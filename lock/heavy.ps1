# heavy-queue's lock: runs one command line while holding the machine's one heavy slot, so heavy jobs
# (builds, test runs, benchmarks) run one at a time. --exclusive (benchmarks and every timing run) takes the
# same slot and then also waits until the machine is otherwise idle.
#
#   heavy.cmd [--exclusive] [--name TEXT] [--estimate 90s|10m|2h] COMMAND LINE...
#   heavy.cmd --status
#
# The slot is a named mutex: Windows frees it when its holder dies, so a killed job never leaves the
# machine locked. Waiters queue in arrival order (ROOT\queue, one file per waiting process; a dead waiter's
# file is dropped). The holder is in ROOT\holder.txt. The command runs with HEAVY_QUEUE_HELD set (and the
# config's heldVariable): a heavy script it calls runs at once instead of waiting for its own parent. It
# also waits while the hold file's line 1 is not "HOLD: no" or a quiet flag whose holder is alive exists,
# and an --exclusive job holds that flag while it runs. The exit code is the command's.
#
# config.json in the repository's root (not in the repository; HEAVY_QUEUE_CONFIG names another file)
# says where things are; each setting has a default:
#   root          the data folder (queue, holder.txt, history.tsv, status.*, publish.txt)  %ProgramData%\heavy-queue
#   holdFile      line 1 "HOLD: no" lets jobs start, anything else holds them             ROOT\hold.txt
#   quietFlag     the flag an --exclusive job holds, and every job waits for              ROOT\quiet.flag
#   mutex         the slot's name                                                         Global\heavy-queue
#   heldVariable  one more variable set for the command, for scripts that check their own (none)
#   title         the status page's heading                                               COMPUTERNAME heavy slot
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')
$queueDir = Join-Path $root 'queue'
$holderFile = Join-Path $root 'holder.txt'
$line = $env:HEAVY_QUEUE_COMMAND
if ($null -eq $line) { $line = '' }
$line = $line.Trim()
$exclusive = $false
$name = ''
$status = $false
$given = ''
while ($true)
{
  if ($line -match '^--exclusive(\s+|$)(.*)$') { $exclusive = $true; $line = $matches[2]; continue }
  if ($line -match '^--estimate\s+(\S+)\s*(.*)$') { $given = $matches[1]; $line = $matches[2]; continue }
  if ($line -match '^--status(\s+|$)(.*)$') { $status = $true; $line = $matches[2]; continue }
  if ($line -match '^--name\s+"([^"]*)"\s*(.*)$') { $name = $matches[1]; $line = $matches[2]; continue }
  if ($line -match '^--name\s+(\S+)\s*(.*)$') { $name = $matches[1]; $line = $matches[2]; continue }
  break
}

# Writes a file other jobs read all the time (holder.txt, the queue's, the flag): a reader holding it
# open for a moment made Set-Content fail and the job end ("being used by another process", 2026-11-23),
# so it tries again for up to 5 seconds.
function Write-Shared([string]$path, [string]$text)
{
  for ($i = 0; ; $i++)
  {
    try { [IO.File]::WriteAllText($path, $text + "`r`n", (New-Object System.Text.UTF8Encoding($true))); return }
    catch { if ($i -ge 50) { throw }; Start-Sleep -Milliseconds 100 }
  }
}

function Alive([int]$id) { return $null -ne (Get-Process -Id $id -ErrorAction SilentlyContinue) }

function Show-Status
{
  $text = if (Test-Path $holderFile) { (Get-Content -Raw $holderFile -ErrorAction SilentlyContinue).Trim() } else { '' }
  if ($text -match '^pid (\d+)' -and (Alive ([int]$matches[1]))) { 'holder: ' + $text } else { 'holder: none' }
  $waiting = @(Get-ChildItem $queueDir -File -ErrorAction SilentlyContinue | Sort-Object Name)
  'waiting: ' + $waiting.Count
  foreach ($w in $waiting) { '  ' + (Get-Content -Raw $w.FullName -ErrorAction SilentlyContinue).Trim() }
}

# status.html: the holder, the queue and the last 200 finished jobs (history.tsv), written again on
# every enqueue, start and finish; the open page reloads itself every 5 s and counts the running times.
$historyFile = Join-Path $root 'history.tsv'
$pageFile = Join-Path $root 'status.html'

function Html([string]$text) { return [System.Net.WebUtility]::HtmlEncode($text) }
function Iso([DateTime]$time) { return $time.ToString('yyyy-MM-ddTHH:mm:sszzz') }
function MdText([string]$text) { return ($text -replace '`', "'" -replace '\|', '/') }

function Owner([string]$thread, [string]$cwd) { if ($thread) { return $thread } return (Who $cwd) }

# The title of the Claude session (the thread) that started this job, from the desktop app's record of
# it (CLAUDE_CODE_HOST_SESSION_ID); empty outside one. ':' is written '-' (the records use ': ').
function Thread-Title
{
  $id = $env:CLAUDE_CODE_HOST_SESSION_ID
  if (-not $id) { return '' }
  try
  {
    $file = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Claude-Data\*\claude-code-sessions') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem $_.FullName -Recurse -Depth 2 -Filter "$id.json" -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $file) { return '' }
    $text = [IO.File]::ReadAllText($file.FullName)
    if ($text -match '"title"\s*:\s*"((?:[^"\\]|\\.)*)"') { return (('"' + $matches[1] + '"' | ConvertFrom-Json -ErrorAction SilentlyContinue) -replace '[:\t\r\n]', '-') }
  }
  catch { }
  return ''
}

function Who([string]$cwd)
{
  if ($cwd -match 'worktrees\\([^\\]+)') { return $matches[1] }
  $parts = @($cwd.TrimEnd('\') -split '\\')
  if ($parts.Count -ge 2) { return $parts[-2] + '\' + $parts[-1] }
  return $cwd
}

# "pid N, KIND, since MM-dd HH:mm:ss, cwd DIR[, thread TITLE][, estimate Ns]: LABEL" (holder.txt and the
# queue's files; the estimate is there only when the job gave one with --estimate)
function Parse-Record([string]$text)
{
  if ($text -notmatch '^pid (\d+), (\w+), since (\d\d-\d\d \d\d:\d\d:\d\d), cwd (.*?)(?:, thread (.*?))?(?:, estimate (\d+)s)?: (.*)$') { return $null }
  $since = [DateTime]::ParseExact("$((Get-Date).Year)-$($matches[3])", 'yyyy-MM-dd HH:mm:ss', $null)
  if ($since -gt (Get-Date).AddDays(1)) { $since = $since.AddYears(-1) }
  $est = if ($matches[6]) { [int]$matches[6] } else { $null }
  return [pscustomobject]@{ Pid = [int]$matches[1]; Kind = $matches[2]; Since = $since; Cwd = $matches[4]; Thread = $matches[5]; Given = $est; Label = $matches[7].Trim() }
}

# Time estimates. A job's estimate is, in this order: what it gave with --estimate; else the median of
# the last 5 successful runs with the same name (the label in lower case, without a Claude Code worktree's path,
# digits counted as one, its first three words); else of the last 5 successful jobs of the same thread;
# else of the last 5 of the same kind. Tried on a first machine's 221 finished jobs: within 2x for 86%
# of the jobs matched by name, 46% of those matched only by thread. history.tsv's ninth column is the estimate a job
# had when it started (with its basis), to see how good they are.
function Estimate-Key([string]$label)
{
  $l = $label.ToLowerInvariant().Trim('"', ' ')
  $l = $l -replace '[a-z]:\\[^ ]*?\\\.claude\\worktrees\\[^\\ ]+\\', ''
  $l = $l -replace '\d+', '#'
  return (@($l -split '\s+' | Where-Object { $_ }) | Select-Object -First 3) -join ' '
}

function Parse-Seconds([string]$text)
{
  if ($text -match '^(\d+(?:\.\d+)?)(s|m|h)?$')
  {
    $n = [double]$matches[1]
    switch ($matches[2]) { 'm' { $n *= 60 } 'h' { $n *= 3600 } }
    return [int]$n
  }
  return $null
}

$script:estimator = $null
function Load-Estimator
{
  $byName = @{}; $byThread = @{}; $byKind = @{}
  foreach ($l in @(Get-Content $historyFile -ErrorAction SilentlyContinue))
  {
    $f = $l.TrimStart([char]0xFEFF) -split "`t"
    if ($f.Count -lt 7 -or $f[3] -ne '0') { continue }
    try { $run = ([DateTime]$f[2] - [DateTime]$f[1]).TotalSeconds } catch { continue }
    $who = if ($f.Count -ge 8 -and $f[7]) { $f[7] } else { Who $f[5] }
    foreach ($pair in @(@($byName, (Estimate-Key $f[6])), @($byThread, $who), @($byKind, $f[4])))
    {
      $map = $pair[0]; $key = $pair[1]
      if (-not $map.ContainsKey($key)) { $map[$key] = New-Object System.Collections.ArrayList }
      [void]$map[$key].Add($run)
    }
  }
  $script:estimator = @{ name = $byName; thread = $byThread; kind = $byKind }
}

function Median-Of-Last($list)
{
  $last = @($list | Select-Object -Last 5 | Sort-Object)
  if ($last.Count -eq 0) { return $null }
  if ($last.Count % 2) { return [int]$last[[int][Math]::Floor($last.Count / 2)] }
  return [int](($last[$last.Count / 2 - 1] + $last[$last.Count / 2]) / 2)
}

# @{ seconds; basis (given, name, thread, kind); count } or $null when nothing is known.
function Estimate($r)
{
  if ($null -ne $r.Given) { return @{ seconds = $r.Given; basis = 'given'; count = 0 } }
  if (-not $script:estimator) { Load-Estimator }
  foreach ($try in @(@('name', (Estimate-Key $r.Label)), @('thread', (Owner $r.Thread $r.Cwd)), @('kind', $r.Kind)))
  {
    $map = $script:estimator[$try[0]]
    if ($map.ContainsKey($try[1])) { return @{ seconds = (Median-Of-Last $map[$try[1]]); basis = $try[0]; count = $map[$try[1]].Count } }
  }
  return $null
}

function Short-Time([DateTime]$t) { if ($t.Date -eq (Get-Date).Date) { return $t.ToString('HH:mm') } return $t.ToString('MM-dd HH:mm') }

function Duration([TimeSpan]$t)
{
  if ($t.TotalHours -ge 1) { return '{0}h {1:D2}m' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
  if ($t.TotalMinutes -ge 1) { return '{0}m {1:D2}s' -f $t.Minutes, $t.Seconds }
  return '{0}s' -f [int]$t.TotalSeconds
}

function Write-Page
{
  try
  {
    $md = New-Object System.Text.StringBuilder
    $jRunning = $null; $jQueue = New-Object System.Collections.ArrayList; $jFinished = New-Object System.Collections.ArrayList
    $now = Get-Date
    $script:estimator = $null
    # When the next job could start: now, or when the running job's estimate runs out (unknown once a job
    # in the line has no estimate). The machine's holds and an exclusive job's idle wait are not counted.
    $next = $now
    $rows = New-Object System.Text.StringBuilder
    $holder = $null
    if (Test-Path $holderFile) { $holder = Parse-Record ((Get-Content -Raw $holderFile -ErrorAction SilentlyContinue) + '').Trim() }
    if ($holder -and (Alive $holder.Pid))
    {
      $iso = $holder.Since.ToString('s')
      $e = Estimate $holder
      $jRunning = [ordered]@{ kind = $holder.Kind; thread = (Owner $holder.Thread $holder.Cwd); folder = (Who $holder.Cwd); label = $holder.Label; since = (Iso $holder.Since) }
      $estText = ''; $doneText = ''
      if ($e)
      {
        $done = $holder.Since.AddSeconds($e.seconds)
        if ($done -lt $now) { $done = $now } # (over its estimate: done any moment, as far as the line is concerned)
        $next = $done
        $jRunning.estimate = $e.seconds; $jRunning.basis = $e.basis; $jRunning.done = (Iso $done)
        $estText = (Duration ([TimeSpan]::FromSeconds($e.seconds))) + " ($($e.basis))"; $doneText = '~' + (Short-Time $done)
      }
      else { $next = $null }
      [void]$rows.Append("<tr><td class='kind $($holder.Kind)'>$($holder.Kind)</td><td>$(Html (Owner $holder.Thread $holder.Cwd))</td><td class='cmd'>$(Html $holder.Label)</td><td>$($holder.Since.ToString('HH:mm:ss'))</td><td class='run' data-since='$iso'></td><td>$estText</td><td>$doneText</td><td>$($holder.Pid)</td></tr>")
      [void]$md.Append("| $($holder.Kind) | $(Owner $holder.Thread $holder.Cwd) | ``$(MdText $holder.Label)`` | $($holder.Since.ToString('HH:mm')) | $(Duration ($now - $holder.Since)) | $estText | $doneText |`n")
    }
    else { [void]$rows.Append("<tr><td colspan='8' class='none'>free</td></tr>"); [void]$md.Append("| free | | | | | | |`n") }
    $mdQueue = New-Object System.Text.StringBuilder
    $queue = New-Object System.Text.StringBuilder
    $n = 0
    foreach ($w in @(Get-ChildItem $queueDir -File -ErrorAction SilentlyContinue | Sort-Object Name))
    {
      $r = Parse-Record ((Get-Content -Raw $w.FullName -ErrorAction SilentlyContinue) + '').Trim()
      if (-not $r -or -not (Alive $r.Pid)) { continue }
      $n++
      $job = [ordered]@{ kind = $r.Kind; thread = (Owner $r.Thread $r.Cwd); folder = (Who $r.Cwd); label = $r.Label; since = (Iso $r.Since) }
      $e = Estimate $r
      $estText = ''; $startText = ''
      if ($e) { $job.estimate = $e.seconds; $job.basis = $e.basis; $estText = (Duration ([TimeSpan]::FromSeconds($e.seconds))) + " ($($e.basis))" }
      if ($null -ne $next)
      {
        $job.starts = (Iso $next); $startText = '~' + (Short-Time $next)
        if ($e) { $next = $next.AddSeconds($e.seconds); $job.done = (Iso $next); $startText += ' - ~' + (Short-Time $next) } else { $next = $null }
      }
      [void]$jQueue.Add($job)
      [void]$queue.Append("<tr><td>$n</td><td class='kind $($r.Kind)'>$($r.Kind)</td><td>$(Html (Owner $r.Thread $r.Cwd))</td><td class='cmd'>$(Html $r.Label)</td><td>$($r.Since.ToString('HH:mm:ss'))</td><td class='run' data-since='$($r.Since.ToString('s'))'></td><td>$estText</td><td>$startText</td></tr>")
      [void]$mdQueue.Append("| $n | $($r.Kind) | $(Owner $r.Thread $r.Cwd) | ``$(MdText $r.Label)`` | $($r.Since.ToString('HH:mm')) | $(Duration ($now - $r.Since)) | $estText | $startText |`n")
    }
    if ($n -eq 0) { [void]$queue.Append("<tr><td colspan='8' class='none'>nobody waiting</td></tr>") }
    $mdHistory = New-Object System.Text.StringBuilder
    $history = New-Object System.Text.StringBuilder
    $lines = @(Get-Content $historyFile -Tail 200 -ErrorAction SilentlyContinue)
    [array]::Reverse($lines)
    foreach ($l in $lines)
    {
      # queued, started, finished (ISO), exit code, kind, cwd, label
      $f = $l -split "`t"
      if ($f.Count -lt 7) { continue }
      $owner = if ($f.Count -ge 8) { Owner $f[7] $f[5] } else { Who $f[5] }; $queued = [DateTime]$f[0]; $started = [DateTime]$f[1]; $ended = [DateTime]$f[2]
      $ok = if ($f[3] -eq '0') { 'ok' } else { 'bad' }
      if ($jFinished.Count -lt 100) { [void]$jFinished.Add([ordered]@{ kind = $f[4]; thread = $owner; folder = (Who $f[5]); label = $f[6]; queued = (Iso $queued); started = (Iso $started); ended = (Iso $ended); exit = [int]$f[3] }) }
      [void]$history.Append("<tr><td class='kind $($f[4])'>$($f[4])</td><td>$(Html $owner)</td><td class='cmd'>$(Html $f[6])</td><td>$($started.ToString('MM-dd HH:mm'))</td><td>$(Duration ($started - $queued))</td><td>$(Duration ($ended - $started))</td><td class='$ok'>$($f[3])</td></tr>")
      if ($mdHistory.Length -lt 20000) { [void]$mdHistory.Append("| $($f[4]) | $owner | ``$(MdText $f[6])`` | $($started.ToString('MM-dd HH:mm')) | $(Duration ($started - $queued)) | $(Duration ($ended - $started)) | $(if ($f[3] -eq '0') { '0' } else { '**' + $f[3] + '**' }) |`n") }
    }
    if ($lines.Count -eq 0) { [void]$history.Append("<tr><td colspan='7' class='none'>none yet</td></tr>") }
    $page = @"
<!doctype html>
<html><head><meta charset="utf-8"><meta http-equiv="refresh" content="5"><title>heavy slot</title>
<style>
:root { --bg: #fff; --fg: #1a1a1a; --muted: #666; --line: #ddd; --head: #f3f3f3; --ok: #1a7f37; --bad: #c62828; --ex: #8250df; --hv: #0969da; }
@media (prefers-color-scheme: dark) { :root { --bg: #161616; --fg: #e6e6e6; --muted: #999; --line: #333; --head: #222; --ok: #4ac26b; --bad: #ff6b6b; --ex: #b392f0; --hv: #58a6ff; } }
body { background: var(--bg); color: var(--fg); font: 14px/1.4 system-ui, sans-serif; margin: 16px; }
h1 { font-size: 18px; margin: 0 0 4px; } h2 { font-size: 15px; margin: 20px 0 6px; }
.muted, .none { color: var(--muted); } table { border-collapse: collapse; width: 100%; }
th, td { border-bottom: 1px solid var(--line); padding: 4px 8px; text-align: left; vertical-align: top; }
th { background: var(--head); font-weight: 600; } td.cmd { font-family: Consolas, monospace; font-size: 12px; word-break: break-all; }
.kind.exclusive { color: var(--ex); font-weight: 600; } .kind.heavy { color: var(--hv); } .ok { color: var(--ok); } .bad { color: var(--bad); font-weight: 600; }
</style></head><body>
<h1>$(Html $title)</h1>
<div class="muted">One heavy job at a time (tools\heavy\heavy.cmd). Written $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); reloads every 5 s.</div>
<h2>Running</h2>
<table><tr><th>kind</th><th>thread</th><th>command</th><th>started</th><th>running</th><th>estimate</th><th>done</th><th>pid</th></tr>$($rows.ToString())</table>
<h2>Waiting</h2>
<table><tr><th>#</th><th>kind</th><th>thread</th><th>command</th><th>queued</th><th>waiting</th><th>estimate</th><th>runs</th></tr>$($queue.ToString())</table>
<h2>Finished (last 200)</h2>
<table><tr><th>kind</th><th>thread</th><th>command</th><th>started</th><th>waited</th><th>took</th><th>exit</th></tr>$($history.ToString())</table>
<script>
function d(s) { s = Math.max(0, Math.floor(s)); var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
  return h ? h + 'h ' + String(m).padStart(2, '0') + 'm' : m ? m + 'm ' + String(x).padStart(2, '0') + 's' : x + 's'; }
function tick() { document.querySelectorAll('[data-since]').forEach(function (e) { e.textContent = d((Date.now() - new Date(e.dataset.since)) / 1000); }); }
tick(); setInterval(tick, 1000);
</script>
</body></html>
"@
    $temp = "$pageFile.$PID.tmp"
    [IO.File]::WriteAllText($temp, $page, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force $temp $pageFile
    # The same as markdown (status.md), for reading in a terminal or an editor.
    $noneQueue = if ($mdQueue.Length) { '' } else { "| | nobody waiting | | | | | | |`n" }
    $text = "# $title`n`nWritten $($now.ToString('yyyy-MM-dd HH:mm:ss')) (this machine's times; durations as of then).`n`n" +
      "## Running`n`n| kind | thread | command | started | running | estimate | done |`n|---|---|---|---|---|---|---|`n" + $md.ToString() +
      "`n## Waiting`n`n| # | kind | thread | command | queued | waiting | estimate | runs |`n|---|---|---|---|---|---|---|---|`n" + $mdQueue.ToString() + $noneQueue +
      "`n## Finished`n`n| kind | thread | command | started | waited | took | exit |`n|---|---|---|---|---|---|---|`n" + $mdHistory.ToString()
    $mdFile = Join-Path $root 'status.md'
    # And as JSON (status.json), for whatever shows the status elsewhere: with ROOT\publish.txt (the board's
    # address and password), machine\publish.ps1 is started after every change and posts it to the board.
    $json = ([ordered]@{ written = (Iso $now); running = $jRunning; queue = @($jQueue); finished = @($jFinished) } | ConvertTo-Json -Depth 4 -Compress)
    $jsonFile = Join-Path $root 'status.json'
    [IO.File]::WriteAllText("$jsonFile.$PID.tmp", $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force "$jsonFile.$PID.tmp" $jsonFile
    [IO.File]::WriteAllText("$mdFile.$PID.tmp", $text, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force "$mdFile.$PID.tmp" $mdFile
    if (Test-Path (Join-Path $root 'publish.txt'))
    {
      Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$repo\machine\publish.ps1`"")
    }
  }
  catch { try { Set-Content -Path (Join-Path $root 'page-error.txt') -Value "$(Get-Date -Format s) $_ $($_.InvocationInfo.PositionMessage)" } catch { } } # (the page is a view: a failed write never stops a job)
}

if ($status) { Show-Status; Write-Page; exit 0 }
if (-not $line) { 'usage: heavy.cmd [--exclusive] [--name TEXT] [--estimate 90s|10m|2h] COMMAND LINE...  |  heavy.cmd --status'; exit 2 }

function Run-Command
{
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $env:ComSpec
  $info.Arguments = '/d /s /c "' + $line + '"'
  $info.UseShellExecute = $false
  $info.WorkingDirectory = (Get-Location).Path
  $info.EnvironmentVariables['HEAVY_QUEUE_HELD'] = "$PID"
  if ($heldVariable) { $info.EnvironmentVariables[$heldVariable] = "$PID" }
  $process = [System.Diagnostics.Process]::Start($info)
  $process.WaitForExit()
  return $process.ExitCode
}

# Inside a heavy job already (its own child): no second wait. CI (GITHUB_ACTIONS) and a machine whose data
# folder's parent does not exist have no lock.
if ($env:HEAVY_QUEUE_HELD -or ($heldVariable -and [Environment]::GetEnvironmentVariable($heldVariable)) -or $env:GITHUB_ACTIONS -or -not (Test-Path (Split-Path $root))) { exit (Run-Command) }

New-Item -ItemType Directory -Force $queueDir | Out-Null
# A machine too slow or too different for timing has ROOT\no-benchmarks: an --exclusive job is refused there
# at once.
if ($exclusive -and (Test-Path (Join-Path $root 'no-benchmarks')))
{
  [Console]::Error.WriteLine("heavy: $($env:COMPUTERNAME) does not run benchmarks or timing runs ($root\no-benchmarks): run --exclusive jobs on a benchmark machine.")
  exit 2
}
$label = if ($name) { $name } else { $line }
if ($label.Length -gt 160) { $label = $label.Substring(0, 160) + '...' }
$kind = if ($exclusive) { 'exclusive' } else { 'heavy' }
$thread = Thread-Title
$givenSeconds = $null
if ($given)
{
  $givenSeconds = Parse-Seconds $given
  if ($null -eq $givenSeconds) { [Console]::Error.WriteLine("heavy: --estimate takes a time such as 90s, 10m or 2h, not '$given'."); exit 2 }
}
$me = "pid $PID, $kind, since {0}, cwd {1}" + $(if ($thread) { ", thread " + ($thread -replace '\{', '{{' -replace '\}', '}}') }) + $(if ($null -ne $givenSeconds) { ", estimate $($givenSeconds)s" }) + ': {2}'
$ticket = Join-Path $queueDir ('{0:D20}-{1}.txt' -f [DateTime]::UtcNow.Ticks, $PID)
$queuedAt = Get-Date
Write-Shared $ticket ($me -f $queuedAt.ToString('MM-dd HH:mm:ss'), (Get-Location).Path, $label)
Write-Page

function First-In-Queue
{
  foreach ($w in @(Get-ChildItem $queueDir -File -ErrorAction SilentlyContinue | Sort-Object Name))
  {
    $id = [int](($w.BaseName -split '-')[1])
    if ($id -eq $PID) { return $true }
    if (Alive $id) { return $false }
    Remove-Item $w.FullName -Force -ErrorAction SilentlyContinue
  }
  return $true
}

function Machine-Held
{
  $first = Get-Content $schedule -TotalCount 1 -ErrorAction SilentlyContinue
  if ($first -and $first.Trim() -ne 'HOLD: no') { return "$(Split-Path -Leaf $schedule) line 1 is '$($first.Trim())'" }
  if (Test-Path $flag)
  {
    $text = Get-Content -Raw $flag -ErrorAction SilentlyContinue
    if ($text -match 'heavy pid (\d+)' -and -not (Alive ([int]$matches[1]))) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }
    else { return '$(Split-Path -Leaf $flag) exists' }
  }
  return $null
}

$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$held = $false
$said = ''
$code = 1
try
{
  while (-not $held)
  {
    $why = $null
    if (-not (First-In-Queue)) { $why = 'queued behind an earlier job' }
    if (-not $why) { $why = Machine-Held }
    if (-not $why)
    {
      try { $held = $mutex.WaitOne(2000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
      if (-not $held) { $why = 'the heavy slot is taken' }
    }
    if ($held) { break }
    $holder = if (Test-Path $holderFile) { (Get-Content -Raw $holderFile -ErrorAction SilentlyContinue).Trim() } else { '' }
    $now = "heavy: waiting ($why). holder: $holder"
    if ($now -ne $said) { [Console]::Error.WriteLine($now); $said = $now; Write-Page }
    Start-Sleep -Seconds 3
  }
  Remove-Item $ticket -Force -ErrorAction SilentlyContinue
  $startedAt = Get-Date
  $atStart = Estimate ([pscustomobject]@{ Given = $givenSeconds; Label = $label; Thread = $thread; Cwd = (Get-Location).Path; Kind = $kind })
  Write-Shared $holderFile ($me -f $startedAt.ToString('MM-dd HH:mm:ss'), (Get-Location).Path, $label)
  Write-Page

  if ($exclusive)
  {
    Write-Shared $flag "heavy pid $PID ($label)"
    # Otherwise idle: total CPU under 15% for 20 seconds in a row (a desktop with a few apps open sits near 7%).
    $quiet = 0
    $said = ''
    while ($quiet -lt 20)
    {
      $load = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
      if ($load -lt 15) { $quiet += 2 } else
      {
        $quiet = 0
        $now = 'heavy: exclusive, waiting for the machine to go idle'
        if ($now -ne $said) { [Console]::Error.WriteLine("$now (load $load%)"); $said = $now }
      }
      Start-Sleep -Seconds 2
    }
  }
  $code = Run-Command
  # Stopped from outside (ROOT\stopped-PID.txt says why, e.g. its machine was closed): said
  # here, so the thread knows to run the job again, there or elsewhere.
  $stopped = Join-Path $root "stopped-$PID.txt"
  if (Test-Path $stopped)
  {
    [Console]::Error.WriteLine('heavy: STOPPED: ' + ((Get-Content -Raw $stopped -ErrorAction SilentlyContinue) + '').Trim() + ' Run it again.')
    Remove-Item $stopped -Force -ErrorAction SilentlyContinue
    if ($code -eq 0) { $code = 1 }
  }
}
finally
{
  Remove-Item $ticket -Force -ErrorAction SilentlyContinue
  if ($held)
  {
    if ($exclusive) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }
    Remove-Item $holderFile -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $clean = ($label -replace "[`t`r`n]", ' ')
    $record = @($queuedAt.ToString('s'), $startedAt.ToString('s'), (Get-Date).ToString('s'), "$code", $kind, (Get-Location).Path, $clean, $thread, $(if ($atStart) { "$($atStart.seconds) $($atStart.basis)" } else { '' })) -join "`t"
    try { Add-Content -Path $historyFile -Encoding UTF8 -Value $record } catch { }
  }
  $mutex.Dispose()
  Write-Page
}
exit $code
