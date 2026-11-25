# heavy-queue's lock: runs one command line while holding the machine's one heavy slot, so heavy jobs
# (builds, test runs, benchmarks) run one at a time. --exclusive (benchmarks and every timing run) takes the
# same slot and then also waits until the machine is otherwise idle.
#
#   heavy.cmd [--exclusive] [--name TEXT] [--estimate 90s|10m|2h] [--local | --travel] COMMAND LINE...
#   heavy.cmd --detach [--log FILE] [the same options] COMMAND LINE...
#   heavy.cmd --status
#
# --detach returns at once and runs the job (its wait included) in a process of its own outside the caller's
# process tree, its output in a log file and its exit code in LOG.exit (lock\detached.ps1): a job that
# outlives whoever started it, such as a Claude session the desktop app stops after an hour without a turn.
#
# While it waits, a job may run on another machine instead, in a copy of its git checkout made there, its
# output, files and exit code coming back (lock\travel.ps1). --local keeps it here; an --exclusive job goes only with --travel.
#
# The slot is a named mutex: Windows frees it when its holder dies, so a killed job never leaves the
# machine locked. Waiters queue in arrival order (ROOT\queue, one file per waiting process; a dead waiter's
# file is dropped). The holder is in ROOT\holder.txt. The command runs with HEAVY_QUEUE_HELD set (and the
# config's heldVariable): a heavy script it calls runs at once instead of waiting for its own parent. It
# also waits while the hold file's line 1 is not "HOLD: no" or a quiet flag whose holder is alive exists,
# and an --exclusive job holds that flag while it runs. The exit code is the command's.
#
# config.json in the repository's root (kept out of git; HEAVY_QUEUE_CONFIG names another file) says where
# things are (lock\config.ps1 reads it; lock\README.md lists the settings and their defaults).
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
$stayHere = $false
$mayTravel = $false
$travelledFile = ''
$detach = $false
$logGiven = ''
while ($true)
{
  if ($line -match '^--detach(\s+|$)(.*)$') { $detach = $true; $line = $matches[2]; continue }
  if ($line -match '^--log\s+"([^"]+)"\s*(.*)$') { $logGiven = $matches[1]; $line = $matches[2]; continue }
  if ($line -match '^--log\s+(\S+)\s*(.*)$') { $logGiven = $matches[1]; $line = $matches[2]; continue }
  if ($line -match '^--exclusive(\s+|$)(.*)$') { $exclusive = $true; $line = $matches[2]; continue }
  if ($line -match '^--estimate\s+(\S+)\s*(.*)$') { $given = $matches[1]; $line = $matches[2]; continue }
  if ($line -match '^--status(\s+|$)(.*)$') { $status = $true; $line = $matches[2]; continue }
  if ($line -match '^--name\s+"([^"]*)"\s*(.*)$') { $name = $matches[1]; $line = $matches[2]; continue }
  if ($line -match '^--name\s+(\S+)\s*(.*)$') { $name = $matches[1]; $line = $matches[2]; continue }
  if ($line -match '^--local(\s+|$)(.*)$') { $stayHere = $true; $line = $matches[2]; continue }
  if ($line -match '^--travel(\s+|$)(.*)$') { $mayTravel = $true; $line = $matches[2]; continue }
  # (machine\worker.ps1: run another machine's job, claimed for this one)
  if ($line -match '^--run-travelled\s+"([^"]+)"\s*$') { $travelledFile = $matches[1]; $line = ''; continue }
  break
}
. (Join-Path $PSScriptRoot 'travel.ps1')

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

# A status file put in place by renaming a new one over it, tried again for up to 2 seconds: two jobs writing
# their pages at once, or a reader of the old one, made the rename fail ("Cannot create a file when that
# file already exists", 2026-11-24).
function Move-Over([string]$from, [string]$to)
{
  for ($i = 0; ; $i++)
  {
    try { Move-Item -Force -LiteralPath $from -Destination $to; return }
    catch { if ($i -ge 20) { Remove-Item -LiteralPath $from -Force -ErrorAction SilentlyContinue; throw }; Start-Sleep -Milliseconds 100 }
  }
}

function Alive([int]$id) { return $null -ne (Get-Process -Id $id -ErrorAction SilentlyContinue) }

# The line's order, the same for every waiter and page: the queue files' names hold when each job was queued
# and its estimate when it was (TICKS-PID-eSECONDS.txt), so the order depends on nothing that changes. With
# shortestFirst (the default), the job with the smallest estimate plus the time it was queued goes first: a
# shorter job passes a longer one, and every second a job waits counts as a second off its estimate, so a long
# job passes everything queued after it once it has waited its own length and starves nobody. A job without
# an estimate counts as unknownEstimate seconds (an hour); a file from an older lock (no estimate) too.
# shortestFirst false: first come, first served.
function Queue-Order
{
  $list = foreach ($w in @(Get-ChildItem $queueDir -File -ErrorAction SilentlyContinue))
  {
    if ($w.Name -notmatch '^(\d{20})-(\d+)(?:-e(\d+))?\.txt$') { continue }
    $id = [int]$matches[2]
    if ($id -ne $PID -and -not (Alive $id)) { Remove-Item $w.FullName -Force -ErrorAction SilentlyContinue; continue } # (a waiter that died)
    $eta = if ($matches[3]) { [double]$matches[3] } else { [double]$unknownEstimate }
    $queued = [double]([long]$matches[1] / 10000000)
    [pscustomobject]@{ File = $w; Pid = $id; Id = "$($matches[1])-$($matches[2])"; Key = $(if ($shortestFirst) { $eta + $queued } else { $queued }) }
  }
  return @($list | Sort-Object Key, Id)
}

function Show-Status
{
  $text = if (Test-Path $holderFile) { (Get-Content -Raw $holderFile -ErrorAction SilentlyContinue).Trim() } else { '' }
  if ($text -match '^pid (\d+)' -and (Alive ([int]$matches[1]))) { 'holder: ' + $text } else { 'holder: none' }
  $waiting = @(Queue-Order)
  'waiting: ' + $waiting.Count
  foreach ($w in $waiting) { '  ' + (Get-Content -Raw $w.File.FullName -ErrorAction SilentlyContinue).Trim() }
}

# status.html: the holder, the queue and the last 200 finished jobs (history.tsv), written again on
# every enqueue, start and finish; the open page reloads itself every 5 s and counts the running times.
$historyFile = Join-Path $root 'history.tsv'
$pageFile = Join-Path $root 'status.html'

function Html([string]$text) { return [System.Net.WebUtility]::HtmlEncode($text) }
function Iso([DateTime]$time) { return $time.ToString('yyyy-MM-ddTHH:mm:sszzz') }
function MdText([string]$text) { return ($text -replace '`', "'" -replace '\|', '/') }

function Owner([string]$thread, [string]$cwd) { if ($thread) { return $thread } return (Who $cwd) }

# Who started this job (the page's thread column): HEAVY_QUEUE_THREAD when set; else, inside a Claude Code
# session of the desktop app, that session's title (CLAUDE_CODE_HOST_SESSION_ID and the app's record of
# it); else empty, and the page names the job's folder. ':' is written '-' (the records use ': ').
function Thread-Title
{
  if ($env:HEAVY_QUEUE_THREAD) { return ($env:HEAVY_QUEUE_THREAD -replace '[:\t\r\n]', '-') }
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

# A folder as the page shows it: a Claude Code worktree's name, else its last two parts.
function Who([string]$cwd)
{
  if ($cwd -match '\\\.claude\\worktrees\\([^\\]+)') { return $matches[1] }
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
# the last 5 successful runs with the same name; else of the last 5 successful jobs of the same thread;
# else of the last 5 successful jobs of the same kind. A name is the label's first three words in lower
# case, a path among them cut to its last two parts and every number counted alike, so the same script
# from another folder, or another numbered run, is the same job. Tried on a first machine's 223 finished
# jobs: within 2x for 88% of the jobs matched by name, 50% of those matched only by thread. history.tsv's
# ninth column is the estimate a job had when it started (with its basis), to see how good they are.
function Estimate-Key([string]$label)
{
  $words = foreach ($w in @($label.ToLowerInvariant() -split '\s+' | Where-Object { $_ } | Select-Object -First 3))
  {
    $w = $w.Trim('"', "'")
    $parts = @($w -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -ge 2) { $w = $parts[-2] + '\' + $parts[-1] }
    $w -replace '\d+', '#'
  }
  return @($words) -join ' '
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
  foreach ($l in @(Get-Content $historyFile -Tail 3000 -ErrorAction SilentlyContinue)) # (the recent past is enough, and keeps each page write quick)
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

# What holds the line besides the slot itself, or '': the hold file's line 1 when it is not "HOLD: no", or
# the quiet flag while its holder lives. The flag of the job running now (an --exclusive job holds it) does
# not count when that job's pid is given: it holds the slot anyway.
function Hold-Reason([int]$runningPid = 0)
{
  $first = Get-Content $schedule -TotalCount 1 -ErrorAction SilentlyContinue
  if ($first -and $first.Trim() -ne 'HOLD: no') { return "$(Split-Path -Leaf $schedule) line 1 is '$($first.Trim())'" }
  if (Test-Path $flag)
  {
    $text = (Get-Content -Raw $flag -ErrorAction SilentlyContinue) + ''
    if ($text -match 'heavy pid (\d+)' -and (([int]$matches[1] -eq $runningPid) -or -not (Alive ([int]$matches[1])))) { return '' }
    return "$(Split-Path -Leaf $flag) exists"
  }
  return ''
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
    # in the line has no estimate, or while the line is held). An exclusive job's idle wait is not counted.
    $next = $now
    $rows = New-Object System.Text.StringBuilder
    $holder = $null
    if (Test-Path $holderFile) { $holder = Parse-Record ((Get-Content -Raw $holderFile -ErrorAction SilentlyContinue) + '').Trim() }
    $running = $holder -and (Alive $holder.Pid)
    $heldWhy = Hold-Reason $(if ($running) { $holder.Pid } else { 0 })
    if ($running)
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
    if ($heldWhy) { $next = $null }
    # On a worker (machine\worker.ps1 writes ROOT\worker.txt): what it does for its home, or why it does not.
    $workerNote = Read-Small (Join-Path $root 'worker.txt')
    # This machine's jobs that travelled and run elsewhere now (their worker's status shows them too).
    $jElsewhere = New-Object System.Collections.ArrayList
    $claims = if ($travelExchange) { @(Get-ChildItem $travelExchange -Filter '*.claim' -File -ErrorAction SilentlyContinue | Sort-Object Name) } else { @() }
    foreach ($claim in $claims)
    {
      $id = $claim.Name -replace '\.claim$', ''
      $who = Read-Small $claim.FullName
      if (-not $who -or $who -eq $machine -or (Test-Path (Travel-File $id 'exit'))) { continue }
      $text = Read-Small (Travel-File $id 'job.json')
      if (-not $text) { continue }
      $o = $text | ConvertFrom-Json
      if ($o.machine -ne $machine) { continue }
      [void]$jElsewhere.Add([ordered]@{ machine = $who; kind = $o.kind; thread = (Owner $o.thread $o.cwd); folder = (Who $o.cwd); label = $o.label; since = $o.queued })
      [void]$rows.Append("<tr><td class='kind travelled'>on $(Html $who)</td><td>$(Html (Owner $o.thread $o.cwd))</td><td class='cmd'>$(Html $o.label)</td><td></td><td></td><td></td><td></td><td>$(Html $who)</td></tr>")
      [void]$md.Append("| on $who | $(Owner $o.thread $o.cwd) | ``$(MdText $o.label)`` | | | | |`n")
    }
    $mdQueue = New-Object System.Text.StringBuilder
    $queue = New-Object System.Text.StringBuilder
    $n = 0
    foreach ($q in @(Queue-Order))
    {
      $w = $q.File
      $r = Parse-Record ((Get-Content -Raw $w.FullName -ErrorAction SilentlyContinue) + '').Trim()
      if (-not $r) { continue }
      $n++
      $job = [ordered]@{ kind = $r.Kind; thread = (Owner $r.Thread $r.Cwd); folder = (Who $r.Cwd); label = $r.Label; since = (Iso $r.Since) }
      $stays = Read-Small (Join-Path $travelDir "$($q.Id).stays")
      $travelNote = ''
      if ($travelExchange -and (Test-Path (Join-Path $travelExchange "$($q.Id).job.json"))) { $job.travel = $true; $travelNote = ' (may travel)' }
      elseif ($stays) { $job.stays = $stays; $travelNote = " (stays here: $stays)" }
      $e = Estimate $r
      $estText = ''; $startText = ''
      if ($e) { $job.estimate = $e.seconds; $job.basis = $e.basis; $estText = (Duration ([TimeSpan]::FromSeconds($e.seconds))) + " ($($e.basis))" }
      if ($null -ne $next)
      {
        $job.starts = (Iso $next); $startText = '~' + (Short-Time $next)
        if ($e) { $next = $next.AddSeconds($e.seconds); $job.done = (Iso $next); $startText += ' - ~' + (Short-Time $next) } else { $next = $null }
      }
      elseif ($heldWhy) { $startText = 'held' }
      [void]$jQueue.Add($job)
      [void]$queue.Append("<tr><td>$n</td><td class='kind $($r.Kind)'>$($r.Kind)</td><td>$(Html (Owner $r.Thread $r.Cwd))</td><td class='cmd'>$(Html $r.Label)<span class='muted'>$(Html $travelNote)</span></td><td>$($r.Since.ToString('HH:mm:ss'))</td><td class='run' data-since='$($r.Since.ToString('s'))'></td><td>$estText</td><td>$startText</td></tr>")
      [void]$mdQueue.Append("| $n | $($r.Kind) | $(Owner $r.Thread $r.Cwd) | ``$(MdText $r.Label)``$travelNote | $($r.Since.ToString('HH:mm')) | $(Duration ($now - $r.Since)) | $estText | $startText |`n")
    }
    if ($n -eq 0) { [void]$queue.Append("<tr><td colspan='8' class='none'>nobody waiting</td></tr>") }
    $mdHistory = New-Object System.Text.StringBuilder
    $history = New-Object System.Text.StringBuilder
    $lines = @(Get-Content $historyFile -Tail 200 -ErrorAction SilentlyContinue)
    [array]::Reverse($lines)
    foreach ($l in $lines)
    {
      # queued, started, finished (ISO), exit code, kind, cwd, label, thread, estimate at its start ("SECONDS BASIS"),
      # the machine it travelled to
      $f = $l.TrimStart([char]0xFEFF) -split "`t"
      if ($f.Count -lt 7) { continue }
      $owner = if ($f.Count -ge 8) { Owner $f[7] $f[5] } else { Who $f[5] }; $queued = [DateTime]$f[0]; $started = [DateTime]$f[1]; $ended = [DateTime]$f[2]
      $ok = if ($f[3] -eq '0') { 'ok' } else { 'bad' }
      $guess = $null; $guessBasis = ''; $guessText = ''
      if ($f.Count -ge 9 -and $f[8] -match '^(\d+) (\w+)$') { $guess = [int]$matches[1]; $guessBasis = $matches[2]; $guessText = (Duration ([TimeSpan]::FromSeconds($guess))) + " ($guessBasis)" }
      if ($jFinished.Count -lt 100)
      {
        $job = [ordered]@{ kind = $f[4]; thread = $owner; folder = (Who $f[5]); label = $f[6]; queued = (Iso $queued); started = (Iso $started); ended = (Iso $ended); exit = [int]$f[3] }
        if ($null -ne $guess) { $job.estimate = $guess; $job.basis = $guessBasis }
        if ($f.Count -ge 10 -and $f[9]) { $job.ranOn = $f[9] }
        [void]$jFinished.Add($job)
      }
      $ranOn = if ($f.Count -ge 10 -and $f[9]) { " (ran on $($f[9]))" } else { '' }
      [void]$history.Append("<tr><td class='kind $($f[4])'>$($f[4])</td><td>$(Html $owner)</td><td class='cmd'>$(Html $f[6])<span class='muted'>$(Html $ranOn)</span></td><td>$($started.ToString('MM-dd HH:mm'))</td><td>$(Duration ($started - $queued))</td><td>$(Duration ($ended - $started))</td><td>$guessText</td><td class='$ok'>$($f[3])</td></tr>")
      if ($mdHistory.Length -lt 20000) { [void]$mdHistory.Append("| $($f[4]) | $owner | ``$(MdText $f[6])``$ranOn | $($started.ToString('MM-dd HH:mm')) | $(Duration ($started - $queued)) | $(Duration ($ended - $started)) | $guessText | $(if ($f[3] -eq '0') { '0' } else { '**' + $f[3] + '**' }) |`n") }
    }
    if ($lines.Count -eq 0) { [void]$history.Append("<tr><td colspan='8' class='none'>none yet</td></tr>") }
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
<div class="muted">One heavy job at a time. Written $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); reloads every 5 s.$(if ($workerNote) { ' ' + (Html $workerNote) })</div>
$(if ($heldWhy) { "<p class='bad'>Held: $(Html $heldWhy). No job starts until it is released.</p>" })
<h2>Running</h2>
<table><tr><th>kind</th><th>thread</th><th>command</th><th>started</th><th>running</th><th>estimate</th><th>done</th><th>pid</th></tr>$($rows.ToString())</table>
<h2>Waiting</h2>
<table><tr><th>#</th><th>kind</th><th>thread</th><th>command</th><th>queued</th><th>waiting</th><th>estimate</th><th>runs</th></tr>$($queue.ToString())</table>
<h2>Finished (last 200)</h2>
<table><tr><th>kind</th><th>thread</th><th>command</th><th>started</th><th>waited</th><th>took</th><th>estimate</th><th>exit</th></tr>$($history.ToString())</table>
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
    Move-Over $temp $pageFile
    # The same as markdown (status.md), for reading in a terminal or an editor.
    $noneQueue = if ($mdQueue.Length) { '' } else { "| | nobody waiting | | | | | | |`n" }
    $text = "# $title`n`nWritten $($now.ToString('yyyy-MM-dd HH:mm:ss')) (this machine's times; durations as of then).`n`n" +
      $(if ($heldWhy) { "**Held:** $(MdText $heldWhy). No job starts until it is released.`n`n" }) +
      "## Running`n`n| kind | thread | command | started | running | estimate | done |`n|---|---|---|---|---|---|---|`n" + $md.ToString() +
      "`n## Waiting`n`n| # | kind | thread | command | queued | waiting | estimate | runs |`n|---|---|---|---|---|---|---|---|`n" + $mdQueue.ToString() + $noneQueue +
      "`n## Finished`n`n| kind | thread | command | started | waited | took | estimate | exit |`n|---|---|---|---|---|---|---|---|`n" + $mdHistory.ToString()
    $mdFile = Join-Path $root 'status.md'
    # And as JSON (status.json), for whatever shows the status elsewhere: with ROOT\publish.txt (the board's
    # address and password), machine\publish.ps1 is started after every change and posts it to the board.
    $whole = [ordered]@{ written = (Iso $now); running = $jRunning; queue = @($jQueue); finished = @($jFinished) }
    if ($heldWhy) { $whole.held = $heldWhy }
    if ($jElsewhere.Count) { $whole.elsewhere = @($jElsewhere) }
    if ($workerNote) { $whole.worker = $workerNote }
    $json = ($whole | ConvertTo-Json -Depth 4 -Compress)
    $jsonFile = Join-Path $root 'status.json'
    [IO.File]::WriteAllText("$jsonFile.$PID.tmp", $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Over "$jsonFile.$PID.tmp" $jsonFile
    [IO.File]::WriteAllText("$mdFile.$PID.tmp", $text, (New-Object System.Text.UTF8Encoding($false)))
    Move-Over "$mdFile.$PID.tmp" $mdFile
    if (Test-Path (Join-Path $root 'publish.txt'))
    {
      Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$repo\machine\publish.ps1`"")
    }
  }
  catch { try { Set-Content -Path (Join-Path $root 'page-error.txt') -Value "$(Get-Date -Format s) $_ $($_.InvocationInfo.PositionMessage)" } catch { } } # (the page is a view: a failed write never stops a job)
}

if ($status) { Show-Status; Write-Page; exit 0 }
# --help, -h, /? or any option this lock does not know: the usage, never a job (three threads queued "--help"
# as a command line, 2026-11-25).
if ($line -match '^(--\S*|-h|-\?|/\?|/h|/help)(\s|$)') { [Console]::Error.WriteLine("heavy: $(if ($matches[1] -match '^(--help|-h|-\?|/\?|/h|/help)$') { 'usage' } else { "unknown option $($matches[1])" })"); $line = '' }
if (-not $line -and -not $travelledFile) { 'usage:heavy.cmd [--detach [--log FILE]] [--exclusive] [--name TEXT] [--estimate 90s|10m|2h] [--local | --travel] COMMAND LINE...  |  heavy.cmd --status'; exit 2 }
if ($logGiven -and -not $detach) { [Console]::Error.WriteLine('heavy: --log goes with --detach.'); exit 2 }

# --detach: the same job, started by WMI (so its parent is WMI's service, not this process: whatever ends
# the caller's process tree or job object leaves it running), queued and run as any other. This process
# returns at once. The job's environment is this one, without secrets (written to disk for the moment it
# takes the job to start, as travelling jobs leave them out too).
if ($detach)
{
  if ($env:HEAVY_QUEUE_HELD -or ($heldVariable -and [Environment]::GetEnvironmentVariable($heldVariable)))
  {
    [Console]::Error.WriteLine('heavy: --detach inside a heavy job: the job would run without the slot once its parent ends.')
    exit 2
  }
  $detachDir = Join-Path $root 'detached'
  New-Item -ItemType Directory -Force $detachDir | Out-Null
  $id = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID
  $log = if ($logGiven) { [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).Path, $logGiven)) } else { Join-Path $detachDir "$id.log" }
  $options = @()
  if ($exclusive) { $options += '--exclusive' }
  if ($name) { $options += "--name `"$name`"" }
  if ($given) { $options += "--estimate $given" }
  if ($stayHere) { $options += '--local' }
  if ($mayTravel) { $options += '--travel' }
  $whole = (@($options) + $line) -join ' '
  $environment = Travel-Environment
  foreach ($n in @('COMPUTERNAME', 'TEMP', 'TMP', 'APPDATA', 'LOCALAPPDATA', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'ProgramData', 'ALLUSERSPROFILE', 'windir', 'SystemRoot', 'SystemDrive', 'OS', 'ComSpec', 'PSModulePath', 'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE'))
  {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($null -ne $v) { $environment[$n] = $v } # (the same machine: its own folders stay)
  }
  if ($env:HEAVY_QUEUE_CONFIG) { $environment['HEAVY_QUEUE_CONFIG'] = $env:HEAVY_QUEUE_CONFIG }
  if ($env:HEAVY_QUEUE_THREAD) { $environment['HEAVY_QUEUE_THREAD'] = $env:HEAVY_QUEUE_THREAD }
  New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
  Remove-Item -LiteralPath "$log.exit" -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText($log, '', (New-Object System.Text.UTF8Encoding($false)))
  $jobFile = Join-Path $detachDir "$id.json"
  $job = [ordered]@{ cwd = (Get-Location).Path; line = $whole; log = $log; env = $environment }
  Write-Shared $jobFile ($job | ConvertTo-Json -Depth 3 -Compress)
  $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
  $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\detached.ps1`" `"$jobFile`""
  $made = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command; CurrentDirectory = (Get-Location).Path; ProcessStartupInformation = $startup }
  if ($made.ReturnValue -ne 0)
  {
    Remove-Item -LiteralPath $jobFile -Force -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("heavy: could not start the detached job (Win32_Process.Create returned $($made.ReturnValue)).")
    exit 1
  }
  "heavy: detached (pid $($made.ProcessId)): $whole"
  "heavy: output in $log; when the job ends, $log.exit holds its exit code."
  exit 0
}

# A job that travelled here (machine\worker.ps1 claimed it): its home's offer gives the command line, the
# environment and what to show. Its folder is made once this machine's slot is held and the home's state is in
# the exchange; its output and exit code go back through the exchange, and a home that stops watching (its
# waiter gone) stops the job.
$travelled = $null
if ($travelledFile)
{
  $travelled = Get-Content -Raw $travelledFile | ConvertFrom-Json
  $line = $travelled.line
  $exclusive = $travelled.kind -eq 'exclusive'
  $name = "$($travelled.label) (from $($travelled.machine))"
  if ($null -ne $travelled.estimate) { $given = "$($travelled.estimate)s" }
  $env:HEAVY_QUEUE_THREAD = $travelled.thread
}

function Run-Command
{
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $env:ComSpec
  $info.Arguments = '/d /s /c "' + $line + '"'
  $info.UseShellExecute = $false
  $info.WorkingDirectory = (Get-Location).Path
  if ($travelled)
  {
    # (the home's tool folders are this worker's copies of them: lock\travel.ps1's Take-Tools)
    foreach ($p in $travelled.env.PSObject.Properties) { $info.EnvironmentVariables[$p.Name] = Tool-Rewrite ([string]$p.Value) $travelled.tools }
    $pathName = @($info.EnvironmentVariables.Keys | Where-Object { $_ -eq 'PATH' })[0]
    if ($travelled.tools -and $pathName) { $info.EnvironmentVariables[$pathName] = Tool-PathVariable ([string]$info.EnvironmentVariables[$pathName]) $travelled.tools }
    $info.Arguments = '/d /s /c "' + (Tool-Rewrite $line $travelled.tools) + '"'
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
  }
  $info.EnvironmentVariables['HEAVY_QUEUE_HELD'] = "$PID"
  if ($heldVariable) { $info.EnvironmentVariables[$heldVariable] = "$PID" }
  # (and the home's: its scripts' own lock calls, such as a gate that takes the slot itself, run at once here too)
  if ($travelled -and $travelled.held) { $info.EnvironmentVariables[[string]$travelled.held] = "$PID" }
  $process = [System.Diagnostics.Process]::Start($info)
  if ($travelled) { $process.StandardInput.Close() } # (nobody types into a job that travelled)
  if (-not $travelled)
  {
    $process.WaitForExit()
    return $process.ExitCode
  }
  # Its output into the exchange as it comes (unbuffered, so the home's waiter shows it at once), a heartbeat
  # every 5 s, and the home's waiter watched: gone for travelStale seconds, the job is stopped.
  $outFile = New-Object IO.FileStream((Travel-File $travelled.id 'out'), [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite, 1)
  $errFile = New-Object IO.FileStream((Travel-File $travelled.id 'err'), [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite, 1)
  $copyOut = $process.StandardOutput.BaseStream.CopyToAsync($outFile)
  $copyErr = $process.StandardError.BaseStream.CopyToAsync($errFile)
  $watch = Travel-File $travelled.id 'watch'
  while (-not $process.WaitForExit(5000))
  {
    Beat (Travel-File $travelled.id 'alive') 'running'
    if (-not (Fresh $watch))
    {
      $script:abandoned = $true
      & taskkill /T /F /PID $process.Id 2>&1 | Out-Null
    }
  }
  # (a process the job left running may still hold the pipes: their copies get 10 s, then are let go)
  try { [void]$copyOut.Wait(10000) } catch { }
  try { [void]$copyErr.Wait(10000) } catch { }
  $outFile.Close(); $errFile.Close()
  return $process.ExitCode
}

# Inside a heavy job already (its own child): no second wait. Under CI (CI or GITHUB_ACTIONS set) a runner
# runs one job anyway: no lock either.
if (-not $travelled -and ($env:HEAVY_QUEUE_HELD -or ($heldVariable -and [Environment]::GetEnvironmentVariable($heldVariable)) -or $env:CI -or $env:GITHUB_ACTIONS)) { exit (Run-Command) }

# A config made for another computer (its "computer"): refused, as the lock would hold this computer's slot
# for another machine's queue.
if ($computer -and $computer -ne $env:COMPUTERNAME)
{
  [Console]::Error.WriteLine("heavy: $configFile belongs to $computer, not $($env:COMPUTERNAME): run this machine's own lock.")
  exit 2
}
New-Item -ItemType Directory -Force $queueDir | Out-Null
# A machine too slow or too different for timing has ROOT\no-benchmarks: an --exclusive job is refused there
# at once.
if ($exclusive -and (Test-Path (Join-Path $root 'no-benchmarks')))
{
  [Console]::Error.WriteLine("heavy: $machine does not run benchmarks or timing runs ($root\no-benchmarks): run --exclusive jobs on a benchmark machine.")
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
# (HEAVY_QUEUE_SINCE, UTC ticks: a job queued again keeps its place, such as one moved to a newer lock)
$queuedTicks = if ($env:HEAVY_QUEUE_SINCE -match '^\d{1,20}$') { [long]$env:HEAVY_QUEUE_SINCE } else { [DateTime]::UtcNow.Ticks }
Remove-Item Env:\HEAVY_QUEUE_SINCE -ErrorAction SilentlyContinue
$ticketName = '{0:D20}-{1}' -f $queuedTicks, $PID
$queueGuess = Estimate ([pscustomobject]@{ Given = $givenSeconds; Label = $label; Thread = $thread; Cwd = (Get-Location).Path; Kind = $kind })
$ticket = Join-Path $queueDir ("$ticketName-e{0}.txt" -f $(if ($queueGuess) { [int]$queueGuess.seconds } else { [int]$unknownEstimate }))
$queuedAt = ([DateTime]::new($queuedTicks, [DateTimeKind]::Utc)).ToLocalTime()
Write-Shared $ticket ($me -f $queuedAt.ToString('MM-dd HH:mm:ss'), (Get-Location).Path, $label)

# The offer, when this job may travel (lock\travel.ps1); when it asked to travel and may not, the reason.
$offer = ''
if (-not $travelled)
{
  # (every job may travel but an --exclusive one: a timing run's numbers belong to this machine unless it asks)
  $plan = Travel-Plan (Get-Location).Path $line $stayHere ($mayTravel -or ($travelByDefault -and ((-not $exclusive) -or $travelExclusive)))
  $stayReason = $plan.Why
  if (-not $stayReason)
  {
    New-Item -ItemType Directory -Force $travelExchange | Out-Null
    Clear-Dead-Offers
    $guess = Estimate ([pscustomobject]@{ Given = $givenSeconds; Label = $label; Thread = $thread; Cwd = (Get-Location).Path; Kind = $kind })
    $job = [ordered]@{ id = $ticketName; machine = $machine; pid = $PID; cwd = (Get-Location).Path; line = $line; label = $label; kind = $kind; thread = $thread
      estimate = $(if ($guess) { $guess.seconds } else { $null }); queued = (Iso $queuedAt); fingerprintCommands = @($fingerprintCommands); tools = (Offer-Tools); fingerprint = (Fingerprint); env = (Travel-Environment); held = $heldVariable; folders = @($plan.Folders) }
    Beat (Travel-File $ticketName 'waiting') 'waiting'
    Write-Shared (Travel-File $ticketName 'job.json') ($job | ConvertTo-Json -Depth 3 -Compress)
    $offer = $ticketName
    $offeredAt = Get-Date
  }
  elseif ($travelExchange)
  {
    New-Item -ItemType Directory -Force $travelDir | Out-Null
    Write-Shared (Travel-File $ticketName 'stays') $stayReason
  }
}
Write-Page

# (waiters of an older lock order the line by age alone: when nobody has held the slot for 15 s, the oldest
# waiter takes it whatever the order says, so two that disagree never wait for each other)
$script:freeSince = $null
function First-In-Queue
{
  $order = @(Queue-Order)
  if ($order.Count -eq 0 -or $order[0].Pid -eq $PID) { $script:freeSince = $null; return $true }
  if (Test-Path $holderFile) { $script:freeSince = $null; return $false }
  if (-not $script:freeSince) { $script:freeSince = Get-Date; return $false }
  if (((Get-Date) - $script:freeSince).TotalSeconds -lt 15) { return $false }
  return ((@($order | Sort-Object Id)[0]).Pid -eq $PID)
}

# Why this waiter may not start yet besides the slot, or $null. A quiet flag whose holder died is removed.
function Machine-Held
{
  if (Test-Path $flag)
  {
    $text = (Get-Content -Raw $flag -ErrorAction SilentlyContinue) + ''
    if ($text -match 'heavy pid (\d+)' -and -not (Alive ([int]$matches[1]))) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }
  }
  $why = Hold-Reason
  if ($why) { return $why }
  return $null
}

$mutex = New-Object System.Threading.Mutex($false, $mutexName)
# Whoever started this waiter (heavy.cmd's cmd.exe): gone while the job waits (a caller stopped from outside),
# the job is no longer wanted and leaves the line.
$parentPid = 0
try { $parentPid = [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId } catch { }
$held = $false
$elsewhere = ''
$ranElsewhere = $false
$stopWhy = ''
$exitWritten = $false
$runIt = $true
$killWithMe = $false
$said = ''
$code = 1
try
{
  while ($true)
  {
    while (-not $held)
    {
      if ($travelled) { Beat (Travel-File $travelled.id 'alive') 'waiting' }
      if ($parentPid -and -not $travelled -and -not (Alive $parentPid)) { [Console]::Error.WriteLine('heavy: whoever started this job is gone: it leaves the line.'); $code = 1; exit 1 }
      if ($offer)
      {
        # (the offer names the tools of now: refreshed every 5 minutes while it waits)
        if (((Get-Date) - $offeredAt).TotalMinutes -ge 5)
        {
          $job.fingerprint = Fingerprint
          Write-Shared (Travel-File $offer 'job.json') ($job | ConvertTo-Json -Depth 3 -Compress)
          $offeredAt = Get-Date
        }
        Beat (Travel-File $offer 'waiting') 'waiting'
        $who = Read-Small (Travel-File $offer 'claim')
        if ($who -and $who -ne $machine) { $elsewhere = $who; break }
      }
      $why = $null
      if (-not (First-In-Queue)) { $why = 'queued behind an earlier job' }
      if (-not $why) { $why = Machine-Held }
      if (-not $why)
      {
        try { $held = $mutex.WaitOne(2000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { $why = 'the heavy slot is taken' }
      }
      # This machine claims its own job before running it: a worker that claimed it first runs it instead.
      if ($held -and $offer -and -not (Try-Claim (Travel-File $offer 'claim') $machine))
      {
        $who = Read-Small (Travel-File $offer 'claim')
        if ($who -ne $machine) { $mutex.ReleaseMutex(); $held = $false; $elsewhere = $who; break }
      }
      if ($held) { break }
      $holder = if (Test-Path $holderFile) { (Get-Content -Raw $holderFile -ErrorAction SilentlyContinue).Trim() } else { '' }
      $now = "heavy: waiting ($why). holder: $holder"
      if ($now -ne $said) { [Console]::Error.WriteLine($now); $said = $now; Write-Page }
      Start-Sleep -Seconds 3
    }
    if (-not $elsewhere) { break }
    # A worker claimed it: the checkout's state goes over, unless something keeps the job here.
    $refusedWhy = Pack-State $offer (Get-Location).Path $plan.Folders
    if ($refusedWhy)
    {
      [Console]::Error.WriteLine("heavy: stays here after all ($refusedWhy).")
      $offer = ''; $elsewhere = ''
      continue
    }
    Remove-Item $ticket -Force -ErrorAction SilentlyContinue
    $startedAt = Get-Date
    $atStart = Estimate ([pscustomobject]@{ Given = $givenSeconds; Label = $label; Thread = $thread; Cwd = (Get-Location).Path; Kind = $kind })
    Write-Page
    $result = Follow-Remote $offer $elsewhere $plan.Folders
    if ($null -ne $result) { $code = $result; $ranElsewhere = $true; break }
    # Not run there (the worker could not make the checkout): here after all, in its place in the line.
    [Console]::Error.WriteLine("heavy: $elsewhere did not run it: it runs here.")
    Write-Shared $ticket ($me -f $queuedAt.ToString('MM-dd HH:mm:ss'), (Get-Location).Path, $label)
    $offer = ''; $elsewhere = ''
  }
  if (-not $ranElsewhere)
  {
    Remove-Item $ticket -Force -ErrorAction SilentlyContinue
    $startedAt = Get-Date
    $atStart = Estimate ([pscustomobject]@{ Given = $givenSeconds; Label = $label; Thread = $thread; Cwd = (Get-Location).Path; Kind = $kind })
    Write-Shared $holderFile ($me -f $startedAt.ToString('MM-dd HH:mm:ss'), (Get-Location).Path, $label)
    Write-Page
    $runIt = $true
    if ($travelled)
    {
      # The home's state (it packs it once it sees the claim), then the checkout made from it.
      $waitedFrom = Get-Date
      Write-Have $travelled.id $travelled.folders
      while (-not (Test-Path (Travel-File $travelled.id 'ready')) -and -not (Test-Path (Travel-File $travelled.id 'refused')))
      {
        Beat (Travel-File $travelled.id 'alive') 'waiting for the home''s state'
        # (the home beats its waiting file while it packs, which can take minutes)
        if (((Get-Date) - $waitedFrom).TotalSeconds -gt $travelStale + 30 -and -not (Fresh (Travel-File $travelled.id 'waiting'))) { break }
        Start-Sleep -Seconds 1
      }
      if (-not (Test-Path (Travel-File $travelled.id 'ready')))
      {
        $runIt = $false; $exitWritten = $true; $code = 0 # (the home keeps it, or is gone: nothing to tell it)
      }
      else
      {
        try
        {
          Beat (Travel-File $travelled.id 'alive') 'making its checkout'
          # (the tools' copies this job runs with: the worker made them before its claim, unless an older worker did)
          if ($travelled.tools) { $toolWhy = Take-Tools $travelled.tools; if ($toolWhy) { throw $toolWhy } }
          $here = Prepare-Checkout $travelled.id
          $before = Snapshot-Files $script:workerFolders
          Set-Location -LiteralPath $here
        }
        catch
        {
          $runIt = $false; $code = 1
          try { Add-Content -Path (Travel-File $travelled.id 'err') -Value "heavy: $machine could not make the checkout: $($_.Exception.Message)" } catch { }
          Write-Shared (Travel-File $travelled.id 'exit') "notrun: $($_.Exception.Message)"
          $exitWritten = $true
        }
      }
    }
    if ($runIt -and $exclusive)
    {
      Write-Shared $flag "heavy pid $PID ($label)"
      # Otherwise idle: total CPU under idleLoad percent (15) for idleSeconds (20) in a row; a desktop with a
      # few apps open sits near 7%.
      $quiet = 0
      $said = ''
      while ($quiet -lt $idleSeconds)
      {
        if ($travelled) { Beat (Travel-File $travelled.id 'alive') 'waiting for an idle machine' }
        $load = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
        if ($load -lt $idleLoad) { $quiet += 2 } else
        {
          $quiet = 0
          $now = 'heavy: exclusive, waiting for the machine to go idle'
          if ($now -ne $said) { [Console]::Error.WriteLine("$now (load $load%)"); $said = $now }
        }
        Start-Sleep -Seconds 2
      }
    }
    if ($runIt)
    {
      if ($travelled)
      {
        Beat (Travel-File $travelled.id 'alive') 'running'
        $killWithMe = Kill-With-Me $true
        if (-not $killWithMe) { [Console]::Error.WriteLine('heavy: no job object: a lock killed mid-job would leave the job running.') }
      }
      $code = Run-Command
      if ($travelled -and $before)
      {
        try { Beat (Travel-File $travelled.id 'alive') 'sending its files back'; $backNote = Pack-Back $travelled.id $script:workerFolders $before; [Console]::Error.WriteLine("heavy: $backNote") }
        catch { try { Add-Content -Path (Travel-File $travelled.id 'err') -Value "heavy: the job's files could not go back: $($_.Exception.Message)" } catch { }; if ($code -eq 0) { $code = 1 } }
      }
      # Stopped from outside (ROOT\stopped-PID.txt says why, e.g. its machine was closed): said here, so the
      # thread knows to run the job again, there or elsewhere.
      $stopped = Join-Path $root "stopped-$PID.txt"
      if (Test-Path $stopped)
      {
        $stopWhy = ((Get-Content -Raw $stopped -ErrorAction SilentlyContinue) + '').Trim()
        Remove-Item $stopped -Force -ErrorAction SilentlyContinue
      }
      elseif ($script:abandoned) { $stopWhy = "its home ($($travelled.machine)) stopped waiting for it." }
      if ($stopWhy)
      {
        $message = "heavy: STOPPED: $stopWhy Run it again."
        if ($travelled) { try { Add-Content -Path (Travel-File $travelled.id 'err') -Value $message } catch { } } else { [Console]::Error.WriteLine($message) }
        if ($code -eq 0) { $code = 1 }
      }
    }
  }
}
finally
{
  Remove-Item $ticket -Force -ErrorAction SilentlyContinue
  if ($travelled)
  {
    if ($killWithMe) { [void](Kill-With-Me $false) }
    if (-not $exitWritten) { Write-Shared (Travel-File $travelled.id 'exit') "$code$(if ($stopWhy) { ' stopped' })" }
  }
  if ($held -or $ranElsewhere)
  {
    if ($held)
    {
      if ($exclusive -and $runIt) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }
      Remove-Item $holderFile -Force -ErrorAction SilentlyContinue
      $mutex.ReleaseMutex()
    }
    $clean = ($label -replace "[`t`r`n]", ' ')
    $record = @($queuedAt.ToString('s'), $startedAt.ToString('s'), (Get-Date).ToString('s'), "$code", $kind, (Get-Location).Path, $clean, $thread, $(if ($atStart) { "$($atStart.seconds) $($atStart.basis)" } else { '' }), $(if ($ranElsewhere) { $elsewhere } else { '' })) -join "`t"
    if ($ranElsewhere -or $runIt) { try { Add-Content -Path $historyFile -Encoding UTF8 -Value $record } catch { } }
  }
  if (-not $travelled -and $travelExchange) { Remove-Travel $ticketName }
  $mutex.Dispose()
  Write-Page
}
exit $code
