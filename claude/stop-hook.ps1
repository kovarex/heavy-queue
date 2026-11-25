# heavy-queue's Claude Code Stop hook: a thread whose title does not show what its heavy jobs do, or whose jobs
# wait or run with nobody watching them, is not let end its turn until it has seen to it (lock\threads.ps1).
# claude\README.md says how to install it.
#
# It reads the hook's input (JSON on stdin), and does nothing when the session has no id
# (CLAUDE_CODE_HOST_SESSION_ID or HEAVY_QUEUE_SESSION), when it already stopped a turn's end once
# (stop_hook_active: never a loop), or when the thread's record says what its jobs do and, while they wait or
# run, its watcher (heavy.cmd --watch) is alive. Else it answers {"decision": "block", "reason": STEPS}.
$ErrorActionPreference = 'Stop'
try
{
  $inputText = [Console]::In.ReadToEnd()
  $hook = $null
  try { $hook = $inputText | ConvertFrom-Json } catch { }
  if ($hook -and $hook.stop_hook_active) { exit 0 }
  $lock = Join-Path (Split-Path $PSScriptRoot) 'lock'
  . (Join-Path $lock 'config.ps1')
  . (Join-Path $lock 'threads.ps1')
  $session = Job-Session
  if (-not $session) { exit 0 }
  $record = Thread-Record $session
  $now = Session-State $session
  if (-not $record -and $now.State -eq 'none') { exit 0 }
  $shown = if ($record -and $record.shown) { "$($record.shown)" } else { 'none' }
  $title = if ($record) { "$($record.title)" } else { '' }
  $watched = $record -and (Thread-Alive ([int]$record.watcher))
  if ($now.State -eq $shown -and ($shown -eq 'none' -or $watched)) { exit 0 }
  $heavy = if ($env:HEAVY_QUEUE_CALLED_AS) { $env:HEAVY_QUEUE_CALLED_AS } else { Join-Path $lock 'heavy.cmd' }
  $what = switch ($now.State) { 'waiting' { "A heavy job of this thread waits in the heavy queue ($($now.Label))." } 'running' { "A heavy job of this thread holds the heavy slot ($($now.Label))." } default { "This thread's heavy jobs have ended, and its title was last recorded as showing '$shown'." } }
  if ($now.State -eq $shown) { $reason = "$what Nobody watches it: run ``$heavy --shown $shown --thread `"$(if ($title) { $title } else { 'TITLE' })`" --watch`` with run_in_background, so that its start or end wakes you; if the title does not show it yet, set it first: $(Title-Wanted $shown $title)." }
  else { $reason = "$what $(Title-Steps $now.State $title $heavy)" }
  if (-not $title) { $reason += " (TITLE: this thread's title without an icon; --thread records it for the heavy queue's pages too.)" }
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  [Console]::Out.Write((@{ decision = 'block'; reason = "heavy queue: $reason" } | ConvertTo-Json -Compress))
  exit 0
}
catch { exit 0 } # (a hook that fails never keeps a turn from ending)
