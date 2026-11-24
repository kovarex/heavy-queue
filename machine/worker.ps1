# A worker: runs its home machine's waiting jobs that may travel (lock\travel.ps1) while this machine is
# open and idle. The config's "home" is the home's data folder as this machine sees it (its folders are
# shared and mapped here at the same paths by setup-worker.ps1). Every 5 seconds, while this machine's hold
# file says "HOLD: no", no quiet flag stands, its slot is free and nothing waits for it here, it claims the
# oldest offer it may run and starts this clone's lock with it (heavy.cmd --run-travelled), which runs it
# in this machine's slot. An offer it may run: not claimed, its home's waiter still there, the same
# fingerprint as this machine's, no --exclusive one on a no-benchmarks machine, and no other job running in
# its folder (or one inside the other) on any machine. What it does, or why it takes nothing, is in
# ROOT\worker.txt, which the status pages and the board show. Started at logon; one at a time.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'lock\config.ps1')
if (-not $homeRoot) { 'no "home" in the config: this machine runs no other machine''s jobs'; exit 0 }
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
$homeTravel = Join-Path $homeRoot 'travel'
$script:travelHere = $homeTravel
$noteFile = Join-Path $root 'worker.txt'
$lastNote = ''
function Note([string]$text)
{
  if ($text -ne $script:lastNote) { try { Write-Shared $noteFile $text } catch { }; $script:lastNote = $text }
}

$mine = ''
$mineAt = [DateTime]::MinValue
$lock = Join-Path (Split-Path $PSScriptRoot) 'lock\heavy.ps1'
while ($true)
{
  try
  {
    $first = Get-Content $schedule -TotalCount 1 -ErrorAction SilentlyContinue
    if ($first -and $first.Trim() -ne 'HOLD: no') { Note "Takes no job from $homeRoot while held."; continue }
    if (Test-Path $flag) { Note 'Takes no job while a quiet flag stands.'; continue }
    $holder = ((Get-Content -Raw (Join-Path $root 'holder.txt') -ErrorAction SilentlyContinue) + '').Trim()
    if ($holder -match '^pid (\d+),' -and (Alive ([int]$matches[1]))) { continue }
    if (@(Get-ChildItem (Join-Path $root 'queue') -File -ErrorAction SilentlyContinue).Count -gt 0) { continue }
    if (-not (Test-Path $homeTravel)) { Note "Cannot see ${homeTravel}: is the home's share mapped?"; continue }
    $offers = @(Get-ChildItem $homeTravel -Filter '*.job.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($offers.Count -eq 0) { Note "Waiting for jobs from $homeRoot."; continue }
    if (((Get-Date) - $mineAt).TotalSeconds -gt 60) { $mine = Fingerprint; $mineAt = Get-Date }
    # The folders and threads in use: the home's running job and every job running on some machine for it.
    # A thread's jobs ran one after another on its home; they still do, wherever they run.
    $busy = New-Object System.Collections.ArrayList
    $busyThreads = New-Object System.Collections.ArrayList
    $homeHolder = ((Get-Content -Raw (Join-Path $homeRoot 'holder.txt') -ErrorAction SilentlyContinue) + '').Trim()
    if ($homeHolder -match ', cwd (.*?)(?:, thread (.*?))?(?:, estimate \d+s)?: ')
    {
      [void]$busy.Add($matches[1])
      if ($matches[2]) { [void]$busyThreads.Add($matches[2]) }
    }
    foreach ($c in @(Get-ChildItem $homeTravel -Filter '*.claim' -File -ErrorAction SilentlyContinue))
    {
      $id = $c.Name -replace '\.claim$', ''
      if (Test-Path (Travel-File $id 'exit')) { continue }
      $text = Read-Small (Travel-File $id 'job.json')
      if (-not $text) { continue }
      $running = $text | ConvertFrom-Json
      [void]$busy.Add($running.cwd)
      if ($running.thread) { [void]$busyThreads.Add($running.thread) }
    }
    $why = ''
    foreach ($o in $offers)
    {
      $id = $o.Name -replace '\.job\.json$', ''
      if (Test-Path (Travel-File $id 'claim')) { continue }
      if (-not (Fresh (Travel-File $id 'waiting'))) { continue }
      $text = Read-Small $o.FullName
      if (-not $text) { continue }
      $job = $text | ConvertFrom-Json
      if ($job.kind -eq 'exclusive' -and (Test-Path (Join-Path $root 'no-benchmarks'))) { continue }
      if ($job.fingerprint -ne $mine) { $why = "Takes no job from $($job.machine): its tools differ from this machine's ($($fingerprintCommands -join '; '))."; continue }
      $overlap = $job.thread -and $busyThreads.Contains($job.thread)
      foreach ($b in $busy) { if (Folders-Overlap $b $job.cwd) { $overlap = $true } }
      if ($overlap) { continue }
      # (the tools now, not a minute ago: one updated since would run the job with other tools)
      $mine = Fingerprint; $mineAt = Get-Date
      if ($job.fingerprint -ne $mine) { $why = "Takes no job from $($job.machine): its tools differ from this machine's ($($fingerprintCommands -join '; '))."; continue }
      if (-not (Try-Claim (Travel-File $id 'claim') $machine)) { continue }
      $env:HEAVY_QUEUE_COMMAND = "--run-travelled `"$($o.FullName)`""
      try { Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$lock`"") | Out-Null }
      finally { Remove-Item Env:\HEAVY_QUEUE_COMMAND -ErrorAction SilentlyContinue }
      Note "Runs $($job.label) for $($job.machine)."
      $why = ''
      Start-Sleep -Seconds 5 # (its lock takes the slot before the next look)
      break
    }
    if ($why) { Note $why }
  }
  catch { Note "Worker error: $($_.Exception.Message)" }
  finally { Start-Sleep -Seconds 5 }
}
