# Sets this computer up as a worker: it runs other machines' waiting jobs that may travel (lock\travel.ps1),
# which come and go through a folder every machine sees (-Exchange, a NAS share). Run once, in PowerShell, in
# this computer's clone of heavy-queue:
#   powershell -ExecutionPolicy Bypass -File machine\setup-worker.ps1 -Exchange \\NAS\SHARE\FOLDER -PublishFile PATH [-Name NAME] [-NoBenchmarks] [-Tools DIR,DIR]
# -Tools: the folders the homes' travelTools name (such as C:\Program Files\kpp): made if missing and given to
#   this user to modify, so the worker mirrors the homes' tools over them without running as administrator.
# -PublishFile, -Name, -NoBenchmarks: as machine\setup-machine.ps1, which this runs too (this machine's own
# lock, its gate and its card on the board).
# It writes "travelExchange" into config.json and registers the scheduled task "heavy-queue worker"
# (machine\worker.ps1 at logon, hidden). This machine needs git and tar (Windows 10 has it), and can fetch
# the homes' repositories (their remotes) as you; the tools the homes' fingerprints name must be the same
# here, or the worker takes nothing and says why on the board. A job's checkout is made at its path on the
# home; a folder of this computer in the way is renamed to NAME.local-DATE-TIME, never deleted.
param(
  [Parameter(Mandatory = $true)][string]$Exchange,
  [Parameter(Mandatory = $true)][string]$PublishFile,
  [string]$Name = '',
  [switch]$NoBenchmarks,
  [string[]]$Tools = @())
$ErrorActionPreference = 'Stop'
$clone = Split-Path $PSScriptRoot
if (-not (Test-Path -LiteralPath $Exchange)) { New-Item -ItemType Directory -Force $Exchange | Out-Null }
$configPath = if ($env:HEAVY_QUEUE_CONFIG) { $env:HEAVY_QUEUE_CONFIG } else { Join-Path $clone 'config.json' }
$settings = if (Test-Path $configPath) { Get-Content -Raw $configPath | ConvertFrom-Json } else { New-Object PSObject }
$settings | Add-Member -NotePropertyName travelExchange -NotePropertyValue $Exchange -Force
Set-Content $configPath ($settings | ConvertTo-Json) -Encoding ascii
"config: $configPath (travelExchange $Exchange)"
foreach ($tool in 'git', "$env:windir\System32\tar.exe")
{
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is missing: the worker makes checkouts with it" }
}
$setup = @{ PublishFile = $PublishFile }
if ($Name) { $setup.Name = $Name }
if ($NoBenchmarks) { $setup.NoBenchmarks = $true }
& (Join-Path $PSScriptRoot 'setup-machine.ps1') @setup
foreach ($folder in $Tools)
{
  New-Item -ItemType Directory -Force $folder | Out-Null
  & icacls $folder /grant "$($env:USERDOMAIN)\$($env:USERNAME):(OI)(CI)M" /T /C /Q | Out-Null
  if ($LASTEXITCODE) { throw "could not give $folder to $env:USERNAME (icacls $LASTEXITCODE): run this as administrator" }
  "tool folder ${folder}: $env:USERNAME may modify it"
}
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*machine\worker.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$clone\machine\worker.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
# (highest privileges: it mirrors the home's travelTools over its own, such as C:\Program Files\kpp)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'heavy-queue worker' -Action $action -Trigger $trigger -Settings $taskSettings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'heavy-queue worker'
'worker started (scheduled task "heavy-queue worker"). Open this machine on the board; what the worker does, or why it takes nothing, shows on its card.'
