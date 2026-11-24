# Jobs that travel (dot-sourced by heavy.ps1 and machine\worker.ps1). A machine whose folders other machines
# see at the same paths (travelRoots: shared, and mapped there by machine\setup-worker.ps1) offers its waiting
# jobs: an open, idle worker (a machine whose config names this one's data folder as its "home") claims the
# oldest one it may run and runs it in the same folder, so the job sees the same files, git included. Its
# output comes back to the waiting heavy.cmd as it is written, and so does its exit code: for the thread that
# started it, the job ran, only elsewhere. Everything goes through files in the home's data folder:
#   travel\ID.job.json   the offer: folder, command line, label, kind, thread, estimate, environment (no
#                        secrets), the tool versions (fingerprint); ID is the queue ticket's name
#   travel\ID.waiting    the home's waiter, every 3 s while it waits (a counter)
#   travel\ID.claim      the machine that runs it, made with CreateNew: whoever makes it first runs the job,
#                        the home itself included (it claims its own job before running it locally)
#   travel\ID.alive      the worker, every 5 s (a counter and what it is doing)
#   travel\ID.watch      the home's waiter, every 3 s while the job runs elsewhere (a counter)
#   travel\ID.out, .err  the job's output
#   travel\ID.exit       its exit code, then why when it did not finish ("1 stopped: ...")
# A job travels only when nothing it names is elsewhere: its folder and every path in its command line are
# under travelRoots (or samePaths, the same on every machine), it is not --local, and an --exclusive job
# (a timing run) only with --travel. A worker takes it only with the same fingerprint (the config's
# commands, such as the compiler's and Visual Studio's versions, give the same output there) and while no
# other job runs in that folder anywhere. A worker that stops answering for 90 s ends the job with
# "heavy: STOPPED"; a home waiter that goes away for 90 s makes the worker stop the job.

$travelDir = Join-Path $root 'travel'

# A path's normalised form for prefix tests: full, lower case, ending in '\'; $null when it is no path.
function Folder-Key([string]$path)
{
  try { return ([IO.Path]::GetFullPath($path.Replace('/', '\')).TrimEnd('\') + '\').ToLowerInvariant() }
  catch { return $null }
}

function Under-Any([string]$path, $folders)
{
  $key = Folder-Key $path
  if (-not $key) { return $false }
  foreach ($f in @($folders)) { $fk = Folder-Key "$f"; if ($fk -and $key.StartsWith($fk)) { return $true } }
  return $false
}

# One folder inside the other (or the same): two jobs in such folders never run at once on two machines.
function Folders-Overlap([string]$a, [string]$b)
{
  $ka = Folder-Key $a; $kb = Folder-Key $b
  return $ka -and $kb -and ($ka.StartsWith($kb) -or $kb.StartsWith($ka))
}

# Why this job may not travel, or '' when it may.
function Travel-Refusal([string]$cwd, [string]$commandLine, [bool]$isExclusive, [bool]$forbid, [bool]$allow)
{
  if ($forbid) { return '--local' }
  if (@($travelRoots).Count -eq 0) { return 'no travelRoots in the config' }
  if ($isExclusive -and -not $allow) { return 'an --exclusive job travels only with --travel' }
  if (-not (Under-Any $cwd $travelRoots)) { return "its folder is outside travelRoots" }
  $expanded = [Environment]::ExpandEnvironmentVariables($commandLine)
  foreach ($m in [regex]::Matches($expanded, '"([^"]*)"|([^\s"]+)'))
  {
    $token = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
    $paths = New-Object System.Collections.ArrayList
    if ($m.Groups[1].Success -and $token -match '^([A-Za-z]:[\\/]|\\\\)') { [void]$paths.Add($token) }
    else
    {
      foreach ($p in [regex]::Matches($token, '(?<![A-Za-z])([A-Za-z]:[\\/][^\s"<>|&()=,;]*)|(\\\\[^\s"<>|&()=,;]+)')) { [void]$paths.Add($p.Value) }
      if ($paths.Count -eq 0 -and $token -match '\.\.[\\/]') { [void]$paths.Add((Join-Path $cwd ($token -replace '^.*?=', ''))) }
    }
    foreach ($p in $paths)
    {
      if (-not (Under-Any $p $travelRoots) -and -not (Under-Any $p $samePaths)) { return "it names $p, outside travelRoots" }
    }
  }
  return ''
}

# The environment a travelling job takes along: everything but what names this machine, its own folders
# and its secrets (a worker keeps its own of those).
function Travel-Environment
{
  $skip = '^(COMPUTERNAME|USERDOMAIN.*|LOGONSERVER|SESSIONNAME|CLIENTNAME|NUMBER_OF_PROCESSORS|PROCESSOR_.*|TEMP|TMP|APPDATA|LOCALAPPDATA|USERPROFILE|HOMEDRIVE|HOMEPATH|PUBLIC|ProgramData|ALLUSERSPROFILE|OneDrive.*|windir|SystemRoot|SystemDrive|OS|ComSpec|PSModulePath|DriverData|HEAVY_QUEUE_.*)$'
  $secret = '(?i)(token|secret|passw|apikey|api_key|credential|auth|cookie|private|session_key)'
  $result = [ordered]@{}
  foreach ($e in [Environment]::GetEnvironmentVariables().GetEnumerator() | Sort-Object Name)
  {
    $n = [string]$e.Name
    if ($n -match $skip -or $n -match $secret -or ($heldVariable -and $n -eq $heldVariable)) { continue }
    $result[$n] = [string]$e.Value
  }
  return $result
}

# The fingerprint commands' output: two machines run each other's jobs only when theirs are the same.
function Fingerprint
{
  $parts = foreach ($c in @($fingerprintCommands))
  {
    # (cmd /s /c "LINE": the outer quotes go, a quoted program path in LINE stays as it is)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /s /c "' + $c + ' 2>&1"'
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($info)
    $output = $p.StandardOutput.ReadToEnd().Trim()
    $p.WaitForExit()
    "$c => $output"
  }
  return (@($parts) -join "`n")
}

function Travel-File([string]$id, [string]$ext) { return Join-Path $script:travelHere "$id.$ext" }

function Try-Claim([string]$path, [string]$who)
{
  try
  {
    $fs = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $bytes = [Text.Encoding]::UTF8.GetBytes($who); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
    return $true
  }
  catch [System.IO.IOException] { return $false }
}

function Read-Small([string]$path)
{
  for ($i = 0; $i -lt 5; $i++)
  {
    try { if (-not (Test-Path $path)) { return $null }; return ([IO.File]::ReadAllText($path)).Trim() }
    catch { Start-Sleep -Milliseconds 100 }
  }
  return $null
}

# Copies what a file gained since $position to $sink; returns the new position.
function Pump([string]$path, [long]$position, $sink)
{
  if (-not (Test-Path $path)) { return $position }
  try
  {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try
    {
      [void]$fs.Seek($position, [IO.SeekOrigin]::Begin)
      $buffer = New-Object byte[] 65536
      while (($n = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) { $sink.Write($buffer, 0, $n); $position += $n }
      $sink.Flush()
    }
    finally { $fs.Close() }
  }
  catch { }
  return $position
}

# A heartbeat file other machines watch: a counter that changes. Its age is told by seeing it change, never
# by comparing clocks.
$script:beats = @{}
function Beat([string]$path, [string]$what)
{
  $script:beats[$path] = 1 + [int]$script:beats[$path]
  try { Write-Shared $path "$($script:beats[$path]) $what" } catch { }
}

# Whether a heartbeat file changed in the last $travelStale seconds, as this process has watched it
# (first seen: fresh).
$script:seen = @{}
function Fresh([string]$path)
{
  $text = Read-Small $path
  $now = Get-Date
  $last = $script:seen[$path]
  if (-not $last -or $last.Text -ne $text) { $script:seen[$path] = @{ Text = $text; Since = $now }; return $true }
  return (($now - $last.Since).TotalSeconds -lt $travelStale)
}

function Remove-Travel([string]$id)
{
  foreach ($ext in 'job.json', 'stays', 'parked', 'waiting', 'claim', 'alive', 'watch', 'out', 'err', 'exit')
  {
    Remove-Item (Travel-File $id $ext) -Force -ErrorAction SilentlyContinue
  }
}

# The travel files of this machine's jobs whose waiter died: gone, unless a worker still runs the job (it
# notices that nobody watches, stops it and writes its exit; the next clearing takes them).
function Clear-Dead-Offers
{
  foreach ($f in @(Get-ChildItem $travelDir -File -ErrorAction SilentlyContinue))
  {
    if ($f.Name -notmatch '^(\d{20})-(\d+)\.') { continue }
    $id = "$($matches[1])-$($matches[2])"
    if (Alive ([int]$matches[2])) { continue }
    $who = Read-Small (Travel-File $id 'claim')
    if ($who -and $who -ne $machine -and -not (Test-Path (Travel-File $id 'exit'))) { continue }
    Remove-Travel $id
  }
}

# On a worker, the lock that runs a travelled job and everything it starts are in one job object that kills
# them all when the lock's process ends: a lock killed mid-job (its home then reports it stopped, and the
# thread runs it again) leaves nothing running in the shared folder. At the job's normal end the kill is
# switched off, so what it leaves running on purpose (a compile server) stays.
function Kill-With-Me([bool]$on)
{
  if (-not ('HeavyQueueJob' -as [type]))
  {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HeavyQueueJob
{
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
  [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
  [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [StructLayout(LayoutKind.Sequential)] struct Basic { public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] struct Counters { public ulong A, B, C, D, E, F; }
  [StructLayout(LayoutKind.Sequential)] struct Extended { public Basic Basic; public Counters Io; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }
  static IntPtr job = IntPtr.Zero;
  public static bool Set(bool killOnClose)
  {
    if (job == IntPtr.Zero)
    {
      job = CreateJobObject(IntPtr.Zero, null);
      if (job == IntPtr.Zero || !AssignProcessToJobObject(job, GetCurrentProcess())) return false;
    }
    Extended e = new Extended();
    e.Basic.LimitFlags = killOnClose ? 0x2000u : 0u; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    int length = Marshal.SizeOf(typeof(Extended));
    IntPtr p = Marshal.AllocHGlobal(length);
    try { Marshal.StructureToPtr(e, p, false); return SetInformationJobObject(job, 9, p, (uint)length); }
    finally { Marshal.FreeHGlobal(p); }
  }
}
'@
  }
  return [HeavyQueueJob]::Set($on)
}

# The home's side once a worker claimed the job: the output as it comes, then the exit code.
function Follow-Remote([string]$id, [string]$worker)
{
  [Console]::Error.WriteLine("heavy: $worker runs this job (it travelled from $machine).")
  $stdout = [Console]::OpenStandardOutput(); $stderr = [Console]::OpenStandardError()
  $outAt = 0L; $errAt = 0L
  $alive = Travel-File $id 'alive'
  $claimedAt = Get-Date
  $doing = ''
  while ($true)
  {
    Beat (Travel-File $id 'watch') 'following'
    $state = (Read-Small $alive) -replace '^\d+\s*', ''
    if ($state -and $state -ne $doing) { [Console]::Error.WriteLine("heavy: $($worker): $state"); $doing = $state }
    $outAt = Pump (Travel-File $id 'out') $outAt $stdout
    $errAt = Pump (Travel-File $id 'err') $errAt $stderr
    $exit = Read-Small (Travel-File $id 'exit')
    if ($exit)
    {
      Start-Sleep -Milliseconds 300
      $outAt = Pump (Travel-File $id 'out') $outAt $stdout
      $errAt = Pump (Travel-File $id 'err') $errAt $stderr
      $code = if ($exit -match '^(-?\d+)') { [int]$matches[1] } else { 1 }
      [Console]::Error.WriteLine("heavy: $worker finished it: exit $code.")
      return $code
    }
    $started = Test-Path $alive
    if ((-not $started -and ((Get-Date) - $claimedAt).TotalSeconds -gt $travelStale + 30) -or ($started -and -not (Fresh $alive)))
    {
      [Console]::Error.WriteLine("heavy: STOPPED: $worker stopped answering at $(Get-Date -Format 'HH:mm:ss'). Run it again.")
      return 1
    }
    Start-Sleep -Seconds 1
  }
}
