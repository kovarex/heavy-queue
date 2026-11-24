# Sets this computer up as a worker: it runs another machine's (its home's) waiting jobs that may travel,
# in the same folders, which this script maps here at the same paths (directory links to the home's shares:
# machine\share-home.ps1 makes them). Run once, as administrator, in this computer's clone of heavy-queue
# (not inside one of the mapped folders):
#   powershell -ExecutionPolicy Bypass -File machine\setup-worker.ps1 -HomeName PC-HOME -HomeData C:\...\heavy -PublishFile PATH [-User NAME] [-Name NAME] [-NoBenchmarks]
# -HomeName: the home's computer name. -HomeData: the home's data folder (its config's root), which must lie
#   in one of its shared folders. -PublishFile, -Name, -NoBenchmarks: as machine\setup-machine.ps1, which
#   this runs too (this machine's own lock, its gate and the board).
# -User: the home's user for its shares (asked when not given; the password is always typed by you).
# What it does, and says:
# 1. This computer remembers the sign-in for the home's shares (cmdkey).
# 2. A scheduled task here that runs a script from a folder about to become the home's is stopped and
#    removed, and so is a PowerShell running one: a gate of an older setup there would write the home's
#    hold file and hold all its jobs.
# 3. Each share of the home becomes a directory link at the same path here (C:\kpp -> \\HOME\kpp). A folder
#    of this computer that is in the way is renamed to NAME.local-DATE, never deleted.
# 4. Links to network folders are followed (fsutil SymlinkEvaluation L2R:1) and git trusts the home's
#    repositories (safe.directory *).
# 5. config.json: this machine's data folder stays local (%ProgramData%\heavy-queue unless set), "home" is
#    -HomeData, and "fingerprint" is the home's, so both compare the same tools.
# 6. setup-machine.ps1, then the scheduled task "heavy-queue worker" (machine\worker.ps1 at logon).
param(
  [Parameter(Mandatory = $true)][string]$HomeName,
  [Parameter(Mandatory = $true)][string]$HomeData,
  [Parameter(Mandatory = $true)][string]$PublishFile,
  [string]$User = '',
  [string]$Name = '',
  [switch]$NoBenchmarks)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'run this as administrator (directory links need it)' }
$clone = Split-Path $PSScriptRoot

# 1. The sign-in for the home's shares.
# (only the shares share-home.ps1 made: their comment says heavy-queue)
function Home-Shares { return @(net view "\\$HomeName" 2>$null | Where-Object { $_ -match '^(\S+)\s+Disk.*heavy-queue' } | ForEach-Object { ($_ -split '\s+')[0] }) }
$shares = Home-Shares
if ($shares.Count -eq 0)
{
  if (-not $User) { $User = Read-Host "The user for \\$HomeName's shares (its local user, or MicrosoftAccount\your@e-mail)" }
  & cmdkey "/add:$HomeName" "/user:$User" /pass
  $shares = Home-Shares
  if ($shares.Count -eq 0) { throw "\\$HomeName shows no heavy-queue shares: is machine\share-home.ps1 run there, is it on, and is the sign-in right?" }
}
"shares of \\$($HomeName): $($shares -join ', ')"

# 2. What would run the home's scripts once its folders are here.
$mapped = @($shares | ForEach-Object { "c:\$($_.ToLowerInvariant())\" })
function Under-Mapped([string]$text) { $t = "$text".ToLowerInvariant(); return @($mapped | Where-Object { $t.Contains($_) }).Count -gt 0 }
foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue))
{
  $runs = (@($task.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
  if (Under-Mapped $runs)
  {
    Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false
    "removed the scheduled task '$($task.TaskName)' (it ran $runs)"
  }
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match '\.ps1' -and (Under-Mapped $_.CommandLine) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; "stopped pid $($_.ProcessId): $($_.CommandLine)" }

# 3. Each share at the same path here.
$date = Get-Date -Format 'yyyyMMdd'
foreach ($share in $shares)
{
  $path = "C:\$share"
  $target = "\\$HomeName\$share"
  if ($clone.ToLowerInvariant().StartsWith($path.ToLowerInvariant() + '\')) { throw "this clone ($clone) lies in $path, which becomes the home's: clone heavy-queue elsewhere first" }
  $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if ($item -and $item.LinkType -eq 'SymbolicLink' -and "$($item.Target)" -ieq $target) { "$path -> $target already"; continue }
  if ($item)
  {
    $aside = "$path.local-$date"
    Rename-Item -LiteralPath $path -NewName (Split-Path -Leaf $aside)
    "$path was this computer's own: renamed to $aside"
  }
  New-Item -ItemType SymbolicLink -Path $path -Target $target | Out-Null
  "$path -> $target"
}

# 4. Links to network folders, and the home's repositories.
& fsutil behavior set SymlinkEvaluation L2R:1 | Out-Null
& git config --global --add safe.directory '*'
'links to network folders are followed; git trusts the home''s repositories'

# 5. This clone's config.
if (-not (Test-Path (Join-Path $HomeData 'queue'))) { throw "$HomeData has no queue folder: is it the home's data folder (its config's root)?" }
$configPath = Join-Path $clone 'config.json'
$settings = if (Test-Path $configPath) { Get-Content -Raw $configPath | ConvertFrom-Json } else { New-Object PSObject }
$settings | Add-Member -NotePropertyName home -NotePropertyValue $HomeData -Force
$homeConfig = Join-Path (Split-Path $HomeData) 'heavy-queue\config.json'
if (Test-Path $homeConfig)
{
  $theirs = Get-Content -Raw $homeConfig | ConvertFrom-Json
  if ($theirs.fingerprint) { $settings | Add-Member -NotePropertyName fingerprint -NotePropertyValue $theirs.fingerprint -Force; "fingerprint from $($homeConfig): $($theirs.fingerprint -join '; ')" }
  if ($theirs.samePaths) { $settings | Add-Member -NotePropertyName samePaths -NotePropertyValue $theirs.samePaths -Force }
}
else { "no ${homeConfig}: set ""fingerprint"" in $configPath as the home has it" }
Set-Content $configPath ($settings | ConvertTo-Json) -Encoding ascii
"config: $configPath"

# 6. This machine's own lock, gate and board entry, then the worker.
$setup = @{ PublishFile = $PublishFile }
if ($Name) { $setup.Name = $Name }
if ($NoBenchmarks) { $setup.NoBenchmarks = $true }
& (Join-Path $PSScriptRoot 'setup-machine.ps1') @setup
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$clone\machine\worker.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'heavy-queue worker' -Action $action -Trigger $trigger -Settings $taskSettings -Force | Out-Null
Start-ScheduledTask -TaskName 'heavy-queue worker'
'worker started (scheduled task "heavy-queue worker"). What it does, or why it takes nothing, shows on the board.'
