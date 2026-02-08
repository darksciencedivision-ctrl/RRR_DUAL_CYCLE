param(
  [string]$Root = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Logs = Join-Path $Root "logs"
$ClockFile = Join-Path $Logs "clock.txt"

if (!(Test-Path $Logs)) { New-Item -ItemType Directory -Force -Path $Logs | Out-Null }

while ($true) {
  $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Set-Content -Encoding UTF8 -Path $ClockFile -Value $now
  Start-Sleep -Seconds 1
}
