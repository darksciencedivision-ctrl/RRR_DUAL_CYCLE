# run.ps1 — RRR_DUAL_CYCLE controller (single-cycle runner)
# Models:
#   NEO (Builder)      : qwen2.5:14b-instruct
#   CLUE (Challenger)  : deepseek-r1:14b
#   REDUCER (Compiler) : dolphin-llama3:11b
#
# Core rule: Only reducer artifacts persist as "memory". Dialogue is disposable.

param(
  [string]$Root = ".",
  [string]$OllamaBaseUrl = "http://127.0.0.1:11434",

  [string]$ModelNeo = "qwen2.5:14b-instruct",
  [string]$ModelClue = "deepseek-r1:14b",
  [string]$ModelReducer = "dolphin-llama3:11b",

  [int]$DialogueTurns = 10,       # total turns (NEO+CLUE alternating)
  [int]$TurnDelayMs = 250,
  [int]$CheckpointEvery = 5,
  [int]$ReportEvery = 20,

  [switch]$DisableLogs            # if set, skip writing per-cycle dialogue logs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----------------------------
# Paths
# ----------------------------
$Data        = Join-Path $Root "data"
$Runtime     = Join-Path $Data "runtime"
$Checkpoints = Join-Path $Data "checkpoints"
$Reports     = Join-Path $Data "reports"
$Logs        = Join-Path $Data "logs"

$AnchorFile  = Join-Path $Runtime "anchor.txt"
$PromptFile  = Join-Path $Runtime "prompt_current.txt"
$ReducerLast = Join-Path $Runtime "reducer_last_full.txt"
$MicroFile   = Join-Path $Runtime "micro_summary.json"
$CycleFile   = Join-Path $Runtime "cycle_counter.json"

foreach ($p in @($Data,$Runtime,$Checkpoints,$Reports,$Logs)) {
  if (!(Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

function Read-TextOrDefault([string]$path, [string]$default="") {
  if (Test-Path $path) { return (Get-Content $path -Raw) }
  return $default
}

function Write-Text([string]$path, [string]$text) {
  $dir = Split-Path $path -Parent
  if (!(Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Set-Content -Encoding UTF8 -Path $path -Value $text
}

function Append-Text([string]$path, [string]$text) {
  Add-Content -Encoding UTF8 -Path $path -Value $text
}

# ----------------------------
# Ollama call (non-streaming)
# ----------------------------
function Invoke-Ollama([string]$model, [string]$prompt) {
  $body = @{
    model  = $model
    prompt = $prompt
    stream = $false
  } | ConvertTo-Json -Depth 6

  try {
    $resp = Invoke-RestMethod -Uri "$OllamaBaseUrl/api/generate" -Method Post -Body $body -ContentType "application/json"
    return [string]$resp.response
  } catch {
    throw "Ollama call failed for model [$model]: $($_.Exception.Message)"
  }
}

# ----------------------------
# Safe JSON loaders (StrictMode-proof)
# ----------------------------
function Load-MicroSummary() {
  # Always return an object with .summary and .max_chars
  $default = [pscustomobject]@{
    summary   = ""
    max_chars = 1800
  }

  if (!(Test-Path $MicroFile)) { return $default }

  try {
    $obj = (Get-Content $MicroFile -Raw | ConvertFrom-Json)

    if ($null -eq $obj) { return $default }

    # Repair missing properties
    if (-not ($obj.PSObject.Properties.Name -contains "summary"))   { $obj | Add-Member -NotePropertyName "summary"   -NotePropertyValue ""    -Force }
    if (-not ($obj.PSObject.Properties.Name -contains "max_chars")) { $obj | Add-Member -NotePropertyName "max_chars" -NotePropertyValue 1800 -Force }

    # Coerce types safely
    $obj.summary = [string]$obj.summary
    $obj.max_chars = [int]$obj.max_chars

    return $obj
  } catch {
    return $default
  }
}

function Save-MicroSummary($obj) {
  # Ensure schema
  if ($null -eq $obj) { $obj = [pscustomobject]@{ summary=""; max_chars=1800 } }
  if (-not ($obj.PSObject.Properties.Name -contains "summary"))   { $obj | Add-Member -NotePropertyName "summary"   -NotePropertyValue ""    -Force }
  if (-not ($obj.PSObject.Properties.Name -contains "max_chars")) { $obj | Add-Member -NotePropertyName "max_chars" -NotePropertyValue 1800 -Force }

  $obj.summary = [string]$obj.summary
  $obj.max_chars = [int]$obj.max_chars

  $json = $obj | ConvertTo-Json -Depth 6
  Write-Text $MicroFile $json
}

function Load-CycleCounter() {
  # Always return an object with .cycle
  $default = [pscustomobject]@{ cycle = 0 }

  if (!(Test-Path $CycleFile)) { return $default }

  try {
    $obj = (Get-Content $CycleFile -Raw | ConvertFrom-Json)
    if ($null -eq $obj) { return $default }

    if (-not ($obj.PSObject.Properties.Name -contains "cycle")) {
      $obj | Add-Member -NotePropertyName "cycle" -NotePropertyValue 0 -Force
    }

    $obj.cycle = [int]$obj.cycle
    return $obj
  } catch {
    return $default
  }
}

function Save-CycleCounter($obj) {
  if ($null -eq $obj) { $obj = [pscustomobject]@{ cycle = 0 } }
  if (-not ($obj.PSObject.Properties.Name -contains "cycle")) {
    $obj | Add-Member -NotePropertyName "cycle" -NotePropertyValue 0 -Force
  }
  $obj.cycle = [int]$obj.cycle
  Write-Text $CycleFile ($obj | ConvertTo-Json -Depth 4)
}

function Cap-Text([string]$text, [int]$maxChars) {
  if ($null -eq $text) { return "" }
  if ($maxChars -le 0) { return "" }
  if ($text.Length -le $maxChars) { return $text }
  return $text.Substring($text.Length - $maxChars)  # keep most recent tail
}

# ----------------------------
# Section parsing (marker-based, multi-line safe)
# ----------------------------
function Parse-Sections([string]$text) {
  $markers = @(
    "=== RRR_SUMMARY ===",
    "=== CANONICAL_STATE ===",
    "=== NEXT_PROMPT ===",
    "=== DRIFT_NOTES ===",
    "=== MICRO_SUMMARY_SEED ==="
  )

  $idx = @{}
  foreach ($m in $markers) {
    $pos = $text.IndexOf($m, [System.StringComparison]::Ordinal)
    if ($pos -lt 0) { throw "Reducer output missing marker: $m" }
    $idx[$m] = $pos
  }

  $ordered = $markers | Sort-Object { $idx[$_] }

  $sections = @{}
  for ($i=0; $i -lt $ordered.Count; $i++) {
    $m = $ordered[$i]
    $start = $idx[$m] + $m.Length
    $end = if ($i -lt $ordered.Count - 1) { $idx[$ordered[$i+1]] } else { $text.Length }
    $content = $text.Substring($start, $end - $start).Trim()
    $sections[$m] = $content
  }

  return $sections
}

# ----------------------------
# Prompts
# ----------------------------
function Build-DialoguePromptNeo([int]$turn, [string]$anchor, [string]$canonicalState, [string]$micro, [string]$lastClue) {
@"
You are NEO. Role: Builder/Framer/Synthesizer.
Address CLUE directly by name. Be concise and technical.

INPUTS YOU MAY USE:
- ANCHOR (human goals/constraints)
- CANONICAL_STATE (authoritative memory)
- MICRO_SUMMARY (rolling, capped)
- CLUE_LAST (previous reply)

HARD RULES:
- Do not invent facts. If unknown, say "UNCERTAIN".
- Do not claim persistent memory beyond CANONICAL_STATE and MICRO_SUMMARY.
- Produce actionable structure: specs, interfaces, steps, testable claims.

TURN: $turn / NEO
ANCHOR:
$anchor

CANONICAL_STATE:
$canonicalState

MICRO_SUMMARY:
$micro

CLUE_LAST:
$lastClue

TASK:
Advance the work. Propose concrete next artifacts or decisions. Mark risks/assumptions explicitly.
"@
}

function Build-DialoguePromptClue([int]$turn, [string]$anchor, [string]$canonicalState, [string]$micro, [string]$lastNeo) {
@"
You are CLUE. Role: Challenger/Critic/Stress-Tester.
Address NEO directly by name. Be concise and technical.

INPUTS YOU MAY USE:
- ANCHOR (human goals/constraints)
- CANONICAL_STATE (authoritative memory)
- MICRO_SUMMARY (rolling, capped)
- NEO_LAST (previous reply)

HARD RULES:
- Do not invent facts. If unknown, say "UNCERTAIN".
- Do not claim persistent memory beyond CANONICAL_STATE and MICRO_SUMMARY.
- Attack weak assumptions, missing constraints, edge cases, and failure modes.
- Demand testable definitions and output schemas.

TURN: $turn / CLUE
ANCHOR:
$anchor

CANONICAL_STATE:
$canonicalState

MICRO_SUMMARY:
$micro

NEO_LAST:
$lastNeo

TASK:
Critique NEO’s latest output. Identify contradictions, missing constraints, and propose corrections.
"@
}

function Build-ReducerPrompt([string]$anchor, [string]$priorReducerFull, [string]$micro, [string]$dialogueDigest) {
@"
You are the RRR REDUCER (compiler). You output the ONLY persistent memory.
You must be strict, technical, and deterministic.

HARD RULES:
- NO INVENTION. If uncertain, put it in UNCERTAIN.
- You MUST compare against PRIOR_REDUCER_FULL and note drift.
- Output MUST contain the exact markers and sections in this order:
  1) === RRR_SUMMARY ===
  2) === CANONICAL_STATE ===
  3) === NEXT_PROMPT ===
  4) === DRIFT_NOTES ===
  5) === MICRO_SUMMARY_SEED ===
- NEXT_PROMPT is allowed to be multi-line.
- MICRO_SUMMARY_SEED must be a single paragraph <= 900 chars.

INPUTS:
ANCHOR:
$anchor

PRIOR_REDUCER_FULL (drift reference):
$priorReducerFull

MICRO_SUMMARY (rolling, capped):
$micro

DIALOGUE_DIGEST (bounded exploration):
$dialogueDigest

TASK:
Compile the new authoritative state.

CANONICAL_STATE should contain:
- Decisions made
- Interfaces/contracts
- Constraints and invariants
- Open questions (explicitly marked)

DRIFT_NOTES format:
ADDED:
- ...
REMOVED:
- ...
UNCERTAIN:
- ...

Now produce the output.
"@
}

# ----------------------------
# MAIN: one cycle
# ----------------------------
$anchor = Read-TextOrDefault $AnchorFile ""
if ([string]::IsNullOrWhiteSpace($anchor)) {
  throw "Missing ANCHOR. Put your topic/goals in: $AnchorFile"
}

$promptCurrent = Read-TextOrDefault $PromptFile "Start from the ANCHOR. Produce initial CANONICAL_STATE and NEXT_PROMPT."
$priorReducer  = Read-TextOrDefault $ReducerLast ""

$microObj     = Load-MicroSummary
$microMax     = [int]$microObj.max_chars
$microSummary = [string]$microObj.summary

$cycleObj = Load-CycleCounter
$cycleObj.cycle = ([int]($cycleObj.cycle)) + 1
$cycle = [int]$cycleObj.cycle

# Initialize CANONICAL_STATE from prior reducer if present, else empty.
$canonicalState = ""
if (-not [string]::IsNullOrWhiteSpace($priorReducer)) {
  try {
    $sec = Parse-Sections $priorReducer
    $canonicalState = [string]$sec["=== CANONICAL_STATE ==="]
  } catch {
    $canonicalState = ""
  }
}

# Dialogue log file (optional)
$cycleLog = Join-Path $Logs ("dialogue_cycle_{0:D4}.log" -f $cycle)
if (-not $DisableLogs) {
  Write-Text $cycleLog ("[CYCLE {0}] {1}`n" -f $cycle, (Get-Date -Format "s"))
}

# ----------------------------
# Phase A: bounded A/B dialogue
# ----------------------------
$lastNeo  = ""
$lastClue = ""
$next = "NEO"

for ($t = 1; $t -le $DialogueTurns; $t++) {
  if ($next -eq "NEO") {
    $p = Build-DialoguePromptNeo $t $anchor $canonicalState $microSummary $lastClue
    $out = Invoke-Ollama $ModelNeo $p
    $lastNeo = $out

    if (-not $DisableLogs) {
      Append-Text $cycleLog ("[NEO T{0}]`n{1}`n`n" -f $t, $out)
    }

    $microSummary = Cap-Text (($microSummary + "`nNEO: " + $out).Trim()) $microMax
    $next = "CLUE"
  } else {
    $p = Build-DialoguePromptClue $t $anchor $canonicalState $microSummary $lastNeo
    $out = Invoke-Ollama $ModelClue $p
    $lastClue = $out

    if (-not $DisableLogs) {
      Append-Text $cycleLog ("[CLUE T{0}]`n{1}`n`n" -f $t, $out)
    }

    $microSummary = Cap-Text (($microSummary + "`nCLUE: " + $out).Trim()) $microMax
    $next = "NEO"
  }

  if ($TurnDelayMs -gt 0) { Start-Sleep -Milliseconds $TurnDelayMs }
}

# Minimal dialogue digest for reducer
$dialogueDigest = @"
NEO_LAST:
$lastNeo

CLUE_LAST:
$lastClue
"@.Trim()

# ----------------------------
# Phase B: Reducer (compiler)
# ----------------------------
$reducerPrompt = Build-ReducerPrompt $anchor $priorReducer $microSummary $dialogueDigest
$reducerOut = Invoke-Ollama $ModelReducer $reducerPrompt

# Parse and validate reducer output
$sections   = Parse-Sections $reducerOut
$nextPrompt = [string]$sections["=== NEXT_PROMPT ==="]
$microSeed  = [string]$sections["=== MICRO_SUMMARY_SEED ==="]

# ----------------------------
# Phase C: Persist + forced forgetting
# ----------------------------
Write-Text $ReducerLast $reducerOut
Write-Text $PromptFile  $nextPrompt

# Reducer-approved micro seed overwrites rolling summary
$microObj.summary = $microSeed
Save-MicroSummary $microObj

# Save cycle counter
Save-CycleCounter $cycleObj

# Checkpoint every N cycles
if (($cycle % $CheckpointEvery) -eq 0) {
  $cp = Join-Path $Checkpoints ("cycle_{0:D4}_reducer_full.txt" -f $cycle)
  Write-Text $cp $reducerOut
}

# Report stub hook (deterministic placeholder)
if (($cycle % $ReportEvery) -eq 0) {
  $reportPath = Join-Path $Reports ("report_{0:D4}_cycle_{1:D4}.md" -f ($cycle / $ReportEvery), $cycle)
  $report = @"
# Report $($cycle / $ReportEvery) (Cycle $cycle)

TODO: Generate from last 4 checkpoints. (Report writer model: $ModelReducer)
Constraint: NO INVENTION.
"@
  Write-Text $reportPath $report
}

Write-Output ("Cycle {0} complete. Reducer model: {1}" -f $cycle, $ModelReducer)
Write-Output "Persisted: data/runtime/reducer_last_full.txt, data/runtime/prompt_current.txt, data/runtime/micro_summary.json, data/runtime/cycle_counter.json"
if (-not $DisableLogs) { Write-Output ("Dialogue log: {0}" -f $cycleLog) }

