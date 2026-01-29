param(
  [string]$WebAppName = $env:WEB_APP_NAME,
  [string]$StatusUrl = $env:A2A_AUTOMATION_STATUS_URL
)

# Check A2A Automation Framework Status
Write-Host "Checking A2A Automation Framework status..."
$processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*automated_main*" }

if ($processes) {
  Write-Host "A2A Automation Framework is RUNNING"
  Write-Host "Processes: $($processes.Count)"
  $processes | Select-Object ProcessId,Name,CreationDate | Format-Table -AutoSize
} else {
  Write-Host "A2A Automation Framework is STOPPED"
}

# Build status URL dynamically
if (-not $StatusUrl -and $WebAppName) {
  $StatusUrl = "https://$WebAppName.azurewebsites.net/a2a/automation/status"
}

if (-not $StatusUrl) {
  Write-Host "Automation endpoint not accessible (missing WebAppName or StatusUrl)"
  return
}

# Check automation endpoint
try {
  $status = Invoke-RestMethod -Uri $StatusUrl -TimeoutSec 5
  Write-Host "Automation Status: $($status | ConvertTo-Json -Compress)"
} catch {
  Write-Host "Automation endpoint not accessible"
}
