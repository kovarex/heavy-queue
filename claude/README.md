# Claude Code threads

A Claude Code thread's title shows what its heavy jobs do: `⏳ TITLE` while one waits in the line, `⚙️ TITLE`
while one holds the slot (or runs on a worker), plain `TITLE` when it has none. Nothing here renames a thread:
only the thread (or its coordinator) can. What heavy-queue does is make sure the thread is woken and told, at
the moment its job's state changes, and that no thread ends a turn with a title or a watch that is out of date.

- **Every job knows its session:** a job's records carry `, session ID`: `HEAVY_QUEUE_SESSION` when set, else
  the Claude desktop app's `CLAUDE_CODE_HOST_SESSION_ID`, which every command a session runs inherits (a
  detached job keeps it). lock\threads.ps1 reads a session's state from the holder, the line, the jobs running
  on a worker (`ROOT\elsewhere\PID.txt`) and the detached jobs starting (`ROOT\detached\ID.PID.session`).
- **What a thread shows:** `ROOT\threads\SESSION.json`: its plain title (the pages and the history show it
  instead of the app's session title, which stays the one it started with), the state its title shows, and its
  watcher's pid.
- **`heavy.cmd --thread "TITLE"`** records the plain title (an icon in front is dropped); before a command line,
  it records it and the job runs as usual.
- **`heavy.cmd --shown STATE`** (none, waiting, running) records what the title shows now.
- **`heavy.cmd --shown STATE --watch`** records it and waits until the session's state differs from it, then
  prints what to do (the title wanted, and the next watch) and ends. Run with run_in_background, its end
  wakes the thread: the job's start and end reach it within seconds, whether its turn is running or not. It
  ends at once when nothing waits or runs (`--shown none`), and when a newer watcher of the same thread
  replaces it.
- **The Stop hook (stop-hook.ps1)** runs at the end of every turn of every session. When the session's jobs
  wait or run and its record says otherwise, or nobody watches them, or they ended and the title still shows
  an icon, it keeps the turn going once (`decision: block`) with the exact steps: rename, check with
  list_threads, ask the coordinator (`send_message` to `@parent`) when a rename did not apply, then record or
  watch. So no thread has to remember the rule: queueing a job in a turn is enough. A hook that fails, or a
  turn it already kept going once (`stop_hook_active`), ends normally. A session with nothing in the line and
  nothing recorded costs one look at the queue folder (about 0.3 s of PowerShell).

## Install

In the user's `%USERPROFILE%\.claude\settings.json`, beside any other Stop hooks:

```json
"hooks": {
  "Stop": [
    { "hooks": [ { "type": "command", "timeout": 30,
      "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\heavy-queue\\claude\\stop-hook.ps1\"" } ] }
  ]
}
```

## Limits

- A session the app has stopped (an hour without a turn) runs no hook and no watcher: its title shows what it
  last recorded until its next turn, whose end the hook checks. A thread that waits on a long job keeps a
  check-in every 30 minutes or less, which keeps it running.
- A job run in the foreground of a turn (heavy.cmd waiting inside one tool call) is not shown while that
  call lasts: the hook looks only at a turn's end.
