param(
  [string]$Root = ".",
  [int]$Lines = 40,
  [int]$PollMs = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Logs = Join-Path $Root "logs"
$DialogFile = Join-Path $Logs "dialog.txt"
$OutFile = Join-Path $Logs "obs_dialog.txt"

if (!(Test-Path $Logs)) { New-Item -ItemType Directory -Force -Path $Logs | Out-Null }
if (!(Test-Path $DialogFile)) { New-Item -ItemType File -Force -Path $DialogFile | Out-Null }

while ($true) {
  try {
    $tail = Get-Content -Path $DialogFile -Tail $Lines -ErrorAction Stop
    $text = ($tail -join "`n").TrimEnd()
    Set-Content -Encoding UTF8 -Path $OutFile -Value $text
  } catch {}
  Start-Sleep -Milliseconds $PollMs
}
