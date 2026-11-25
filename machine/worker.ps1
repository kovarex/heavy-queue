# A worker: runs other machines' waiting jobs that may travel (lock\travel.ps1) while this machine is open and
# idle. Every 5 seconds, while this machine's hold file says "HOLD: no", no quiet flag stands, its slot is free
# and nothing waits for it here, it looks at the offers in the exchange (travelExchange) and claims the oldest
# it may run: not this machine's own, not claimed, its home's waiter still there, no --exclusive one on a
# no-benchmarks machine, and the same tools: the offer names its fingerprint commands and their output at
# home, and this machine runs the same commands (again right before it claims). It then starts this clone's
# lock with the offer (heavy.cmd --run-travelled), which waits for the home's state, makes the checkout and
# runs the job in this machine's slot. What it does, or why it takes nothing, is in ROOT\worker.txt, which
# the status pages and the board show. Started at logon; one at a time.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'lock\config.ps1')
if (-not $travelExchange) { 'no "travelExchange" in the config: this machine runs no other machine''s jobs'; exit 0 }
$single = New-Object System.Threading.Mutex($false, "$mutexName-worker")
$owned = $false
try { $owned = $single.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

function Write-Shared([string]$path, [string]$text)
{
  for ($i = 0; ; $i++)
  {
    try { [IO.File]::WriteAllText($path, $text + "`r`n", (New-Object System.Text.UTF8Encoding($true))); return }
    catch { if ($i -ge 50) { throw }; Start-Sleep -Milliseconds 100 }
  }
}
function Alive([int]$id) { return $null -ne (Get-Process -Id $id -ErrorAction SilentlyContinue) }
. (Join-Path (Split-Path $PSScriptRoot) 'lock\travel.ps1')
$noteFile = Join-Path $root 'worker.txt'
$lastNote = ''
function Note([string]$text)
{
  if ($text -ne $script:lastNote) { try { Write-Shared $noteFile $text } catch { }; $script:lastNote = $text }
}

# This machine's output of a set of fingerprint commands, kept a minute.
$fingerprints = @{}
function Mine($commands, [bool]$fresh)
{
  $key = @($commands) -join "`n"
  $known = $fingerprints[$key]
  if ($fresh -or -not $known -or ((Get-Date) - $known.At).TotalSeconds -gt 60) { $known = @{ Text = (Fingerprint $commands); At = Get-Date }; $fingerprints[$key] = $known }
  return $known.Text
}

$lock = Join-Path (Split-Path $PSScriptRoot) 'lock\heavy.ps1'
while ($true)
{
  try
  {
    $first = Get-Content $schedule -TotalCount 1 -ErrorAction SilentlyContinue
    if ($first -and $first.Trim() -ne 'HOLD: no') { Note 'Takes no job while held.'; continue }
    if (Test-Path $flag) { Note 'Takes no job while a quiet flag stands.'; continue }
    $holder = ((Get-Content -Raw (Join-Path $root 'holder.txt') -ErrorAction SilentlyContinue) + '').Trim()
    if ($holder -match '^pid (\d+),' -and (Alive ([int]$matches[1]))) { continue }
    if (@(Get-ChildItem (Join-Path $root 'queue') -File -ErrorAction SilentlyContinue).Count -gt 0) { continue }
    if (-not (Test-Path $travelExchange)) { Note "Cannot see ${travelExchange}."; continue }
    $offers = @(Get-ChildItem $travelExchange -Filter '*.job.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $why = 'Waiting for jobs that may travel.'
    foreach ($o in $offers)
    {
      $id = $o.Name -replace '\.job\.json$', ''
      if (Test-Path (Travel-File $id 'claim')) { continue }
      if (-not (Fresh (Travel-File $id 'waiting'))) { continue }
      $text = Read-Small $o.FullName
      if (-not $text) { continue }
      $job = $text | ConvertFrom-Json
      if ($job.machine -eq $machine) { continue }
      if ($job.kind -eq 'exclusive' -and (Test-Path (Join-Path $root 'no-benchmarks'))) { continue }
      $differs = "Takes no job from $($job.machine): this machine's tools differ ($(@($job.fingerprintCommands) -join '; '))."
      if ($job.tools)
      {
        $toolWhy = Take-Tools $job.tools
        if ($toolWhy) { $why = "Takes no job from $($job.machine): $toolWhy."; continue }
      }
      if ($job.fingerprint -ne (Mine $job.fingerprintCommands $false)) { $why = $differs; continue }
      # (the tools now, not a minute ago: one updated since would run the job with other tools)
      if ($job.fingerprint -ne (Mine $job.fingerprintCommands $true)) { $why = $differs; continue }
      if (-not (Try-Claim (Travel-File $id 'claim') $machine)) { continue }
      $env:HEAVY_QUEUE_COMMAND = "--run-travelled `"$($o.FullName)`""
      try { Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$lock`"") | Out-Null }
      finally { Remove-Item Env:\HEAVY_QUEUE_COMMAND -ErrorAction SilentlyContinue }
      $why = "Runs $($job.label) for $($job.machine)."
      Note $why
      Start-Sleep -Seconds 5 # (its lock takes the slot before the next look)
      break
    }
    Note $why
  }
  catch { Note "Worker error: $($_.Exception.Message)" }
  finally { Start-Sleep -Seconds 5 }
}
