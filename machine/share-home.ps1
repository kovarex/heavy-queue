# Shares this machine's travelRoots (config.json) so that workers can run its jobs in the same folders
# (machine\setup-worker.ps1 maps them there at the same paths). Run once, as administrator, in this clone:
#   powershell -ExecutionPolicy Bypass -File machine\share-home.ps1 [-ReadOnly D:\src] [-WorkerAccount NAME -SignInFile PATH]
# It does these things, and says what it did:
# - The network this machine is on becomes Private: Windows shares nothing on a Public one.
# - File and Printer Sharing's inbound rules are turned on, for Private networks only.
# - Each travelRoot is shared under its folder's name, for this user only: with full access, or read-only
#   for the folders given with -ReadOnly (folders no job elsewhere should write, such as a source tree that
#   only one build at a time may write).
# - With -WorkerAccount: workers sign in as that local account of this machine instead of this user (needed
#   when this user has no password, as Windows lets nobody in over the network through an account without
#   one). It is made when missing, with a random password, not an administrator, hidden from the sign-in
#   screen; the shares and their folders let it in (modify, or read for -ReadOnly); its user name and
#   password go to -SignInFile, where setup-worker.ps1 -SignInFile reads them. Run again, it makes a new
#   password and writes it there again.
param([string[]]$ReadOnly = @(), [string]$WorkerAccount = '', [string]$SignInFile = '')
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'run this as administrator' }
if ($WorkerAccount -and -not $SignInFile) { throw '-WorkerAccount needs -SignInFile: where the workers find its sign-in' }
. (Join-Path (Split-Path $PSScriptRoot) 'lock\config.ps1')
if (@($travelRoots).Count -eq 0) { throw "config.json ($configFile) names no travelRoots: nothing to share" }

foreach ($p in @(Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' }))
{
  Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
  "network '$($p.Name)' ($($p.InterfaceAlias)): Public -> Private"
}
# (the group's resource name, the same in every language of Windows)
$rules = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' | Where-Object { $_.Direction -eq 'Inbound' -and $_.Profile.ToString() -match 'Private' })
$rules | Enable-NetFirewallRule
"File and Printer Sharing: $($rules.Count) inbound rules on for Private networks"

$account = $identity.Name
$worker = ''
if ($WorkerAccount)
{
  $worker = "$env:COMPUTERNAME\$WorkerAccount"
  $bytes = New-Object byte[] 18
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $secret = [Convert]::ToBase64String($bytes).Replace('+', 'x').Replace('/', 'y')
  $secure = ConvertTo-SecureString $secret -AsPlainText -Force
  if (Get-LocalUser -Name $WorkerAccount -ErrorAction SilentlyContinue)
  {
    Set-LocalUser -Name $WorkerAccount -Password $secure
    "the account ${worker}: a new password"
  }
  else
  {
    New-LocalUser -Name $WorkerAccount -Password $secure -PasswordNeverExpires -AccountNeverExpires -UserMayNotChangePassword -Description 'heavy-queue: workers sign in as this' | Out-Null
    "the account ${worker}: made (not an administrator)"
  }
  $hidden = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
  New-Item -Path $hidden -Force | Out-Null
  New-ItemProperty -Path $hidden -Name $WorkerAccount -Value 0 -PropertyType DWord -Force | Out-Null
  New-Item -ItemType Directory -Force (Split-Path $SignInFile) | Out-Null
  Set-Content -Path $SignInFile -Value @($worker, $secret) -Encoding ascii
  "its sign-in: $SignInFile"
}

# (not named $readOnly: PowerShell's names ignore case, and that is the parameter -ReadOnly)
$readOnlyFolders = @($ReadOnly | ForEach-Object { (Resolve-Path $_).Path.TrimEnd('\') })
foreach ($folder in $travelRoots)
{
  if (-not (Test-Path -LiteralPath $folder)) { "$folder does not exist: not shared (take it out of travelRoots)"; continue }
  $full = (Resolve-Path $folder).Path.TrimEnd('\')
  $shareName = Split-Path -Leaf $full
  $asReadOnly = @($readOnlyFolders | Where-Object { $_ -ieq $full }).Count -gt 0
  $description = if ($asReadOnly) { 'heavy-queue: read by workers' } else { 'heavy-queue: worked in by workers' }
  $existing = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
  if ($existing)
  {
    if ($existing.Path.TrimEnd('\') -ine $full) { throw "a share named $shareName already shares $($existing.Path), not $full" }
    if ($existing.Description -ne $description)
    {
      if ($existing.Description -notlike 'heavy-queue:*') { throw "\\$env:COMPUTERNAME\$shareName was not made by this script: change it by hand" }
      Remove-SmbShare -Name $shareName -Force # (made by this script with the other access: made again below)
      $existing = $null
    }
  }
  if (-not $existing)
  {
    if ($asReadOnly) { New-SmbShare -Name $shareName -Path $full -ReadAccess $account -Description $description | Out-Null }
    else { New-SmbShare -Name $shareName -Path $full -FullAccess $account -Description $description | Out-Null }
  }
  $who = $account
  if ($worker)
  {
    Grant-SmbShareAccess -Name $shareName -AccountName $worker -AccessRight $(if ($asReadOnly) { 'Read' } else { 'Full' }) -Force | Out-Null
    # (on the folder, inherited by what is in it and what comes later)
    & icacls $full /grant "$($worker):(OI)(CI)$(if ($asReadOnly) { 'RX' } else { 'M' })" /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls could not let $worker into $full" }
    $who = "$account and $worker"
  }
  "\\$env:COMPUTERNAME\$shareName shares $full ($(if ($asReadOnly) { 'read-only' } else { 'full access' }), for $who only)"
}
''
"On each worker, as administrator, in its clone of heavy-queue:"
"  powershell -ExecutionPolicy Bypass -File machine\setup-worker.ps1 -HomeName $env:COMPUTERNAME -Shares $((@($travelRoots | Where-Object { Test-Path -LiteralPath $_ }) | ForEach-Object { Split-Path -Leaf $_ }) -join ',') -HomeData $root -PublishFile PATH$(if ($SignInFile) { " -SignInFile $SignInFile" })"
