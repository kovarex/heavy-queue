# Shares this machine's travelRoots (config.json) so that workers can run its jobs in the same folders
# (machine\setup-worker.ps1 maps them there at the same paths). Run once, as administrator, in this clone:
#   powershell -ExecutionPolicy Bypass -File machine\share-home.ps1 [-ReadOnly D:\src]
# It does three things, and says what it did:
# - The network this machine is on becomes Private: Windows shares nothing on a Public one.
# - File and Printer Sharing's inbound rules are turned on, for Private networks only.
# - Each travelRoot is shared under its folder's name, for this user only: with full access, or read-only
#   for the folders given with -ReadOnly (folders no job elsewhere should write, such as a source tree that
#   only one build at a time may write).
param([string[]]$ReadOnly = @())
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'run this as administrator' }
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
foreach ($folder in $travelRoots)
{
  $full = (Resolve-Path $folder).Path.TrimEnd('\')
  $shareName = Split-Path -Leaf $full
  $readOnly = @($ReadOnly | Where-Object { (Resolve-Path $_).Path.TrimEnd('\') -ieq $full }).Count -gt 0
  $existing = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
  if ($existing)
  {
    if ($existing.Path.TrimEnd('\') -ine $full) { throw "a share named $shareName already shares $($existing.Path), not $full" }
    "\\$env:COMPUTERNAME\$shareName already shares $full"
    continue
  }
  if ($readOnly) { New-SmbShare -Name $shareName -Path $full -ReadAccess $account -Description 'heavy-queue: read by workers' | Out-Null }
  else { New-SmbShare -Name $shareName -Path $full -FullAccess $account -Description 'heavy-queue: worked in by workers' | Out-Null }
  "\\$env:COMPUTERNAME\$shareName shares $full ($(if ($readOnly) { 'read-only' } else { 'full access' }), for $account only)"
}
''
"On each worker, as administrator, in its clone of heavy-queue:"
"  powershell -ExecutionPolicy Bypass -File machine\setup-worker.ps1 -HomeName $env:COMPUTERNAME -HomeData $root -PublishFile PATH"
"It asks for this computer's sign-in (the user $account, or the Microsoft account's e-mail and password)."
