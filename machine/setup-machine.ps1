# Sets this computer up as a heavy-queue machine that is opened and closed on the board. Run once, in
# PowerShell, from this repository's clone (the lock and the scripts run from the clone):
#   powershell -ExecutionPolicy Bypass -File machine\setup-machine.ps1 -PublishFile PATH [-DataFolder DIR] [-Name NAME] [-NoBenchmarks] [-Shim PATH]
# -PublishFile: a publish.txt to copy into the data folder (the board's address and its posting password,
#   machine\publish.example.txt). It holds the password: keep it outside this repository.
# -DataFolder, -Name: the data folder and the machine's name on the board, written into config.json (made
#   when there is none; its other settings are kept). Without them, config.json's or the defaults.
# -NoBenchmarks: a machine too slow or too different for timing: shown as "builds only", and its lock
#   refuses --exclusive jobs.
# -Shim: also writes a .cmd there that calls this clone's lock\heavy.cmd, for scripts that call the lock by
#   a fixed path.
# It also starts the hold file closed ("HOLD: yes") and registers a scheduled task, "heavy-queue machine
# gate", that runs machine-gate.ps1 hidden at logon. Its parameters are not named like config.ps1's
# variables ($root, $machine...): PowerShell's names ignore case, and dot-sourcing it would overwrite them.
param([Parameter(Mandatory = $true)][string]$PublishFile, [string]$DataFolder = '', [string]$Name = '', [switch]$NoBenchmarks, [string]$Shim = '')
$ErrorActionPreference = 'Stop'
$clone = Split-Path $PSScriptRoot
$configPath = if ($env:HEAVY_QUEUE_CONFIG) { $env:HEAVY_QUEUE_CONFIG } else { Join-Path $clone 'config.json' }
if ($DataFolder -or $Name)
{
  $settings = if (Test-Path $configPath) { Get-Content -Raw $configPath | ConvertFrom-Json } else { New-Object PSObject }
  if ($DataFolder) { $settings | Add-Member -NotePropertyName root -NotePropertyValue $DataFolder -Force }
  if ($Name) { $settings | Add-Member -NotePropertyName machine -NotePropertyValue $Name -Force }
  Set-Content $configPath ($settings | ConvertTo-Json) -Encoding ascii
}
. (Join-Path $clone 'lock\config.ps1')
New-Item -ItemType Directory -Force $root, (Split-Path $schedule) | Out-Null
Copy-Item $PublishFile (Join-Path $root 'publish.txt') -Force
if ($NoBenchmarks) { New-Item -ItemType File -Force (Join-Path $root 'no-benchmarks') | Out-Null } else { Remove-Item (Join-Path $root 'no-benchmarks') -Force -ErrorAction SilentlyContinue }
if ($Shim) { Set-Content $Shim "@echo off`r`ncall `"$clone\lock\heavy.cmd`" %*`r`nexit /b %errorlevel%`r`n" -Encoding ascii }
if (-not (Test-Path $schedule)) { Set-Content $schedule @('HOLD: yes (closed on the board)', '# Line 1 is read by the heavy lock: "HOLD: yes" or "HOLD: no". machine-gate.ps1 writes it from the board.') -Encoding UTF8 }
# (a running gate picks a new name up when restarted)
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*machine-gate.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$clone\machine\machine-gate.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'heavy-queue machine gate' -Action $action -Trigger $trigger -Settings $taskSettings -Force | Out-Null
Start-ScheduledTask -TaskName 'heavy-queue machine gate'
Start-Sleep 5
"data folder: $root, hold file: $schedule"
'hold file line 1: ' + (Get-Content $schedule -TotalCount 1)
"Done. Open $machine on the board when it may take heavy jobs."
