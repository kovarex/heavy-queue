# heavy-queue's settings, read by the lock and the machine scripts (dot-sourced): config.json in the
# repository's root, or the file HEAVY_QUEUE_CONFIG names. lock\README.md lists them and their defaults.
$repo = Split-Path $PSScriptRoot
$configFile = if ($env:HEAVY_QUEUE_CONFIG) { $env:HEAVY_QUEUE_CONFIG } else { Join-Path $repo 'config.json' }
$config = $null
if (Test-Path $configFile)
{
  try { $config = Get-Content -Raw $configFile -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
  catch { throw "heavy: $configFile is not valid JSON (a backslash is written \\): $($_.Exception.Message)" }
}
function Setting([string]$key, $default) { if ($config -and $null -ne $config.$key -and "$($config.$key)" -ne '') { return $config.$key } return $default }
$root = Setting 'root' (Join-Path $env:ProgramData 'heavy-queue')
$machine = Setting 'machine' $env:COMPUTERNAME
$flag = Setting 'quietFlag' (Join-Path $root 'quiet.flag')
$schedule = Setting 'holdFile' (Join-Path $root 'hold.txt')
$mutexName = Setting 'mutex' 'Global\heavy-queue'
$heldVariable = Setting 'heldVariable' ''
$title = Setting 'title' "$machine heavy slot"
$idleLoad = [int](Setting 'idleLoad' 15)
$idleSeconds = [int](Setting 'idleSeconds' 20)
# Jobs that travel (lock\travel.ps1): the folder every machine sees (a NAS share) through which they go, the
# paths that are the same on every machine anyway, the commands whose output must match for two machines to
# run each other's jobs, how much a job's uncommitted state may weigh, and, for testing two machines on one
# computer only, a folder a worker puts its checkouts under (else they are at the home's paths).
$travelExchange = Setting 'travelExchange' ''
$samePaths = @(Setting 'samePaths' @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:windir) | ForEach-Object { "$_" })
$fingerprintCommands = @(Setting 'fingerprint' @() | ForEach-Object { "$_" })
$travelLimitMB = [int](Setting 'travelLimitMB' 500)
$travelCheckouts = Setting 'travelCheckouts' ''
$travelExclusive = [bool](Setting 'travelExclusive' $false) # (timing runs travel too: the machines' hardware is the same)
$travelByDefault = [bool](Setting 'travelByDefault' $true) # (false: only --travel jobs are offered: what git ignores, such as build outputs, does not travel)
$travelTools = @(Setting 'travelTools' @() | ForEach-Object { "$_" }) # (folders a worker takes from its home, such as an unreleased compiler's install)
$computer = Setting 'computer' '' # (the computer this config belongs to: the lock refuses to run elsewhere with it)
$travelStale = [int](Setting 'travelStale' 90) # (seconds without a heartbeat before the other side counts as gone)
