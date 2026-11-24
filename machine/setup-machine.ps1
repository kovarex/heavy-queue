# Sets this computer up as a heavy-queue machine that is opened and closed on the board. Run once, in
# PowerShell, from this repository's clone (the lock and the scripts run from the clone):
#   powershell -ExecutionPolicy Bypass -File machine\setup-machine.ps1 -PublishFile PATH [-Root DIR] [-Name NAME] [-NoBenchmarks] [-Shim PATH]
# -PublishFile: a publish.txt to copy into the data folder (the board's address, its posting password and,
#   optionally, a third line naming the machine). It holds the password: keep it outside this repository.
# -Root: the data folder, written into config.json when there is none yet (else config.json's, else
#   %ProgramData%\heavy-queue).
# -Name: the machine's name on the board (else the computer's name without "PC-").
# -NoBenchmarks: a machine too slow or too different for timing: shown as "builds only", and its lock
#   refuses --exclusive jobs.
# -Shim: also writes a .cmd there that calls this clone's lock\heavy.cmd (for scripts that call the lock by
#   a fixed path).
# It also starts the hold file closed ("HOLD: yes") and registers a scheduled task, "heavy-queue machine
# gate", that runs machine-gate.ps1 hidden at logon.
param([Parameter(Mandatory = $true)][string]$PublishFile, [string]$Root = '', [string]$Name = '', [switch]$NoBenchmarks, [string]$Shim = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$configPath = Join-Path $repo 'config.json'
if ($Root -and -not (Test-Path $configPath)) { Set-Content $configPath (([ordered]@{ root = $Root }) | ConvertTo-Json) -Encoding ascii }
. (Join-Path $repo 'lock\config.ps1')
if ($Root -and $root -ne $Root) { Write-Warning "config.json already names $root as the data folder: kept" }
New-Item -ItemType Directory -Force $root, (Split-Path $schedule) | Out-Null
Copy-Item $PublishFile (Join-Path $root 'publish.txt') -Force
if ($Name)
{
  $lines = @(Get-Content (Join-Path $root 'publish.txt') -TotalCount 2) + $Name
  Set-Content (Join-Path $root 'publish.txt') $lines -Encoding ascii
}
if ($NoBenchmarks) { New-Item -ItemType File -Force (Join-Path $root 'no-benchmarks') | Out-Null } else { Remove-Item (Join-Path $root 'no-benchmarks') -Force -ErrorAction SilentlyContinue }
if ($Shim) { Set-Content $Shim "@echo off`r`ncall `"$repo\lock\heavy.cmd`" %*`r`nexit /b %errorlevel%`r`n" -Encoding ascii }
if (-not (Test-Path $schedule)) { Set-Content $schedule @('HOLD: yes (closed on the board)', '# Line 1 is read by the heavy lock: "HOLD: yes" or "HOLD: no". machine-gate.ps1 writes it from the board.') -Encoding UTF8 }
# (a running gate picks the new name up when restarted)
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*machine-gate.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$repo\machine\machine-gate.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'heavy-queue machine gate' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'heavy-queue machine gate'
Start-Sleep 5
'hold file: ' + (Get-Content $schedule -TotalCount 1)
'Done. Open ' + $(if ($Name) { $Name } else { $env:COMPUTERNAME -replace '^PC-', '' }) + ' on the board when it may take heavy jobs.'
