# heavy-queue's threads: which session's jobs wait or run, so that a Claude Code thread's title can show it
# (an hourglass before TITLE while one of its jobs waits, a gear while one runs, plain TITLE otherwise). Dot-sourced after
# config.ps1 by heavy.ps1 (--watch, --shown, --thread) and by claude\stop-hook.ps1.
#
# A job's session is HEAVY_QUEUE_SESSION when set, else the Claude desktop app's session id
# (CLAUDE_CODE_HOST_SESSION_ID, which a session's every command inherits and a detached job keeps); its records
# (holder.txt, the queue's files, ROOT\elsewhere\PID.txt while it runs on a worker) carry it as
# ", session ID". What a thread last showed, its plain title and its watcher are in ROOT\threads\SESSION.json.
$threadsDir = Join-Path $root 'threads'

function Job-Session
{
  $id = if ($env:HEAVY_QUEUE_SESSION) { $env:HEAVY_QUEUE_SESSION } else { $env:CLAUDE_CODE_HOST_SESSION_ID }
  if ("$id" -match '^[\w-]{1,100}$') { return $id }
  return ''
}

function Thread-Alive([int]$id) { if ($id -le 0) { return $false }; return $null -ne (Get-Process -Id $id -ErrorAction SilentlyContinue) }

function Thread-Read([string]$path)
{
  for ($i = 0; $i -lt 5; $i++)
  {
    try { if (-not (Test-Path -LiteralPath $path)) { return '' }; return ([IO.File]::ReadAllText($path)).Trim() }
    catch { Start-Sleep -Milliseconds 50 }
  }
  return ''
}

# The record: @{ session; title; shown (none, waiting, running); watcher (pid); at } or $null.
function Thread-Record([string]$session)
{
  if (-not $session) { return $null }
  $text = Thread-Read (Join-Path $threadsDir "$session.json")
  if (-not $text) { return $null }
  try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Save-Thread-Record([string]$session, $values)
{
  New-Item -ItemType Directory -Force $threadsDir | Out-Null
  $old = Thread-Record $session
  $record = [ordered]@{ session = $session; title = ''; shown = 'none'; watcher = 0; at = '' }
  if ($old) { foreach ($k in @('title', 'shown', 'watcher')) { if ($null -ne $old.$k) { $record[$k] = $old.$k } } }
  foreach ($k in $values.Keys) { $record[$k] = $values[$k] }
  $record.at = (Get-Date).ToString('s')
  $file = Join-Path $threadsDir "$session.json"
  [IO.File]::WriteAllText("$file.$PID.tmp", ($record | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  for ($i = 0; ; $i++)
  {
    try { Move-Item -Force -LiteralPath "$file.$PID.tmp" -Destination $file; return }
    catch { if ($i -ge 20) { Remove-Item -LiteralPath "$file.$PID.tmp" -Force -ErrorAction SilentlyContinue; throw }; Start-Sleep -Milliseconds 100 }
  }
}

# The plain title a thread gave (--thread), for the pages; '' when it gave none.
function Thread-Given-Title([string]$session)
{
  $r = Thread-Record $session
  if ($r -and $r.title) { return ("$($r.title)" -replace '[:\t\r\n]', '-') }
  return ''
}

# @{ state = none, waiting or running; label } of a session's jobs on this machine: running when one holds
# the slot or runs on a worker, else waiting when one is in the line.
function Session-State([string]$session)
{
  $result = [pscustomobject]@{ State = 'none'; Label = '' }
  if (-not $session) { return $result }
  $pattern = ', session ' + [regex]::Escape($session) + '(?:, estimate \d+s)?: (.*)$'
  $text = Thread-Read (Join-Path $root 'holder.txt')
  if ($text -match '^pid (\d+)' -and (Thread-Alive ([int]$matches[1])) -and $text -match $pattern) { $result.State = 'running'; $result.Label = $matches[1].Trim(); return $result }
  foreach ($f in @(Get-ChildItem (Join-Path $root 'elsewhere') -Filter '*.txt' -File -ErrorAction SilentlyContinue))
  {
    if (-not (Thread-Alive ([int]$f.BaseName))) { continue }
    $text = Thread-Read $f.FullName
    if ($text -match $pattern) { $result.State = 'running'; $result.Label = $matches[1].Trim(); return $result }
  }
  foreach ($f in @(Get-ChildItem (Join-Path $root 'queue') -Filter '*.txt' -File -ErrorAction SilentlyContinue))
  {
    if ($f.Name -notmatch '^\d{20}-(\d+|d[0-9x]+)(?:-e\d+)?(?:-p)?\.txt$') { continue }
    $id = $matches[1]
    if ($id.StartsWith('d')) { if (-not (Test-Path -LiteralPath (Join-Path $root "detached\$id.json"))) { continue } }
    elseif (-not (Thread-Alive ([int]$id))) { continue }
    $text = Thread-Read $f.FullName
    if ($text -match $pattern) { $result.State = 'waiting'; $result.Label = $matches[1].Trim(); return $result }
  }
  # (a detached job between its job file and its own place in the line: detached.ps1's ID.PID.session)
  foreach ($f in @(Get-ChildItem (Join-Path $root 'detached') -Filter '*.session' -File -ErrorAction SilentlyContinue))
  {
    if ($f.Name -notmatch '\.(\d+)\.session$' -or -not (Thread-Alive ([int]$matches[1]))) { continue }
    if ((Thread-Read $f.FullName) -eq "session $session") { $result.State = 'waiting'; $result.Label = 'a detached job'; return $result }
  }
  return $result
}

function Thread-Icon([string]$state) { switch ($state) { 'waiting' { return [string][char]0x23F3 } 'running' { return [string][char]0x2699 + [char]0xFE0F } default { return '' } } }

# What the thread's title should be, in words, for the messages.
function Title-Wanted([string]$state, [string]$title)
{
  $plain = if ($title) { "`"$title`"" } else { 'its title' }
  switch ($state)
  {
    'waiting' { return "`"$(Thread-Icon 'waiting') $(if ($title) { $title } else { 'TITLE' })`" (an hourglass before ${plain}: a job of this thread waits in the heavy queue)" }
    'running' { return "`"$(Thread-Icon 'running') $(if ($title) { $title } else { 'TITLE' })`" (a gear before ${plain}: a job of this thread holds the heavy slot)" }
    default { return "$plain with no icon (nothing of this thread's waits or runs in the heavy queue)" }
  }
}

# The steps a thread takes when its state changes; $heavy is the lock's heavy.cmd.
function Title-Steps([string]$state, [string]$title, [string]$heavy)
{
  $t = if ($title) { $title } else { 'TITLE' }
  $steps = "Set this thread's title to $(Title-Wanted $state $title) with rename_thread (the words after the icon unchanged), then check with list_threads that it shows; a rename can be acknowledged and not applied, so if it does not show, send_message to @parent asking the coordinator to set the title to exactly that. Without rename_thread (not a project thread), skip the title."
  if ($state -eq 'none') { $steps += " Then record it: ``$heavy --shown none --thread `"$t`"``." }
  else { $steps += " Then run ``$heavy --shown $state --thread `"$t`" --watch`` with run_in_background: it ends, and so wakes you, when the job's state changes again (it records what you showed)." }
  return $steps
}

# heavy.cmd --watch: records what the thread shows now and waits until its jobs' state differs from it.
function Watch-Session([string]$session, [string]$shown, [string]$title, [string]$heavy)
{
  $values = @{ shown = $shown; watcher = $PID }
  if ($title) { $values.title = $title }
  Save-Thread-Record $session $values
  $record = Thread-Record $session
  $title = "$($record.title)"
  $wake = $null
  try { $wake = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "$mutexName-changed") } catch { }
  try
  {
    while ($true)
    {
      $now = Session-State $session
      # (a look between two records of one job, or a job queued again at once, is no change: looked at again)
      if ($now.State -ne $shown -and $now.State -ne 'running') { Start-Sleep -Seconds 2; $now = Session-State $session }
      if ($now.State -ne $shown)
      {
        $what = if ($now.State -eq 'none') { "this thread's jobs in the heavy queue have ended" } else { "this thread's job is $($now.State) now ($($now.Label))" }
        "heavy: $what. $(Title-Steps $now.State $title $heavy)"
        return
      }
      if ($shown -eq 'none') { 'heavy: nothing of this thread''s waits or runs in the heavy queue: nothing to watch.'; return }
      # (the line's changes set this event; a job that died says nothing, so a look every 5 s anyway)
      if ($wake) { [void]$wake.WaitOne(5000) } else { Start-Sleep -Seconds 5 }
      $r = Thread-Record $session
      if ($r -and [int]$r.watcher -ne $PID -and (Thread-Alive ([int]$r.watcher))) { 'heavy: another watcher of this thread took over: this one ends.'; return }
    }
  }
  finally
  {
    $r = Thread-Record $session
    if ($r -and [int]$r.watcher -eq $PID) { Save-Thread-Record $session @{ watcher = 0 } }
  }
}
