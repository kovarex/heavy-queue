# Lets the board's buttons open and close this machine. Every 15 seconds it asks the board (ROOT\publish.txt's
# address) whether this machine is open and writes the answer into line 1 of the hold file, which the lock
# reads before starting a job: "HOLD: no" when open, "HOLD: yes (closed on the board)" when closed or when
# the board cannot be reached. A closed machine starts no new heavy job; the one running finishes (Close) or
# is stopped at once (Close now: "stopped"): its command's processes are killed and the lock prints
# "heavy: STOPPED: ..." with a nonzero exit code, so whoever started it can run it again here or elsewhere.
# A board that cannot be reached holds new jobs but stops none. The rest of the hold file is kept. Started
# at logon (setup-machine.ps1 registers it); one at a time.
. (Join-Path (Split-Path $PSScriptRoot) 'lock\config.ps1')
$named = @(Get-Content (Join-Path $root 'publish.txt') -TotalCount 3 -ErrorAction SilentlyContinue)
$machine = if ($env:MACHINE_GATE_NAME) { $env:MACHINE_GATE_NAME } elseif ($named.Count -ge 3 -and $named[2].Trim()) { $named[2].Trim() } else { $env:COMPUTERNAME -replace '^PC-', '' } # (publish.txt's third line, as publish.ps1 reads it; the variable: for testing)
$mutex = New-Object System.Threading.Mutex($false, "$mutexName-machine-gate$($env:MACHINE_GATE_NAME)")
$held = $false
try { $held = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
if (-not $held) { exit 0 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
while ($true)
{
  $state = 'unreachable'
  try
  {
    $address = if ($env:MACHINE_GATE_ADDRESS) { $env:MACHINE_GATE_ADDRESS } else { (Get-Content (Join-Path $root 'publish.txt') -TotalCount 1).Trim() }
    $answer = Invoke-WebRequest -UseBasicParsing -Uri "$address`?state&machine=$machine$(if (Test-Path (Join-Path $root 'no-benchmarks')) { '&role=builds' })&now=$([Uri]::EscapeDataString((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')))" -TimeoutSec 20
    $state = $answer.Content.Trim()
  }
  catch { }
  $line = if ($state -eq 'open') { 'HOLD: no' } elseif ($state -eq 'unreachable') { 'HOLD: yes (the board cannot be reached)' } else { 'HOLD: yes (closed on the board)' }
  $lines = @(Get-Content $schedule -ErrorAction SilentlyContinue)
  if ($lines.Count -eq 0) { $lines = @($line, '# Line 1 is read by the heavy lock: "HOLD: yes" or "HOLD: no". machine-gate.ps1 writes it from the board.') }
  elseif ($lines[0] -ne $line) { $lines[0] = $line } else { $lines = $null }
  if ($lines) { New-Item -ItemType Directory -Force (Split-Path $schedule) | Out-Null; Set-Content -Path $schedule -Value $lines -Encoding UTF8 }
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
