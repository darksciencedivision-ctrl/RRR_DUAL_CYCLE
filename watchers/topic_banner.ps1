param(
  [string]$Root = ".",
  [int]$PollMs = 250
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Logs = Join-Path $Root "logs"
$DialogFile = Join-Path $Logs "dialog.txt"
$BannerFile = Join-Path $Logs "topic_banner.txt"

if (!(Test-Path $Logs)) { New-Item -ItemType Directory -Force -Path $Logs | Out-Null }
if (!(Test-Path $DialogFile)) { New-Item -ItemType File -Force -Path $DialogFile | Out-Null }

$lastBanner = ""

while ($true) {
  try {
    $lines = Get-Content -Path $DialogFile -Tail 300
    $topicLine = $lines | Where-Object { $_ -like "[SYSTEM] Topic:*" } | Select-Object -Last 1
    if ($topicLine) {
      $topic = $topicLine -replace "^\[SYSTEM\]\s*Topic:\s*", ""
      $topic = $topic.Trim()
      if ($topic -and $topic -ne $lastBanner) {
        $lastBanner = $topic
        Set-Content -Encoding UTF8 -Path $BannerFile -Value $topic
      }
    }
  } catch {
    # fail soft
  }
  Start-Sleep -Milliseconds $PollMs
}

