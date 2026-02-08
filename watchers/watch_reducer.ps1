Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Set-Location -LiteralPath $PSScriptRoot
$root = Split-Path -Parent $PSScriptRoot

$src = Join-Path $root "data\runtime\reducer_last_full.txt"
$dst = Join-Path $root "logs\obs_reducer.txt"

if (!(Test-Path (Split-Path -Parent $dst))) { New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null }
if (!(Test-Path $dst)) { New-Item -ItemType File -Force $dst | Out-Null }

$last = ""
while ($true) {
  if (Test-Path $src) {
    $txt = Get-Content -LiteralPath $src -Raw -Encoding UTF8
    if ($txt -ne $last) {
      $last = $txt
      $lines = $txt -split "`r?`n"
      $tail = $lines | Select-Object -Last 120
      Set-Content -LiteralPath $dst -Value ($tail -join "`r`n") -Encoding UTF8
    }
  }
  Start-Sleep -Milliseconds 250
}
