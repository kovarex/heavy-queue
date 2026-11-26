# Jobs that travel (dot-sourced by heavy.ps1 and machine\worker.ps1). A waiting job may run on another
# machine (a worker) with the same tools while it waits here. Its folders (Travel-Plan: the git checkout or
# folder it runs in, and the folders its command line and the scripts it names name) travel with it: the
# worker keeps its own copy of each at the same path, and only what differs from that copy goes over (build
# outputs and uncommitted files included; a git checkout's git state by git), so a second job from the same
# folder moves little. Its output comes back to the waiting heavy.cmd as it is written, then the files it made,
# changed or deleted in those folders, then its exit code. Everything goes through files in the exchange
# folder that every machine sees (travelExchange, a NAS share):
#   ID.job.json      the offer: machine, folder, command line, label, kind, thread, estimate, environment
#                    (no secrets), the tool versions (the fingerprint commands and their output), the folders;
#                    ID is the home's queue ticket's name
#   ID.waiting       the home's waiter, every 3 s while it waits and while it packs (a counter)
#   ID.claim         the machine that runs it, made with CreateNew: whoever makes it first runs the job, the
#                    home included (it claims its own job before running it locally)
#   ID.have.N, .have what the worker's copy of folder N holds (gzipped list), then how many folders
#   ID.fN.tar, .del  the files of folder N that differ there (to write) and that are not here (to delete),
#   ID.fN.bundle     a checkout's commits no remote has,
#   ID.state.json    per folder: which of those exist, its git state (commit, branch, remotes, remote
#                    branches); then
#   ID.ready         (or ID.refused, the reason the job runs at home after all)
#   ID.alive         the worker, every 5 s (a counter and what it is doing)
#   ID.watch         the home's waiter, every 3 s while the job runs elsewhere (a counter)
#   ID.out, ID.err   the job's output
#   ID.bN.tar, .del  the files the job made or changed, and deleted, in folder N
#   ID.exit          its exit code, then why when it did not finish ("1 stopped: ...")
# ROOT\travel (this machine's own) keeps why a waiting job stays home (ID.stays), for the pages.
# A worker takes a job only with the same fingerprint, and no --exclusive one on a no-benchmarks machine. A
# worker that stops answering for travelStale seconds ends the job with "heavy: STOPPED"; a home waiter that
# goes away for as long makes the worker stop the job.

$travelDir = Join-Path $root 'travel'

# Removes a file if it is there, never failing: several waiters clean the same stale queue file, and
# Remove-Item on one another just removed threw a terminating error past -ErrorAction (five benchmark jobs
# died of it on 2026-11-26 at 03:12).
function Drop-File([string]$path) { if ($path) { try { [IO.File]::Delete($path) } catch { } } }

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

# A native command's output and exit code, nothing thrown (git writes progress to stderr).
function Run-Quiet([string]$exe, [string[]]$arguments, [string]$folder = '')
{
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $exe
  $info.Arguments = (@($arguments | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
  $info.UseShellExecute = $false
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.CreateNoWindow = $true
  $info.StandardOutputEncoding = [Text.Encoding]::UTF8 # (git writes UTF-8)
  $info.StandardErrorEncoding = [Text.Encoding]::UTF8
  if ($folder) { $info.WorkingDirectory = $folder }
  $p = [System.Diagnostics.Process]::Start($info)
  $errTask = $p.StandardError.ReadToEndAsync()
  $out = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $errTask.Result }
}

function Git([string]$folder, [string[]]$arguments) { return Run-Quiet 'git' (@('-C', $folder) + $arguments) }

# The top folder of the git checkout a folder is in, or ''.
function Git-Top([string]$folder)
{
  $r = Git $folder @('rev-parse', '--show-toplevel')
  if ($r.Code -ne 0) { return '' }
  return $r.Out.Trim().Replace('/', '\')
}

# The folders a job uses, which travel with it: its own (the git checkout it is in, or its folder) and each
# folder the command line names, and the scripts it names name (one level down). A path under one of
# travelFolderRoots stands for that root's folder it is in (C:\kpp-sandbox\scratch\x\y: C:\kpp-sandbox\scratch\x);
# else for its git checkout, else for its own folder. Paths under samePaths are the same on every machine and
# do not travel; only paths that exist here count. Returns the folders, or the reason the job stays here.
function Travel-Folder([string]$path)
{
  if (Under-Any $path $samePaths) { return '' }
  # (the lock's own folders: its data folder and its clone are this machine's, never a job's)
  if (Under-Any $path @($root, (Split-Path $PSScriptRoot))) { return '' }
  $key = Folder-Key $path
  if (-not $key) { return '' }
  foreach ($r in @($travelFolderRoots))
  {
    $rk = Folder-Key "$r"
    if ($rk -and $key.StartsWith($rk))
    {
      $rest = $key.Substring($rk.Length).Trim('\')
      if (-not $rest) { return "!it names $r itself" }
      $first = ($rest -split '\\')[0]
      return ([IO.Path]::GetFullPath($path.Replace('/', '\'))).Substring(0, $rk.Length + $first.Length)
    }
  }
  $folder = if (Test-Path -LiteralPath $path -PathType Container) { $path } else { Split-Path $path }
  $top = Git-Top $folder
  if ($top) { $folder = $top }
  $folder = [IO.Path]::GetFullPath($folder).TrimEnd('\')
  if (@($folder -split '\\' | Where-Object { $_ }).Count -lt 3) { return "!it names $path, whose folder $folder is too wide to travel" }
  return $folder
}

function Travel-Paths([string]$text, [string]$cwd)
{
  $paths = New-Object System.Collections.ArrayList
  $expanded = [Environment]::ExpandEnvironmentVariables($text)
  foreach ($m in [regex]::Matches($expanded, '"([^"]*)"|([^\s"]+)'))
  {
    $token = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
    if ($m.Groups[1].Success -and $token -match '^([A-Za-z]:[\\/]|\\\\)') { [void]$paths.Add($token); continue }
    $found = $false
    foreach ($p in [regex]::Matches($token, '(?<![A-Za-z])([A-Za-z]:[\\/][^\s"''<>|&()=,;*?]*)|(\\\\[^\s"''<>|&()=,;*?]+)')) { $v = $p.Value.TrimEnd('.', '\', '/'); if ($v -match '^[A-Za-z]:$') { $v += '\' }; [void]$paths.Add($v); $found = $true }
    if (-not $found -and $cwd -and $token -match '[\\/]' -and $token -notmatch '^[-/]') { [void]$paths.Add((Join-Path $cwd ($token -replace '^.*?=', ''))) }
  }
  return ,$paths
}

function Travel-Plan([string]$cwd, [string]$commandLine, [bool]$forbid, [bool]$allow)
{
  if ($forbid) { return [pscustomobject]@{ Why = '--local'; Folders = @() } }
  if (-not $allow) { return [pscustomobject]@{ Why = 'it travels only with --travel here (travelByDefault, travelExclusive in the config)'; Folders = @() } }
  if (-not $travelExchange) { return [pscustomobject]@{ Why = 'no travelExchange in the config'; Folders = @() } }
  $folders = New-Object System.Collections.ArrayList
  $todo = New-Object System.Collections.ArrayList
  [void]$todo.Add($cwd)
  $scripts = @()
  foreach ($p in (Travel-Paths $commandLine $cwd)) { [void]$todo.Add($p) }
  # (the scripts the command line names, read for the paths they name: one level, 64 KB each at most)
  foreach ($p in @($todo))
  {
    if ($p -match '\.(cmd|bat|ps1|py|sh)$' -and (Test-Path -LiteralPath $p -PathType Leaf) -and (Get-Item -LiteralPath $p).Length -lt 65536)
    {
      foreach ($q in (Travel-Paths ([IO.File]::ReadAllText($p)) '')) { [void]$todo.Add($q) }
    }
  }
  foreach ($p in $todo)
  {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $f = Travel-Folder $p
    if (-not $f) { continue }
    if ($f.StartsWith('!')) { return [pscustomobject]@{ Why = $f.Substring(1); Folders = @() } }
    if (-not ($folders | Where-Object { $_ -eq $f })) { [void]$folders.Add($f) }
  }
  # (a folder inside another travels with it)
  $kept = @($folders | Where-Object { $f = $_; -not ($folders | Where-Object { $_ -ne $f -and (Folder-Key $f).StartsWith((Folder-Key $_)) }) })
  return [pscustomobject]@{ Why = ''; Folders = $kept }
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

# The fingerprint commands' output: two machines run each other's jobs only when theirs are the same. A
# worker runs the commands the offer names.
function Fingerprint($commands = $fingerprintCommands)
{
  $parts = foreach ($c in @($commands))
  {
    # (cmd /s /c "LINE": the outer quotes go, a quoted program path in LINE stays as it is)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /s /c "' + $c + ' 2>&1"'
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($info)
    # (30 s at most: a command that hangs, such as a WSL that does not answer, makes the fingerprint differ)
    $read = $p.StandardOutput.ReadToEndAsync()
    if ($read.Wait(30000)) { $output = $read.Result.Trim(); $p.WaitForExit() }
    else { $output = 'did not answer in 30 s'; try { & taskkill /F /T /PID $p.Id 2>&1 | Out-Null } catch { } }
    "$c => $output"
  }
  return (@($parts) -join "`n")
}

# This machine's fingerprint for its offers, worked out by one waiter every 5 minutes and read by the others
# (ROOT\fingerprint.txt): each of 30 waiters running the commands (kpp, clang, python, WSL) every 5 minutes
# was most of what waiting cost.
function Shared-Fingerprint
{
  $file = Join-Path $root 'fingerprint.txt'
  try
  {
    $info = Get-Item -LiteralPath $file -ErrorAction Stop
    if (((Get-Date) - $info.LastWriteTime).TotalMinutes -lt 5) { $text = [IO.File]::ReadAllText($file); if ($text) { return $text } }
  }
  catch { }
  $text = Fingerprint
  try { Write-Shared $file $text } catch { }
  return $text
}

# Tools a worker takes from its home (travelTools, such as a compiler installed from an unreleased build): a
# folder's identity is a hash of its files' names, sizes and times. The home puts a copy of each folder into
# EXCHANGE\tools\NAME-ID once; a worker mirrors it into its own copy, ROOT\tools\PATH (stopping what runs from
# there first), when the offer's ID differs from the copy's (.heavy-queue-tool); a travelled job and its
# fingerprint run with that copy in place of the folder (Tool-Rewrite, Tool-PathVariable).
$toolMark = '.heavy-queue-tool'
function Tool-Id([string]$folder)
{
  $sha = [Security.Cryptography.SHA256]::Create()
  $text = New-Object System.Text.StringBuilder
  $base = (Resolve-Path -LiteralPath $folder).Path.TrimEnd('\').Length + 1
  foreach ($f in @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $toolMark } | Sort-Object FullName))
  {
    [void]$text.Append("$($f.FullName.Substring($base))|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)`n")
  }
  $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text.ToString()))
  return (-join ($hash[0..7] | ForEach-Object { $_.ToString('x2') }))
}

function Tool-Copy([string]$folder, [string]$id) { return Join-Path $travelExchange ("tools\" + ((Split-Path -Leaf $folder) -replace '[^A-Za-z0-9.-]', '_') + "-$id") }

# The home's side, at offer time: each travelTools folder with its identity, its copy in the exchange made
# when missing (robocopy, then a done file).
function Offer-Tools
{
  $tools = @()
  foreach ($folder in @($travelTools))
  {
    if (-not (Test-Path -LiteralPath $folder)) { continue }
    # (one waiter hashes the folder every 5 minutes, the others read its answer: ROOT	ool-ID-NAME.txt)
    $cache = Join-Path $root ('tool-id-' + (($folder -replace '[:\\/ ]+', '_').Trim('_')) + '.txt')
    $id = $null
    try { $ci = Get-Item -LiteralPath $cache -ErrorAction Stop; if (((Get-Date) - $ci.LastWriteTime).TotalMinutes -lt 5) { $id = [IO.File]::ReadAllText($cache).Trim() } } catch { }
    if (-not $id) { $id = Tool-Id $folder; try { Write-Shared $cache $id } catch { } }
    $copy = Tool-Copy $folder $id
    if (-not (Test-Path -LiteralPath (Join-Path $copy '.done')))
    {
      & robocopy $folder $copy /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS /NP /XF $toolMark | Out-Null
      if ($LASTEXITCODE -ge 8) { continue } # (no copy: workers keep their own and compare tools as they are)
      Set-Content -LiteralPath (Join-Path $copy '.done') -Value $id -Encoding ascii
    }
    $tools += [ordered]@{ path = $folder; id = $id }
  }
  return ,$tools
}

# The worker's side, before it compares tools for an offer: its own copies (ROOT\tools\PATH, never the
# folder itself, which this machine's own programs use: Visual Studio keeps C:\Program Files\kpp\kpp.exe
# running, 2026-11-25) brought to the offer's IDs. Returns '' or why not (the note on the board).
function Tool-Here([string]$path) { return Join-Path $root ('tools\' + (($path -replace '[:\\/]+', '_').Trim('_'))) }

# A travelled job's text (its command line, its environment's values, the fingerprint commands) with each
# tool folder's path turned into the worker's copy of it.
function Tool-Rewrite([string]$text, $tools)
{
  foreach ($t in @($tools)) { if ($t) { $text = $text -ireplace ([regex]::Escape(([string]$t.path).TrimEnd([char]92)) + '(?=[\\";/ ]|$)'), (Tool-Here $t.path).Replace('$', '$$') } }
  return $text
}

# A PATH for a travelled job or its fingerprint: the home's tool folders turned into the worker's copies,
# and those copies first when PATH did not name the folder.
function Tool-PathVariable([string]$value, $tools)
{
  $value = Tool-Rewrite $value $tools
  $parts = @($value -split ';')
  foreach ($t in @($tools)) { if ($t -and -not ($parts -contains (Tool-Here $t.path))) { $value = (Tool-Here $t.path) + ';' + $value } }
  return $value
}

function Take-Tools($tools)
{
  foreach ($t in @($tools))
  {
    $here = Tool-Here $t.path
    $mark = Join-Path $here $toolMark
    if ((Read-Small $mark) -eq $t.id) { continue }
    $copy = Tool-Copy $t.path $t.id
    if (-not (Test-Path -LiteralPath (Join-Path $copy '.done'))) { return "the home's copy of $($t.path) is not in the exchange" }
    # (what runs from this copy holds its files: a compile server from an earlier job)
    $key = (Folder-Key $here)
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and (Folder-Key (Split-Path $_.ExecutablePath)).StartsWith($key) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    New-Item -ItemType Directory -Force $here | Out-Null
    # (robocopy's whole output in ROOT\tool-copy.log; its first error line on the board)
    $log = @(& robocopy $copy $here /MIR /R:3 /W:2 /NDL /NJH /NP /XF '.done' $toolMark 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    Set-Content -LiteralPath (Join-Path $root 'tool-copy.log') -Value (@("$(Get-Date -Format s) robocopy $copy ${here}: exit $code") + $log) -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($code -ge 8)
    {
      $error1 = @($log | Where-Object { $_ -match 'ERROR \d+' } | Select-Object -First 1)
      $why = if (@($log | Where-Object { $_ -match 'ERROR 32 ' }).Count) { 'a process holds its files' } else { 'see tool-copy.log' }
      return "could not copy $($t.path) from the exchange into $here (robocopy $code, $why$(if ($error1) { ': ' + $error1[0].Trim() }))"
    }
    Set-Content -LiteralPath $mark -Value $t.id -Encoding ascii
  }
  return ''
}

# ID.stays is this machine's own (ROOT\travel), every other file is in the exchange.
function Travel-File([string]$id, [string]$ext)
{
  if ($ext -eq 'stays') { return Join-Path $travelDir "$id.$ext" }
  return Join-Path $travelExchange "$id.$ext"
}

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
  Remove-Item (Join-Path $travelExchange "$id.*") -Force -ErrorAction SilentlyContinue
  Drop-File (Travel-File $id 'stays')
}

# The travel files of this machine's jobs whose waiter died: gone, unless a worker still runs the job (it
# notices that nobody watches, stops it and writes its exit; the next clearing takes them).
function Clear-Dead-Offers
{
  foreach ($f in @(Get-ChildItem $travelExchange -Filter '*.job.json' -File -ErrorAction SilentlyContinue) + @(Get-ChildItem $travelDir -Filter '*.stays' -File -ErrorAction SilentlyContinue))
  {
    if ($f.Name -notmatch '^(\d{20})-(\d+)\.') { continue }
    $id = "$($matches[1])-$($matches[2])"
    $owner = $f.Name.EndsWith('.stays') -or ((Read-Small $f.FullName) -match ('"machine":"' + [regex]::Escape($machine) + '"'))
    if (-not $owner -or (Alive ([int]$matches[2]))) { continue }
    $who = Read-Small (Travel-File $id 'claim')
    if ($who -and $who -ne $machine -and -not (Test-Path (Travel-File $id 'exit'))) { continue }
    Remove-Travel $id
  }
}

# Folder lists: every file under a folder with its size and time (seconds: what tar keeps), but the folder's
# own .git (a checkout's git state travels by git) and what reparse points lead to (a junction is never
# followed). Kept gzipped in the exchange: ID.have.N (the worker's copy of folder N before the job).
if (-not ('HeavyQueueFiles' -as [type]))
{
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;
public static class HeavyQueueFiles
{
  // null when the folder holds more than max files.
  public static Dictionary<string, string> Scan(string root, int max)
  {
    var files = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    root = Path.GetFullPath(root).TrimEnd('\\');
    if (!Directory.Exists(root)) return files;
    int baseLength = root.Length + 1;
    var stack = new Stack<string>();
    stack.Push(root);
    while (stack.Count > 0)
    {
      string dir = stack.Pop();
      bool top = dir.Length == root.Length;
      foreach (FileSystemInfo e in new DirectoryInfo(dir).EnumerateFileSystemInfos())
      {
        if ((e.Attributes & FileAttributes.ReparsePoint) != 0) continue;
        if (top && string.Equals(e.Name, ".git", StringComparison.OrdinalIgnoreCase)) continue;
        if ((e.Attributes & FileAttributes.Directory) != 0) { stack.Push(e.FullName); continue; }
        FileInfo f = (FileInfo)e;
        files[f.FullName.Substring(baseLength)] = f.Length + "|" + (f.LastWriteTimeUtc.Ticks / 10000000);
        if (files.Count > max) return null;
      }
    }
    return files;
  }
  public static void Write(string path, Dictionary<string, string> files)
  {
    using (var gz = new GZipStream(File.Create(path), CompressionLevel.Fastest))
    using (var w = new StreamWriter(gz, new UTF8Encoding(false)))
      foreach (var kv in files) { w.Write(kv.Key); w.Write('\t'); w.Write(kv.Value); w.Write('\n'); }
  }
  public static Dictionary<string, string> Read(string path)
  {
    var files = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    if (!File.Exists(path)) return files;
    using (var gz = new GZipStream(File.OpenRead(path), CompressionMode.Decompress))
    using (var r = new StreamReader(gz, new UTF8Encoding(false)))
    {
      string line;
      while ((line = r.ReadLine()) != null) { int t = line.IndexOf('\t'); if (t > 0) files[line.Substring(0, t)] = line.Substring(t + 1); }
    }
    return files;
  }
  // The files of mine that theirs lacks or has otherwise (to send), and theirs that mine lacks (to delete).
  public static string[][] Diff(Dictionary<string, string> mine, Dictionary<string, string> theirs, out long bytes)
  {
    var send = new List<string>(); var delete = new List<string>(); bytes = 0;
    foreach (var kv in mine)
    {
      string v;
      if (!theirs.TryGetValue(kv.Key, out v) || v != kv.Value) { send.Add(kv.Key); bytes += long.Parse(kv.Value.Substring(0, kv.Value.IndexOf('|'))); }
    }
    foreach (var k in theirs.Keys) if (!mine.ContainsKey(k)) delete.Add(k);
    return new string[][] { send.ToArray(), delete.ToArray() };
  }
}
'@
}

# A program run to its end with a heartbeat file beaten every 2 s meanwhile (a big tar takes minutes; the
# other side would count this one gone after travelStale seconds otherwise).
function Run-Beating([string]$exe, [string[]]$arguments, [string]$beatFile, [string]$what)
{
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $exe
  $info.Arguments = (@($arguments | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
  $info.UseShellExecute = $false
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($info)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  while (-not $p.WaitForExit(2000)) { Beat $beatFile $what }
  $p.WaitForExit()
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}

function Write-List([string]$path, $names)
{
  [IO.File]::WriteAllText($path, ((@($names) | ForEach-Object { $_.Replace('\', '/') }) -join "`0"), (New-Object System.Text.UTF8Encoding($false)))
}

# A worker's folder for one of the home's: the same path, or under travelCheckouts (testing on one computer).
function Worker-Path([string]$path)
{
  if (-not $travelCheckouts) { return $path }
  return Join-Path $travelCheckouts ($path -replace '^([A-Za-z]):', '$1')
}

# The worker's copies of homes' folders (ROOT\copies.txt): a folder in the way that is not one of them is
# renamed aside, never deleted or written into.
function Owned-Copies { $f = Join-Path $root 'copies.txt'; if (Test-Path $f) { return @(Get-Content $f | Where-Object { $_ }) } return @() }
function Own-Copy([string]$folder)
{
  $key = Folder-Key $folder
  if ((Owned-Copies) -notcontains $key) { [IO.File]::AppendAllText((Join-Path $root 'copies.txt'), "$key`r`n", (New-Object System.Text.UTF8Encoding($false))) }
}

# The worker's side, right after its claim: what its copy of each folder holds now (ID.have.N), then ID.have.
function Write-Have([string]$id, $folders)
{
  $owned = Owned-Copies
  $i = 0
  foreach ($f in @($folders))
  {
    $here = Worker-Path $f
    $mine = if ((Test-Path -LiteralPath $here) -and ($owned -contains (Folder-Key $here) -or (Test-Path -LiteralPath (Join-Path $here '.git\heavy-queue-worker')))) { [HeavyQueueFiles]::Scan($here, [int]::MaxValue) } else { New-Object 'System.Collections.Generic.Dictionary[string,string]' }
    [HeavyQueueFiles]::Write((Travel-File $id "have.$i"), $mine)
    $i++
  }
  Write-Shared (Travel-File $id 'have') "$i"
}

# The home's side, once a worker claimed its job and said what it has: per folder, what differs (ID.fN.tar
# and ID.fN.del: the files to write and to delete), and for a git checkout its git state (the commit, branch,
# remotes and remote branches, with the commits no remote has as ID.fN.bundle) so git works there as here.
# Returns '' when it is ready, else why the job runs here after all (ID.refused tells the worker).
function Pack-State([string]$id, [string]$cwd, $folders)
{
  $why = ''
  try
  {
    $waited = Get-Date
    while (-not (Test-Path (Travel-File $id 'have')))
    {
      Beat (Travel-File $id 'waiting') 'waiting'
      if (((Get-Date) - $waited).TotalSeconds -gt $travelStale + 30) { throw 'the worker did not say what it has' }
      Start-Sleep -Seconds 1
    }
    $limit = [int64]$travelLimitMB * 1MB
    $total = 0L
    $list = @()
    $i = 0
    foreach ($f in @($folders))
    {
      Beat (Travel-File $id 'waiting') 'waiting'
      $mine = [HeavyQueueFiles]::Scan($f, $travelMaxFiles)
      if ($null -eq $mine) { throw "$f holds over $travelMaxFiles files (travelMaxFiles)" }
      $theirs = [HeavyQueueFiles]::Read((Travel-File $id "have.$i"))
      $bytes = 0L
      $diff = [HeavyQueueFiles]::Diff($mine, $theirs, [ref]$bytes)
      $total += $bytes
      if ($total -gt $limit) { throw "what differs on the worker weighs over $travelLimitMB MB (travelLimitMB)" }
      $entry = [ordered]@{ path = $f; tar = ($diff[0].Count -gt 0); del = ($diff[1].Count -gt 0); files = $diff[0].Count; deleted = $diff[1].Count; git = $null }
      if ($diff[0].Count)
      {
        $names = Join-Path $env:TEMP "heavy-send-$PID.txt"
        Write-List $names $diff[0]
        $r = Run-Beating "$env:windir\System32\tar.exe" @('-cf', (Travel-File $id "f$i.tar"), '-C', $f, '--null', '-T', $names) (Travel-File $id 'waiting') 'waiting'
        Drop-File $names
        if ($r.Code -ne 0) { throw "tar of $($f): $($r.Err.Trim())" }
      }
      if ($diff[1].Count) { [IO.File]::WriteAllLines((Travel-File $id "f$i.del"), [string[]]$diff[1], (New-Object System.Text.UTF8Encoding($false))) }
      $top = Git-Top $f
      if ($top -and (Folder-Key $top) -eq (Folder-Key $f))
      {
        $head = (Git $f @('rev-parse', 'HEAD')).Out.Trim()
        $branch = (Git $f @('symbolic-ref', '--short', '-q', 'HEAD')).Out.Trim()
        $remotes = [ordered]@{}
        foreach ($r in ((Git $f @('remote')).Out -split "`n" | Where-Object { $_.Trim() })) { $remotes[$r.Trim()] = (Git $f @('remote', 'get-url', $r.Trim())).Out.Trim() }
        if ($remotes.Count -eq 0) { throw "$f has no remote to fetch from" }
        $refs = [ordered]@{}
        foreach ($l in ((Git $f @('for-each-ref', 'refs/remotes', '--format=%(objectname) %(refname)')).Out -split "`n" | Where-Object { $_ -match '^[0-9a-f]{40} ' }))
        {
          $parts = $l.Trim() -split ' ', 2
          if ($parts[1] -notmatch '/HEAD$') { $refs[$parts[1]] = $parts[0] }
        }
        $local = [int]((Git $f @('rev-list', '--count', 'HEAD', '--not', '--remotes')).Out.Trim())
        if ($local -gt 0)
        {
          $r = Git $f @('bundle', 'create', (Travel-File $id "f$i.bundle"), 'HEAD', '--not', '--remotes')
          if ($r.Code -ne 0) { throw "git bundle: $($r.Err.Trim())" }
        }
        $entry.git = [ordered]@{ head = $head; branch = $branch; remotes = $remotes; refs = $refs; bundle = ($local -gt 0) }
      }
      $list += $entry
      $i++
    }
    $files = 0; $gone = 0; foreach ($e in $list) { $files += $e.files; $gone += $e.deleted }
    [Console]::Error.WriteLine("heavy: its folders go over: $files files ($([math]::Round($total / 1MB, 1)) MB) to write, $gone to delete.")
    $state = [ordered]@{ cwd = $cwd; folders = $list }
    Write-Shared (Travel-File $id 'state.json') ($state | ConvertTo-Json -Depth 6 -Compress)
    Write-Shared (Travel-File $id 'ready') 'ready'
  }
  catch
  {
    $why = "$($_.Exception.Message)"
    Write-Shared (Travel-File $id 'refused') $why
  }
  return $why
}

# A worker's git state for a checkout copy: a .git made from a bare mirror of its first remote (ROOT\mirrors,
# so a second copy of a big repository fetches only what is new), the home's remotes, commits and remote
# branches, HEAD at the home's commit and the index at it; the files are the home's (Pack-State's tar).
function Set-Git([string]$here, $git, [string]$bundle)
{
  $origin = @($git.remotes.PSObject.Properties)[0]
  $mirror = Join-Path $root ("mirrors\" + (($origin.Value -replace '[^A-Za-z0-9]+', '-').Trim('-')) + '.git')
  if (-not (Test-Path -LiteralPath $mirror))
  {
    $r = Run-Quiet 'git' @('clone', '--mirror', '--quiet', $origin.Value, $mirror)
    if ($r.Code -ne 0) { throw "git clone --mirror $($origin.Value): $($r.Err.Trim())" }
  }
  else
  {
    $r = Git $mirror @('fetch', '--prune', '--quiet')
    if ($r.Code -ne 0) { throw "git fetch in $($mirror): $($r.Err.Trim())" }
  }
  $dotGit = Join-Path $here '.git'
  if ((Test-Path -LiteralPath $dotGit -PathType Leaf)) { Remove-Item -LiteralPath $dotGit -Force }
  if (-not (Test-Path -LiteralPath $dotGit))
  {
    $temp = "$here.heavy-git"
    if (Test-Path -LiteralPath $temp) { cmd /c rd /s /q "$temp" }
    $r = Run-Quiet 'git' @('clone', '--no-checkout', '--quiet', '--reference', $mirror, $origin.Value, $temp)
    if ($r.Code -ne 0) { throw "git clone $($origin.Value): $($r.Err.Trim())" }
    Move-Item -LiteralPath (Join-Path $temp '.git') -Destination $dotGit
    cmd /c rd /s /q "$temp"
  }
  foreach ($remote in $git.remotes.PSObject.Properties)
  {
    if ((Git $here @('remote', 'get-url', $remote.Name)).Code -ne 0) { [void](Git $here @('remote', 'add', $remote.Name, $remote.Value)) }
    else { [void](Git $here @('remote', 'set-url', $remote.Name, $remote.Value)) }
    $r = Git $here @('fetch', '--prune', '--quiet', $remote.Name)
    if ($r.Code -ne 0) { throw "git fetch $($remote.Name): $($r.Err.Trim())" }
  }
  if ($git.bundle)
  {
    $r = Git $here @('fetch', '--quiet', $bundle, 'HEAD')
    if ($r.Code -ne 0) { throw "git fetch from the bundle: $($r.Err.Trim())" }
  }
  foreach ($ref in $git.refs.PSObject.Properties)
  {
    $r = Git $here @('update-ref', $ref.Name, $ref.Value)
    if ($r.Code -ne 0) { throw "git update-ref $($ref.Name): $($r.Err.Trim())" }
  }
  if ($git.branch)
  {
    $r = Git $here @('update-ref', "refs/heads/$($git.branch)", $git.head)
    if ($r.Code -ne 0) { throw "git update-ref $($git.branch): $($r.Err.Trim())" }
    [void](Git $here @('symbolic-ref', 'HEAD', "refs/heads/$($git.branch)"))
  }
  else
  {
    $r = Git $here @('update-ref', '--no-deref', 'HEAD', $git.head)
    if ($r.Code -ne 0) { throw "git update-ref HEAD: $($r.Err.Trim())" }
  }
  # (the index at HEAD, the files untouched: what the home changed shows as changed, as there)
  $r = Git $here @('reset', '--quiet', '--mixed')
  if ($r.Code -gt 1) { throw "git reset: $($r.Err.Trim())" }
}

# The worker's side: each folder brought to the home's state at its path here; returns the job's folder here.
function Prepare-Checkout([string]$id)
{
  $state = (Read-Small (Travel-File $id 'state.json')) | ConvertFrom-Json
  $owned = Owned-Copies
  $i = 0
  $script:workerFolders = @()
  foreach ($f in @($state.folders))
  {
    $here = Worker-Path $f.path
    if ($here.Length -lt 6) { throw "refused to work at $here" }
    Beat (Travel-File $id 'alive') "making $here"
    if ((Test-Path -LiteralPath $here) -and $owned -notcontains (Folder-Key $here) -and -not (Test-Path -LiteralPath (Join-Path $here '.git\heavy-queue-worker')))
    {
      Rename-Item -LiteralPath $here -NewName ((Split-Path -Leaf $here) + ".local-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
    }
    New-Item -ItemType Directory -Force $here | Out-Null
    Own-Copy $here
    if ($f.del) { foreach ($rel in [IO.File]::ReadAllLines((Travel-File $id "f$i.del"))) { if ($rel) { Remove-Item -LiteralPath (Join-Path $here $rel) -Force -ErrorAction SilentlyContinue } } }
    if ($f.tar)
    {
      $r = Run-Beating "$env:windir\System32\tar.exe" @('-xf', (Travel-File $id "f$i.tar"), '-C', $here) (Travel-File $id 'alive') "making $here"
      if ($r.Code -ne 0) { throw "tar into $($here): $($r.Err.Trim())" }
    }
    if ($f.git) { Set-Git $here $f.git (Travel-File $id "f$i.bundle") }
    $script:workerFolders += $here
    $i++
  }
  return (Worker-Path $state.cwd)
}

# Every file of each folder (Snapshot-Files: before the job; Pack-Back compares after it).
function Snapshot-Files($folders) { return ,@(@($folders) | ForEach-Object { [HeavyQueueFiles]::Scan($_, [int]::MaxValue) }) }

# The worker's side, after the job: per folder the files it made or changed (ID.bN.tar) and deleted
# (ID.bN.del), for the home to take.
function Pack-Back([string]$id, $folders, $before)
{
  $after = Snapshot-Files $folders
  $changedAll = 0; $deletedAll = 0
  for ($i = 0; $i -lt @($folders).Count; $i++)
  {
    $bytes = 0L
    $diff = [HeavyQueueFiles]::Diff($after[$i], $before[$i], [ref]$bytes)
    if ($diff[0].Count)
    {
      $names = Join-Path $env:TEMP "heavy-back-$PID.txt"
      Write-List $names $diff[0]
      $r = Run-Beating "$env:windir\System32\tar.exe" @('-cf', (Travel-File $id "b$i.tar"), '-C', @($folders)[$i], '--null', '-T', $names) (Travel-File $id 'alive') 'sending its files back'
      Drop-File $names
      if ($r.Code -ne 0) { throw "tar of the job's files: $($r.Err.Trim())" }
    }
    if ($diff[1].Count) { [IO.File]::WriteAllLines((Travel-File $id "b$i.del"), [string[]]$diff[1], (New-Object System.Text.UTF8Encoding($false))) }
    $changedAll += $diff[0].Count; $deletedAll += $diff[1].Count
  }
  return "$changedAll files changed, $deletedAll deleted"
}

# The home's side: the job's files into its folders, as if it had run here.
function Unpack-Back([string]$id, $folders)
{
  $n = 0
  for ($i = 0; $i -lt @($folders).Count; $i++)
  {
    $f = @($folders)[$i]
    if (Test-Path (Travel-File $id "b$i.tar"))
    {
      $r = Run-Quiet "$env:windir\System32\tar.exe" @('-xf', (Travel-File $id "b$i.tar"), '-C', $f)
      if ($r.Code -ne 0) { throw "tar: $($r.Err.Trim())" }
      $n++
    }
    if (Test-Path (Travel-File $id "b$i.del"))
    {
      foreach ($rel in [IO.File]::ReadAllLines((Travel-File $id "b$i.del"))) { if ($rel) { Remove-Item -LiteralPath (Join-Path $f $rel) -Force -ErrorAction SilentlyContinue } }
      $n++
    }
  }
  return $n
}

# On a worker, the lock that runs a travelled job and everything it starts are in one job object that kills
# them all when the lock's process ends: a lock killed mid-job (its home then reports it stopped, and the
# thread runs it again) leaves nothing running. At the job's normal end the kill is switched off, so what it
# leaves running on purpose (a compile server) stays.
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
function Follow-Remote([string]$id, [string]$worker, $folders)
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
    if ($exit -match '^notrun')
    {
      $errAt = Pump (Travel-File $id 'err') $errAt $stderr
      return $null # (the worker could not make the checkout: the job runs here)
    }
    if ($exit)
    {
      Start-Sleep -Milliseconds 300
      $outAt = Pump (Travel-File $id 'out') $outAt $stdout
      $errAt = Pump (Travel-File $id 'err') $errAt $stderr
      $code = if ($exit -match '^(-?\d+)') { [int]$matches[1] } else { 1 }
      try { if (Unpack-Back $id $folders) { [Console]::Error.WriteLine("heavy: the files the job made or changed are here now.") } }
      catch { [Console]::Error.WriteLine("heavy: the job's files could not come back: $($_.Exception.Message)"); if ($code -eq 0) { $code = 1 } }
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
