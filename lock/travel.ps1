# Jobs that travel (dot-sourced by heavy.ps1 and machine\worker.ps1). A job started with --travel from a git
# checkout may run on another machine (a worker) while it waits here: the worker rebuilds the checkout's
# exact state at the same path (the commit, the commits not on any remote, the uncommitted changes and the
# new files; nothing git ignores, such as build folders) and runs the command there. Its output comes back to
# the waiting heavy.cmd as it is written, then its exit code; no file comes back. So a job travels when its
# result is its output and exit code (a gate, a test run) and it builds what it uses itself: a build whose
# files the thread uses afterwards stays home. Everything goes through files in the exchange folder that
# every machine sees (travelExchange, a NAS share):
#   ID.job.json      the offer: machine, folder, command line, label, kind, thread, estimate, environment
#                    (no secrets), the tool versions (the fingerprint commands and their output); ID is the
#                    home's queue ticket's name
#   ID.waiting       the home's waiter, every 3 s while it waits (a counter)
#   ID.claim         the machine that runs it, made with CreateNew: whoever makes it first runs the job, the
#                    home included (it claims its own job before running it locally)
#   ID.state.json    the checkout's state, written by the home once claimed: its top folder, commit, branch,
#   ID.bundle        remotes and remote branches, with the commits no remote has (a git bundle),
#   ID.patch         the uncommitted changes (git diff --binary HEAD) and
#   ID.new.tar       the new files git does not ignore; then
#   ID.ready         (or ID.refused, the reason the job runs at home after all)
#   ID.alive         the worker, every 5 s (a counter and what it is doing)
#   ID.watch         the home's waiter, every 3 s while the job runs elsewhere (a counter)
#   ID.out, ID.err   the job's output
#   ID.exit          its exit code, then why when it did not finish ("1 stopped: ...")
# ROOT\travel (this machine's own) keeps why a waiting job stays home (ID.stays), for the pages.
# A worker takes a job only with the same fingerprint, and no --exclusive one on a no-benchmarks machine. A
# worker that stops answering for travelStale seconds ends the job with "heavy: STOPPED"; a home waiter that
# goes away for as long makes the worker stop the job.

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

# Why this job may not travel, or '' when it may.
function Travel-Refusal([string]$cwd, [string]$commandLine, [bool]$forbid, [bool]$allow)
{
  if ($forbid) { return '--local' }
  if (-not $allow) { return 'it travels only with --travel here (travelByDefault, travelExclusive in the config)' }
  if (-not $travelExchange) { return 'no travelExchange in the config' }
  $top = Git-Top $cwd
  if (-not $top) { return 'its folder is in no git checkout' }
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
      if (-not (Under-Any $p @($top)) -and -not (Under-Any $p $samePaths)) { return "it names $p, outside its checkout ($top)" }
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
    $output = $p.StandardOutput.ReadToEnd().Trim()
    $p.WaitForExit()
    "$c => $output"
  }
  return (@($parts) -join "`n")
}

# Tools a worker takes from its home (travelTools, such as a compiler installed from an unreleased build): a
# folder's identity is a hash of its files' names, sizes and times. The home puts a copy of each folder into
# EXCHANGE\tools\NAME-ID once; a worker mirrors it over its own folder at the same path (stopping what runs
# from there first) when the offer's ID differs from its own (PATH\.heavy-queue-tool), then compares tools.
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
    $id = Tool-Id $folder
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

# The worker's side, before it compares tools for an offer: its folders brought to the offer's IDs. Returns
# '' or why not (the note on the board).
function Take-Tools($tools)
{
  foreach ($t in @($tools))
  {
    $mark = Join-Path $t.path $toolMark
    if ((Read-Small $mark) -eq $t.id) { continue }
    $copy = Tool-Copy $t.path $t.id
    if (-not (Test-Path -LiteralPath (Join-Path $copy '.done'))) { return "the home's copy of $($t.path) is not in the exchange" }
    # (what runs from that folder holds its files: a compile server from an earlier job)
    $key = (Folder-Key $t.path)
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and (Folder-Key (Split-Path $_.ExecutablePath)).StartsWith($key) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    # (robocopy's whole output in ROOT\tool-copy.log; its first error line on the board)
    $log = @(& robocopy $copy $t.path /MIR /R:3 /W:2 /NDL /NJH /NP /XF '.done' $toolMark 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    Set-Content -LiteralPath (Join-Path $root 'tool-copy.log') -Value (@("$(Get-Date -Format s) robocopy $copy $($t.path): exit $code") + $log) -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($code -ge 8)
    {
      $error1 = @($log | Where-Object { $_ -match 'ERROR \d+' } | Select-Object -First 1)
      $holders = @($log | Where-Object { $_ -match 'ERROR 32 ' }).Count
      $why = if ($holders) { 'a process outside this worker holds its files' } elseif ($log -match 'ERROR 5 ') { "the worker's user cannot write it: setup-worker.ps1 -Tools `"$($t.path)`", as administrator, gives it that folder" } else { 'see tool-copy.log' }
      return "could not copy $($t.path) from the exchange (robocopy $code, $why$(if ($error1) { ': ' + $error1[0].Trim() }))"
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

$travelExts = 'job.json', 'stays', 'waiting', 'claim', 'state.json', 'bundle', 'patch', 'new.tar', 'ready', 'refused', 'alive', 'watch', 'out', 'err', 'back.tar', 'back.deleted', 'exit'
function Remove-Travel([string]$id)
{
  foreach ($ext in $travelExts) { Remove-Item (Travel-File $id $ext) -Force -ErrorAction SilentlyContinue }
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

# The home's side, once a worker claimed its job: the checkout's state into the exchange. Returns '' when it
# is ready, else why the job runs here after all (ID.refused tells the worker).
function Pack-State([string]$id, [string]$cwd)
{
  $why = ''
  try
  {
    $top = Git-Top $cwd
    if (-not $top) { throw 'its folder is in no git checkout now' }
    $head = (Git $top @('rev-parse', 'HEAD')).Out.Trim()
    $branch = (Git $top @('symbolic-ref', '--short', '-q', 'HEAD')).Out.Trim()
    $remotes = [ordered]@{}
    foreach ($r in ((Git $top @('remote')).Out -split "`n" | Where-Object { $_.Trim() }))
    {
      $remotes[$r.Trim()] = (Git $top @('remote', 'get-url', $r.Trim())).Out.Trim()
    }
    if ($remotes.Count -eq 0) { throw 'its checkout has no remote to fetch from' }
    $refs = [ordered]@{}
    foreach ($l in ((Git $top @('for-each-ref', 'refs/remotes', '--format=%(objectname) %(refname)')).Out -split "`n" | Where-Object { $_ -match '^[0-9a-f]{40} ' }))
    {
      $parts = $l.Trim() -split ' ', 2
      if ($parts[1] -notmatch '/HEAD$') { $refs[$parts[1]] = $parts[0] }
    }
    $limit = [int64]$travelLimitMB * 1MB
    # The commits no remote has.
    $local = [int]((Git $top @('rev-list', '--count', 'HEAD', '--not', '--remotes')).Out.Trim())
    if ($local -gt 0)
    {
      $r = Git $top @('bundle', 'create', (Travel-File $id 'bundle'), 'HEAD', '--not', '--remotes')
      if ($r.Code -ne 0) { throw "git bundle: $($r.Err.Trim())" }
    }
    # The uncommitted changes, against HEAD (staged or not), written by git itself (bytes as they are).
    $r = Git $top @('diff', '--binary', "--output=$(Travel-File $id 'patch')", 'HEAD')
    if ($r.Code -ne 0) { throw "git diff: $($r.Err.Trim())" }
    # The new files git does not ignore: their names as git writes them (NUL-separated bytes), to tar.
    $list = Join-Path $env:TEMP "heavy-new-$PID.txt"
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = 'git'
    $info.Arguments = "-C `"$top`" ls-files --others --exclude-standard -z"
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($info)
    $bytes = New-Object IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($bytes)
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "git ls-files: exit $($p.ExitCode)" }
    [IO.File]::WriteAllBytes($list, $bytes.ToArray())
    $new = (Get-Item -LiteralPath $list).Length -gt 0
    if ($new)
    {
      $r = Run-Quiet "$env:windir\System32\tar.exe" @('-cf', (Travel-File $id 'new.tar'), '-C', $top, '--null', '-T', $list)
      if ($r.Code -ne 0) { throw "tar: $($r.Err.Trim())" }
    }
    Remove-Item $list -Force -ErrorAction SilentlyContinue
    $size = (Get-Item -LiteralPath (Travel-File $id 'patch')).Length
    if ($new) { $size += (Get-Item -LiteralPath (Travel-File $id 'new.tar')).Length }
    if ($size -gt $limit) { throw "its uncommitted state weighs $([int]($size / 1MB)) MB, over travelLimitMB ($travelLimitMB)" }
    $state = [ordered]@{ top = $top; cwd = $cwd; head = $head; branch = $branch; remotes = $remotes; refs = $refs; bundle = ($local -gt 0); new = $new }
    Write-Shared (Travel-File $id 'state.json') ($state | ConvertTo-Json -Depth 4 -Compress)
    Write-Shared (Travel-File $id 'ready') 'ready'
  }
  catch
  {
    $why = "$($_.Exception.Message)"
    Write-Shared (Travel-File $id 'refused') $why
  }
  return $why
}

# A worker's folder for one of the home's: the same path, or under travelCheckouts (testing on one computer).
function Worker-Path([string]$path)
{
  if (-not $travelCheckouts) { return $path }
  return Join-Path $travelCheckouts ($path -replace '^([A-Za-z]):', '$1')
}

# The worker's side: the checkout at the home's state, at its path here; returns the job's folder here. A
# folder in the way that is not a checkout this worker made (.git\heavy-queue-worker) is renamed aside, never
# deleted. The remotes' commits come from a bare mirror of each remote kept in ROOT\mirrors, so a second
# checkout of a big repository fetches only what is new.
function Prepare-Checkout([string]$id)
{
  $state = (Read-Small (Travel-File $id 'state.json')) | ConvertFrom-Json
  $top = Worker-Path $state.top
  if ($top.Length -lt 6) { throw "refused to work at $top" }
  $mark = Join-Path $top '.git\heavy-queue-worker'
  if ((Test-Path -LiteralPath $top) -and -not (Test-Path -LiteralPath $mark))
  {
    $aside = "$top.local-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Rename-Item -LiteralPath $top -NewName (Split-Path -Leaf $aside)
  }
  $origin = @($state.remotes.PSObject.Properties)[0]
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
  if (-not (Test-Path -LiteralPath $mark))
  {
    New-Item -ItemType Directory -Force (Split-Path $top) | Out-Null
    $r = Run-Quiet 'git' @('clone', '--no-checkout', '--quiet', '--reference', $mirror, $origin.Value, $top)
    if ($r.Code -ne 0) { throw "git clone $($origin.Value): $($r.Err.Trim())" }
    Set-Content -LiteralPath $mark -Value 'a checkout heavy-queue''s worker made: it is set to a home''s state for each job' -Encoding ascii
  }
  foreach ($remote in $state.remotes.PSObject.Properties)
  {
    if ((Git $top @('remote', 'get-url', $remote.Name)).Code -ne 0) { [void](Git $top @('remote', 'add', $remote.Name, $remote.Value)) }
    else { [void](Git $top @('remote', 'set-url', $remote.Name, $remote.Value)) }
    $r = Git $top @('fetch', '--prune', '--quiet', $remote.Name)
    if ($r.Code -ne 0) { throw "git fetch $($remote.Name): $($r.Err.Trim())" }
  }
  if ($state.bundle)
  {
    $r = Git $top @('fetch', '--quiet', (Travel-File $id 'bundle'), 'HEAD')
    if ($r.Code -ne 0) { throw "git fetch from the bundle: $($r.Err.Trim())" }
  }
  # The remote branches as the home has them (a gate compares with origin/master as the home last fetched it).
  foreach ($ref in $state.refs.PSObject.Properties)
  {
    $r = Git $top @('update-ref', $ref.Name, $ref.Value)
    if ($r.Code -ne 0) { throw "git update-ref $($ref.Name): $($r.Err.Trim())" }
  }
  $r = if ($state.branch) { Git $top @('checkout', '--quiet', '--force', '-B', $state.branch, $state.head) } else { Git $top @('checkout', '--quiet', '--force', '--detach', $state.head) }
  if ($r.Code -ne 0) { throw "git checkout $($state.head): $($r.Err.Trim())" }
  # Nothing of the job before: no untracked or ignored file (a stale build would be tested otherwise).
  $r = Git $top @('clean', '-ffdxq')
  if ($r.Code -ne 0) { throw "git clean: $($r.Err.Trim())" }
  $patch = Travel-File $id 'patch'
  if ((Get-Item -LiteralPath $patch).Length -gt 0)
  {
    $r = Git $top @('apply', '--binary', '--whitespace=nowarn', $patch)
    if ($r.Code -ne 0) { throw "git apply: $($r.Err.Trim())" }
  }
  if ($state.new)
  {
    $r = Run-Quiet "$env:windir\System32\tar.exe" @('-xf', (Travel-File $id 'new.tar'), '-C', $top)
    if ($r.Code -ne 0) { throw "tar: $($r.Err.Trim())" }
  }
  $script:workerTop = $top
  return (Worker-Path $state.cwd)
}

# Every file of a checkout but .git's, with its size and time: what a job changed is told by comparing two.
function Snapshot-Files([string]$top)
{
  $files = @{}
  $base = $top.TrimEnd('\').Length + 1
  $git = (Join-Path $top '.git').ToLowerInvariant() + '\'
  foreach ($f in [IO.Directory]::EnumerateFiles($top, '*', [IO.SearchOption]::AllDirectories))
  {
    if ($f.ToLowerInvariant().StartsWith($git)) { continue }
    $i = New-Object IO.FileInfo($f)
    $files[$f.Substring($base)] = "$($i.Length)|$($i.LastWriteTimeUtc.Ticks)"
  }
  return $files
}

# The worker's side, after the job: the files it made or changed in the checkout (build output included)
# into ID.back.tar, the ones it deleted into ID.back.deleted, for the home to take.
function Pack-Back([string]$id, [string]$top, $before)
{
  $after = Snapshot-Files $top
  $changed = @($after.Keys | Where-Object { $before[$_] -ne $after[$_] })
  $deleted = @($before.Keys | Where-Object { -not $after.ContainsKey($_) })
  if ($changed.Count)
  {
    $list = Join-Path $env:TEMP "heavy-back-$PID.txt"
    [IO.File]::WriteAllText($list, (($changed | ForEach-Object { $_.Replace('\', '/') }) -join "`0"), (New-Object System.Text.UTF8Encoding($false)))
    $r = Run-Quiet "$env:windir\System32\tar.exe" @('-cf', (Travel-File $id 'back.tar'), '-C', $top, '--null', '-T', $list)
    Remove-Item $list -Force -ErrorAction SilentlyContinue
    if ($r.Code -ne 0) { throw "tar of the job's files: $($r.Err.Trim())" }
  }
  if ($deleted.Count) { [IO.File]::WriteAllLines((Travel-File $id 'back.deleted'), [string[]]$deleted, (New-Object System.Text.UTF8Encoding($false))) }
  return "$($changed.Count) files changed, $($deleted.Count) deleted"
}

# The home's side: the job's files into its checkout, as if it had run here.
function Unpack-Back([string]$id, [string]$top)
{
  $n = 0
  if (Test-Path (Travel-File $id 'back.tar'))
  {
    $r = Run-Quiet "$env:windir\System32\tar.exe" @('-xf', (Travel-File $id 'back.tar'), '-C', $top)
    if ($r.Code -ne 0) { throw "tar: $($r.Err.Trim())" }
    $n = 1
  }
  if (Test-Path (Travel-File $id 'back.deleted'))
  {
    foreach ($rel in [IO.File]::ReadAllLines((Travel-File $id 'back.deleted'))) { if ($rel) { Remove-Item -LiteralPath (Join-Path $top $rel) -Force -ErrorAction SilentlyContinue } }
    $n = 1
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
function Follow-Remote([string]$id, [string]$worker, [string]$top)
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
      try { if (Unpack-Back $id $top) { [Console]::Error.WriteLine("heavy: the files the job made or changed are here now.") } }
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
