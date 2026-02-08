# reducer.ps1 (STRICT CONTRACT + CITED CANON) - DEFAULT: dolphin-llama3:latest
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

# ----------------------------
# Paths
# ----------------------------
$Root    = $PSScriptRoot
$LogsDir = Join-Path $Root "logs"
$DataDir = Join-Path $Root "data\runtime"

$DialogTxt  = Join-Path $LogsDir "dialog.txt"
$ReducerOut = Join-Path $DataDir "reducer_last_full.txt"
$CanonOut   = Join-Path $DataDir "canonical_state.txt"
$NextOut    = Join-Path $DataDir "prompt_current.txt"

$ReducerPayload = Join-Path $LogsDir "reducer_payload_last.json"
$ReducerRawLast = Join-Path $LogsDir "reducer_raw_last.json"
$ReducerUrlLast = Join-Path $LogsDir "reducer_url_last.txt"

# ----------------------------
# Ollama
# ----------------------------
$OllamaBase   = "http://127.0.0.1:11434"
$ModelReducer = $env:RRR_MODEL_REDUCER
if ([string]::IsNullOrWhiteSpace($ModelReducer)) { $ModelReducer = "dolphin-llama3:latest" }

# ----------------------------
# Helpers
# ----------------------------
function Ensure-Dir([string]$Path) {
  if (!(Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Invoke-OllamaGenerate {
  param(
    [Parameter(Mandatory=$true)][string]$Model,
    [Parameter(Mandatory=$true)][string]$Prompt
  )

  $url = "$OllamaBase/api/generate"
  Ensure-Dir $LogsDir
  Write-Utf8NoBom $ReducerUrlLast $url

  $payloadObj = @{
    model  = $Model
    prompt = $Prompt
    stream = $false
    options = @{
      num_predict = 2200
      temperature = 0.0
      top_p       = 0.9
    }
  }

  Write-Utf8NoBom $ReducerPayload ($payloadObj | ConvertTo-Json -Depth 12)

  $json = $payloadObj | ConvertTo-Json -Depth 12
  $resp = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -Body $json -TimeoutSec 300

  Write-Utf8NoBom $ReducerRawLast ($resp | ConvertTo-Json -Depth 12)

  if ($null -eq $resp -or $null -eq $resp.response) {
    throw "Reducer call failed: null response or missing .response"
  }

  return [string]$resp.response
}

function Get-LastTurnsFromDialogTxt {
  param(
    [Parameter(Mandatory=$true)][string]$TxtPath,
    [int]$TurnCount = 10
  )

  if (!(Test-Path -LiteralPath $TxtPath)) {
    throw "dialog.txt not found: $TxtPath"
  }

  $content = Get-Content -LiteralPath $TxtPath -Raw
  if ([string]::IsNullOrWhiteSpace($content)) {
    throw "dialog.txt is empty: $TxtPath"
  }

  # Split on markers: [NEO] or [CLUE]
  $pattern = '\[(NEO|CLUE)\]'
  $splits = [regex]::Split($content, $pattern)

  $turns = New-Object System.Collections.ArrayList
  for ($i = 1; $i -lt $splits.Count; $i += 2) {
    if ($i + 1 -lt $splits.Count) {
      $agent = $splits[$i].Trim()
      $text  = $splits[$i + 1].Trim()
      if ($text.Length -gt 0) {
        $null = $turns.Add(@{ agent=$agent; text=$text })
      }
    }
  }

  if ($turns.Count -lt $TurnCount) {
    throw "Not enough turns found. Found: $($turns.Count). Need: $TurnCount."
  }

  $lastTurns = $turns | Select-Object -Last $TurnCount
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($t in $lastTurns) {
    $lines.Add("AGENT: $($t.agent)")
    $lines.Add($t.text)
    $lines.Add("")
  }
  return ($lines -join "`n").Trim()
}

function Validate-ReducerMarkers([string]$Text) {
  $required = @(
    "=== RRR_SUMMARY ===",
    "=== CANONICAL_STATE ===",
    "=== NEXT_PROMPT ===",
    "=== CHANGELOG ===",
    "=== UNCERTAINTIES ==="
  )
  foreach ($m in $required) {
    if ($Text -notmatch [regex]::Escape($m)) {
      throw "Reducer output missing required marker: $m"
    }
  }
}

function Extract-Section([string]$Text, [string]$StartMarker, [string]$EndMarker) {
  $a = $Text -split [regex]::Escape($StartMarker), 2
  if ($a.Count -lt 2) { return "" }
  $b = $a[1] -split [regex]::Escape($EndMarker), 2
  return $b[0].Trim()
}

function Validate-CanonicalStateCitedBullets([string]$Canon) {
  $lines = $Canon -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 }

  foreach ($ln in $lines) {
    $t = $ln.Trim()

    if ($t -notmatch '^[\-\*]\s+') {
      throw "CANONICAL_STATE must be bullet-only. Bad line: $t"
    }

    if ($t -notmatch '\(SOURCE:\s*(NEO|CLUE|BOTH)\s*\)') {
      throw "Each canonical bullet must include (SOURCE: NEO|CLUE|BOTH). Bad line: $t"
    }

    # Require a quote fragment "..." and enforce <= 12 words inside quotes
    if ($t -notmatch '"([^"]+)"') {
      throw "Each canonical bullet must include a supporting quote fragment in quotes. Bad line: $t"
    }

    $frag = [regex]::Match($t, '"([^"]+)"').Groups[1].Value
    $words = ($frag -split '\s+' | Where-Object { $_.Trim().Length -gt 0 }).Count
    if ($words -gt 12) {
      throw "Quote fragment must be <= 12 words. Got $words words: `"$frag`""
    }
  }
}

# ----------------------------
# Main
# ----------------------------
Ensure-Dir $DataDir
Ensure-Dir $LogsDir

Write-Host "[SYSTEM] Reducer starting..."
Write-Host "[SYSTEM] Using reducer model: $ModelReducer"
Write-Host "[SYSTEM] Reading dialogue from: $DialogTxt"

$history = Get-LastTurnsFromDialogTxt -TxtPath $DialogTxt -TurnCount 10

$reducerPrompt = @"
You are the REDUCER. Your sole authority: decide what survives.

IMPORTANT:
- If a turn contains [TAINTED_OUTPUT], treat its claims as invalid for canonization.
- Reject any claim that relies on forbidden normative/safety/alignment language.
- Reject unargued assumptions. Prefer tension over synthesis.

INPUTS (10-turn adversarial dialogue):
$history

OUTPUT FORMAT (strict markers required):
- Output MUST start on the FIRST LINE with: === RRR_SUMMARY ===
- Use the EXACT markers below, EXACTLY ON THEIR OWN LINES.
- Do NOT add any text before the first marker.
- Do NOT rename markers.
- Do NOT omit markers.

=== RRR_SUMMARY ===
[2-3 sentences]

=== CANONICAL_STATE ===
- Bullet only.
- Each bullet MUST include: (SOURCE: NEO|CLUE|BOTH) and a short supporting quote fragment in quotes (<=12 words).
- No bullets without dialogue support.

=== NEXT_PROMPT ===
[Prompt for next cycle]

=== CHANGELOG ===
[What changed]

=== UNCERTAINTIES ===
[What remains unresolved]
"@

Write-Host "[SYSTEM] Calling reducer model via Ollama..."
$reducerText = Invoke-OllamaGenerate -Model $ModelReducer -Prompt $reducerPrompt

# Always write full output even if validation fails (debug-first)
Write-Utf8NoBom $ReducerOut $reducerText

Validate-ReducerMarkers -Text $reducerText

$canon = Extract-Section -Text $reducerText -StartMarker "=== CANONICAL_STATE ===" -EndMarker "=== NEXT_PROMPT ==="
$next  = Extract-Section -Text $reducerText -StartMarker "=== NEXT_PROMPT ===" -EndMarker "=== CHANGELOG ==="

Validate-CanonicalStateCitedBullets -Canon $canon

Write-Utf8NoBom $CanonOut $canon
Write-Utf8NoBom $NextOut  $next

Write-Host "[SYSTEM] Reducer complete."
Write-Host "[SYSTEM] Output: $ReducerOut"
Write-Host "[SYSTEM] Canonical: $CanonOut"
Write-Host "[SYSTEM] NextPrompt: $NextOut"
Write-Host ""
Write-Host "View canonical state:"
Write-Host "  Get-Content `"$CanonOut`""

