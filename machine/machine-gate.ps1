# Lets the board's buttons open and close this machine. Every 15 seconds it asks the board (ROOT\publish.txt's
# address) whether this machine (the config's machine name) is open, and writes the answer into line 1 of
# the hold file, which the lock reads before starting a job: "HOLD: no" when open, "HOLD: yes (closed on
# the board)" when closed; a board that cannot be reached, or gives no answer it knows, changes nothing. A closed machine starts no new heavy job; the
# one running finishes (Close) or is stopped at once (Close now: "stopped"): its command's processes are
# killed and the lock prints "heavy: STOPPED: ..." with a nonzero exit code, so whoever started it can run
# it again here or elsewhere. A board that cannot be reached neither holds nor stops anything. The rest of the
# hold file is kept. Started at logon (setup-machine.ps1 registers it); one at a time.
. (Join-Path (Split-Path $PSScriptRoot) 'lock\config.ps1')
$mutex = New-Object System.Threading.Mutex($false, "$mutexName-machine-gate")
$held = $false
try { $held = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
if (-not $held) { exit 0 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
while ($true)
{
  $state = 'unreachable'
  try
  {
    $address = (Get-Content (Join-Path $root 'publish.txt') -TotalCount 1).Trim()
    $answer = Invoke-WebRequest -UseBasicParsing -Uri "$address`?state&machine=$([Uri]::EscapeDataString($machine))$(if (Test-Path (Join-Path $root 'no-benchmarks')) { '&role=builds' })&now=$([Uri]::EscapeDataString((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')))" -TimeoutSec 20
    $state = $answer.Content.Trim()
  }
  catch { }
  # (only the board's own answer changes the hold: a board that cannot be reached, or answers something else,
  # leaves the machine as it was; it once held every job for half an hour, 2026-11-28)
  $line = if ($state -eq 'open') { 'HOLD: no' } elseif ($state -eq 'closed' -or $state -eq 'stopped') { 'HOLD: yes (closed on the board)' } else { $null }
  $lines = @(Get-Content $schedule -ErrorAction SilentlyContinue)
  if (-not $line) { $lines = $null }
  elseif ($lines.Count -eq 0) { $lines = @($line, '# Line 1 is read by the heavy lock: "HOLD: yes" or "HOLD: no". machine-gate.ps1 writes it from the board.') }
  elseif ($lines[0] -ne $line) { $lines[0] = $line } else { $lines = $null }
  if ($lines)
  {
    # (a hold file it cannot write leaves the machine held whatever the board says: said in ROOT\gate-error.txt,
    # else in this user's temp folder, and on the next try)
    try { New-Item -ItemType Directory -Force (Split-Path $schedule) | Out-Null; Set-Content -Path $schedule -Value $lines -Encoding UTF8 -ErrorAction Stop }
    catch
    {
      $message = "$(Get-Date -Format s) the gate cannot write ${schedule}: $($_.Exception.Message)"
      try { Set-Content -Path (Join-Path $root 'gate-error.txt') -Value $message -ErrorAction Stop } catch { Set-Content -Path (Join-Path $env:TEMP 'heavy-queue-gate-error.txt') -Value $message -ErrorAction SilentlyContinue }
    }
  }
  if ($state -eq 'stopped')
  {
    $holder = ((Get-Content -Raw (Join-Path $root 'holder.txt') -ErrorAction SilentlyContinue) + '').Trim()
    if ($holder -match '^pid (\d+),' -and (Get-Process -Id ([int]$matches[1]) -ErrorAction SilentlyContinue))
    {
      $id = [int]$matches[1]
      Set-Content -Path (Join-Path $root "stopped-$id.txt") -Value "$machine was closed on the board at $(Get-Date -Format 'HH:mm:ss')." -Encoding UTF8
      foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $id")) { taskkill /T /F /PID $child.ProcessId 2>&1 | Out-Null }
    }
  }
  Start-Sleep -Seconds 15
}
