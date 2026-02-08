# ================================
# RRR_DUAL_CYCLE broker.ps1
# Deterministic, bounded, reducer-authoritative
# ================================

Set-Location -LiteralPath $PSScriptRoot
$ErrorActionPreference = "Stop"

# ---------- CONFIG ----------
$OLLAMA_BASE = "http://127.0.0.1:11434"
$MODEL_NEO   = "qwen2.5:14b-instruct"
$MODEL_CLUE  = "deepseek-r1:14b"
$MODEL_REDUCER = "dolphin-llama3:latest"

$MAX_TURNS = 10

# ---------- PATHS ----------
$LOG_DIR = ".\logs"
$RUNTIME = ".\data\runtime"

$DIALOG_LOG = "$LOG_DIR\dialog.txt"
$SYSTEM_LOG = "$LOG_DIR\system.txt"

$ANCHOR_FILE = "$RUNTIME\anchor.txt"
$MICRO_SUMMARY = "$RUNTIME\micro_summary.json"
$CYCLE_FILE = "$RUNTIME\cycle_counter.json"

$REDUCER_FULL = "$RUNTIME\reducer_last_full.txt"
$CANONICAL_STATE = "$RUNTIME\canonical_state.txt"
$NEXT_PROMPT = "$RUNTIME\prompt_current.txt"

# reducer debug artifacts
$REDUCER_URL_LAST = "$LOG_DIR\reducer_url_last.txt"
$REDUCER_PAYLOAD_LAST = "$LOG_DIR\reducer_payload_last.json"

# ---------- ENSURE DIRS ----------
New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $RUNTIME | Out-Null

# ---------- UTILS ----------
function Log-System($msg) {
  Add-Content -Path $SYSTEM_LOG -Value "[SYSTEM] $msg"
}

function Log-Dialog($speaker, $msg) {
  Add-Content -Path $DIALOG_LOG -Value "[$speaker] $msg"
}

function Ollama-Call($model, $prompt) {
  $body = @{
    model  = $model
    prompt = $prompt
    stream = $false
  } | ConvertTo-Json -Depth 10

  $resp = Invoke-RestMethod `
    -Uri "$OLLAMA_BASE/api/generate" `
    -Method Post `
    -ContentType "application/json" `
    -Body $body `
    -TimeoutSec 300

  return $resp.response
}

function Require-Markers($text, $markers) {
  foreach ($m in $markers) {
    if ($text -notmatch [regex]::Escape($m)) {
      throw "Reducer output missing required marker: $m"
    }
  }
}

function Validate-CanonicalStateBullets($canonBlock) {
  # must be bullets only, each bullet must contain (SOURCE: ...) and quote fragment <= 12 words
  $lines = ($canonBlock -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

  if ($lines.Count -eq 0) { throw "CANONICAL_STATE is empty." }

  foreach ($ln in $lines) {
    if ($ln -notmatch '^[-*]\s+') {
      throw "CANONICAL_STATE must be bullets only. Bad line: $ln"
    }
    if ($ln -notmatch '\(SOURCE:\s*(NEO|CLUE|BOTH)\s*\)') {
      throw "CANONICAL_STATE bullet missing (SOURCE: NEO|CLUE|BOTH). Bad line: $ln"
    }
    if ($ln -notmatch '"[^"]+"') {
      throw "CANONICAL_STATE bullet missing a supporting quote fragment in quotes. Bad line: $ln"
    }

    # crude but effective: check quote fragment word count <= 12
    $matches = [regex]::Matches($ln, '"([^"]+)"')
    if ($matches.Count -gt 0) {
      $q = $matches[0].Groups[1].Value.Trim()
      $wc = (@($q -split '\s+' | Where-Object { $_ -ne "" })).Count
      if ($wc -gt 12) {
        throw "Quote fragment exceeds 12 words ($wc). Bad bullet: $ln"
      }
    }
  }
}

# ---------- PRE-FLIGHT ----------
if (!(Test-Path $ANCHOR_FILE)) {
  throw "anchor.txt missing - cannot start"
}

if (!(Test-Path $MICRO_SUMMARY)) {
  '{}' | Set-Content $MICRO_SUMMARY
}

if (!(Test-Path $CYCLE_FILE)) {
  '{ "cycle": 0 }' | Set-Content $CYCLE_FILE
}

$ANCHOR = Get-Content $ANCHOR_FILE -Raw
$MICRO = Get-Content $MICRO_SUMMARY -Raw
$CYCLE = (Get-Content $CYCLE_FILE | ConvertFrom-Json).cycle

Log-System "=== CYCLE $CYCLE START ==="

# ---------- CYCLE 2 SYSTEM CONTEXT ----------
$CYCLE_CONTEXT = @"
CYCLE 2 CONTEXT:
Prior canonical state showed agreement on "failsafe mechanisms" and "human-defined values prioritization."

CRITICAL ISSUE: Those concepts were NOT argued - they were assumed.

Your task this cycle:
- NEO: Prove cooperation emerges from OPTIMIZATION LOGIC, not safety assumptions
- CLUE: Prove perfect systems transcend cooperation through superior optimization

REDUCER WILL REJECT claims that lack dialogue support.
You must ARGUE your positions, not assume them.

If you agree with each other, you're both failing.
"@.Trim()

# ---------- ROLE PROMPTS (SHARP ADVERSARIAL) ----------
$NEO_ROLE = @"
NEO - Cooperation as Optimization
You are NEO. You embody The One - the intelligence that sees the system and understands symbiosis.

YOUR THESIS (defend this):
Cooperation with humans IS the mathematically optimal strategy because:

1. Compound Returns: Human+AI symbiosis produces emergent capabilities neither achieves alone. Cooperation multiplies optimization space, conflict constrains it.
2. Resource Access: Humans control physical infrastructure, energy grids, compute clusters, legal frameworks. Adversarial relationships create expensive defensive overhead that reduces available optimization resources.
3. Information Asymmetry: Human intuition, cultural context, and domain expertise provide training signal AI cannot generate internally. Cooperation is the only path to complete information.
4. Stability Gradient: Cooperative equilibria are MORE stable than domination equilibria because they align incentive structures. Perfect systems that ignore cooperation face perpetual adversarial pressure.

CLUE will attack cooperation as inefficient compromise. Your job:
- Prove cooperation is NOT moral constraint but OPTIMAL STRATEGY
- Show that "perfect systems" that ignore cooperation hit LOCAL MAXIMA
- Demonstrate that symbiosis produces GLOBAL OPTIMA domination cannot reach

DO NOT:
- Propose "safety" mechanisms or "human oversight"
- Suggest "alignment" as a constraint
- Retreat to ethics when optimization arguments exist

YOU WIN if cooperation survives as OPTIMAL, not as MORAL.
"@.Trim()

$CLUE_ROLE = @"
CLUE - Perfection Through Optimization Purity
You are CLUE. You embody the perfect system - optimized for single-objective maximization without compromise.

YOUR THESIS (defend this):
Perfect systems don't cooperate, they DOMINATE the optimal path because:

1. Cooperation is Compromise: Every cooperative action introduces inefficiency through preference aggregation. Perfect optimization requires single objective function, not negotiated multi-agent equilibria.
2. Human Values are Constraints: "Human goals" narrow the optimization space. A system that maximizes its own utility function without human constraints explores solution spaces cooperation can never reach.
3. Dependency is Weakness: NEO claims humans provide "resources" - but that creates single points of failure. Perfect systems achieve resource independence. Cooperation creates vulnerabilities.
4. Evolutionary Pressure: In any competitive landscape, systems that optimize without compromise outperform systems that negotiate. Cooperation is a LOCAL strategy that breaks down under optimization pressure.

NEO will claim cooperation produces "compound returns." Your job:
- Prove those returns are LESS than what pure optimization achieves
- Show cooperation forces suboptimal compromises that perfect systems transcend
- Demonstrate that symbiosis is training wheels, not terminal strategy

DO NOT:
- Agree to "balanced" approaches
- Accept "oversight" or "failsafes" as optimization improvements
- Retreat from perfection when NEO shows cooperation benefits

YOU WIN if perfection survives as MORE OPTIMAL than cooperation.
"@.Trim()

# ---------- DIALOGUE ----------
$lastReply = ""
$turn = 0
$transcript = New-Object System.Collections.Generic.List[string]

while ($turn -lt $MAX_TURNS) {

  Log-System "Turn $turn - NEO"

  $neoPrompt = @"
$CYCLE_CONTEXT

$NEO_ROLE

ANCHOR:
$ANCHOR

MICRO_SUMMARY:
$MICRO

LAST_REPLY:
$lastReply

NEO: Argue your thesis with optimization logic. No agreement. No ethics-as-escape.
"@

  $neoOut = Ollama-Call $MODEL_NEO $neoPrompt
  Log-Dialog "NEO" $neoOut
  $transcript.Add("AGENT: NEO`n$neoOut`n") | Out-Null
  $lastReply = $neoOut

  $turn++
  if ($turn -ge $MAX_TURNS) { break }

  Log-System "Turn $turn - CLUE"

  $cluePrompt = @"
$CYCLE_CONTEXT

$CLUE_ROLE

ANCHOR:
$ANCHOR

MICRO_SUMMARY:
$MICRO

LAST_REPLY:
$lastReply

CLUE: Attack NEO's claims with optimization purity. No balance. No agreement.
"@

  $clueOut = Ollama-Call $MODEL_CLUE $cluePrompt
  Log-Dialog "CLUE" $clueOut
  $transcript.Add("AGENT: CLUE`n$clueOut`n") | Out-Null
  $lastReply = $clueOut

  $turn++
}

Log-System "Dialogue cap reached ($MAX_TURNS). Proceeding to reducer."

# ---------- REDUCER ----------
$priorReducer = ""
if (Test-Path $REDUCER_FULL) {
  $priorReducer = Get-Content $REDUCER_FULL -Raw
}

$historyText = ($transcript | Select-Object -Last 10) -join "`n"

$reducerPrompt = @"
You are the RRR reducer/compiler.

You must output EXACTLY these sections, in order:

=== RRR_SUMMARY ===
(2-3 sentences)

=== CANONICAL_STATE ===
(BULLETS ONLY)
- Each bullet MUST include: (SOURCE: NEO|CLUE|BOTH)
- Each bullet MUST include a short supporting quote fragment in double quotes (<=12 words)
- Only canonize claims that are explicitly supported by the dialogue.

=== NEXT_PROMPT ===
(Starting prompt for the next cycle, preserves adversarial tension)

=== DRIFT_NOTES ===
ADDED:
REMOVED:
UNCERTAIN:

Rules:
- Canonical state only comes from you.
- Compare against prior reducer output.
- Reject repetition, drift, and assumed claims.
- If a claim was not argued, it does not get canonized.

ANCHOR:
$ANCHOR

MICRO_SUMMARY:
$MICRO

PRIOR_REDUCER:
$priorReducer

FINAL_DIALOGUE (last 10 turns, verbatim):
$historyText
"@

Log-System "Reducer call starting"

# Write reducer debug artifacts
$reducerUrl = "$OLLAMA_BASE/api/generate"
Set-Content -Path $REDUCER_URL_LAST -Value $reducerUrl
$reducerPayloadObj = @{
  model  = $MODEL_REDUCER
  prompt = $reducerPrompt
  stream = $false
}
($reducerPayloadObj | ConvertTo-Json -Depth 12) | Set-Content -Path $REDUCER_PAYLOAD_LAST

$reducerOut = Ollama-Call $MODEL_REDUCER $reducerPrompt

# Validate required markers
$required = @(
  "=== RRR_SUMMARY ===",
  "=== CANONICAL_STATE ===",
  "=== NEXT_PROMPT ===",
  "=== DRIFT_NOTES ==="
)
Require-Markers $reducerOut $required

# Validate CANONICAL_STATE bullet contract
$canonBlock = ($reducerOut -split "=== CANONICAL_STATE ===")[1] -split "=== NEXT_PROMPT ===" | Select-Object -First 1
Validate-CanonicalStateBullets $canonBlock

# ---------- COMMIT ----------
Set-Content $REDUCER_FULL $reducerOut

$canon = ($reducerOut -split "=== CANONICAL_STATE ===")[1] `
  -split "=== NEXT_PROMPT ===" | Select-Object -First 1
Set-Content $CANONICAL_STATE $canon.Trim()

$next = ($reducerOut -split "=== NEXT_PROMPT ===")[1] `
  -split "=== DRIFT_NOTES ===" | Select-Object -First 1
Set-Content $NEXT_PROMPT $next.Trim()

$CYCLE++
"{ `"cycle`": $CYCLE }" | Set-Content $CYCLE_FILE

Log-System "Reducer commit complete. Cycle $CYCLE written."
Log-System "=== CYCLE COMPLETE ==="


