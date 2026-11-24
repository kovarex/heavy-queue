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
