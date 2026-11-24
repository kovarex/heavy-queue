# The lock

    lock\heavy.cmd [--exclusive] [--name TEXT] [--estimate 90s, 10m or 2h] COMMAND LINE...
    lock\heavy.cmd --detach [--log FILE] [the same options] COMMAND LINE...
    lock\heavy.cmd --status

- **One heavy job at a time:** the command runs while it holds the machine's one heavy slot. Builds,
  test runs, links and anything else that loads the whole machine go through it.
- **Benchmarks and timing runs:** `--exclusive` takes the same slot, then waits until total CPU stays
  under `idleLoad` percent for `idleSeconds`, and holds the quiet flag while it runs.
- **Waiting:** waiters queue in arrival order. A waiter prints one line to stderr naming the holder,
  then a new line only when the reason changes. Nothing needs polling: the command starts once the slot is
  free.
- **Holder dies:** the slot is a named mutex, so Windows frees it when the holding process dies. A
  killed job never leaves the machine locked, and a dead waiter's queue file is dropped.
- **Nested scripts:** the command runs with `HEAVY_QUEUE_HELD` set (and the config's `heldVariable`), so
  scripts it calls that take the lock themselves run at once instead of waiting for their own parent.
- **Holds:** while the hold file's first line is not `HOLD: no`, or the quiet flag exists and its holder
  is alive, no job starts. The status pages say so. machine\machine-gate.ps1 writes the hold file from
  the board's Open and Close buttons; anything else may write it too.
- **Stopped from outside:** a job whose `ROOT\stopped-PID.txt` appears (the board's "Close now") ends with
  `heavy: STOPPED: REASON Run it again.` and a nonzero exit code.
- **No benchmarks here:** with `ROOT\no-benchmarks`, an `--exclusive` job is refused at once (exit 2).
- **CI:** with `CI` or `GITHUB_ACTIONS` set, the command runs straight away.
- **Exit code:** the command's.

## Detached jobs

`--detach` returns at once and the job (its wait included) runs in a process of its own, outside the
caller's process tree: whatever ends the caller leaves it running. The Claude desktop app, for one, stops
a Claude Code session an hour after its last turn and ends every process the session started, a
`heavy.cmd` waiting in the background included (2026-11-24).

- **Output:** in `--log FILE` (relative to the folder), else `ROOT\detached\ID.log`; heavy.cmd prints
  which. The log starts with a line naming the job and ends with `heavy: detached job ended ... with exit
  code N.`; `FILE.exit` appears then, holding the exit code. A new job with the same log empties it and
  removes the old `.exit` first.
- **The same job:** queued, run and shown on the pages as any other, with the caller's folder and
  environment (without secrets, as for travelling jobs: a variable whose name has TOKEN, SECRET,
  PASSWORD, ... stays out) and the thread title.
- **How:** WMI starts lock\detached.ps1 (Win32_Process.Create), so its parent is WMI's service and it is
  in no job object of the caller's. The job file it reads (`ROOT\detached\ID.json`) is removed once read.
- **Not inside a heavy job:** `--detach` there is refused (exit 2), as the job would run without the slot
  once its parent ended.

## Jobs that travel

A waiting job may run on another machine, a worker, in the same folder: the worker sees this machine's
folders at the same paths (machine\share-home.ps1 shares them here, machine\setup-worker.ps1 maps them
there), so the job sees the same files, git included, and nothing is copied. For whoever started it, the
job ran as before: its output comes back to heavy.cmd as it is written, then its exit code, with a line
saying where it ran.

- **Which jobs:** a job travels when its folder and every path in its command line are in `travelRoots`
  (or `samePaths`, the same on every machine). `--local` keeps a job here. An `--exclusive` job (a timing
  run) travels only with `--travel`, as its numbers would come from another machine. The pages say why a
  waiting job stays ("stays here: ...") or that it may travel.
- **Which worker:** an open worker whose slot is free and that has nothing queued claims the oldest job it
  may run: same tools (the `fingerprint` commands' output, checked again right before it claims), no
  `--exclusive` job on a no-benchmarks machine, and no job running anywhere in the same folder (or one
  inside the other) or for the same thread. A thread's jobs ran one after another here; they still do,
  wherever they run. Whoever claims first runs the job, this machine included (a claim is a file made with
  CreateNew).
- **What it takes along:** the command line, the folder, the label, the thread, the estimate and the
  environment, without what names this machine (COMPUTERNAME, TEMP, ...) and without secrets (any variable
  whose name has TOKEN, SECRET, PASSWORD, KEY, AUTH, CREDENTIAL, ...): a worker keeps its own.
- **When something dies:** a worker that stops answering for `travelStale` seconds (90) ends the job here
  with `heavy: STOPPED: ... Run it again.` and exit 1; its lock and everything the job started are in a job
  object that ends with the lock, so nothing keeps running in the shared folder. A waiter here that goes
  away makes the worker stop the job.
- **Files:** `ROOT\travel\ID.*` (lock\travel.ps1 lists them). The worker writes its note (what it does, or
  why it takes nothing, such as other tools) to its `ROOT\worker.txt`, which its pages and the board show.

## Who started a job

The pages' thread column: `HEAVY_QUEUE_THREAD` when set; else, for a job started from a Claude Code
session of the Claude desktop app, that session's title; else the job's folder.

## Estimates

Every job gets a time estimate: what it gave with `--estimate`; else the median of the last 5 successful
runs with the same name; else of the same thread's last 5; else of the same kind's. A name is the label's
(`--name`, else the command line's) first three words in lower case, a path among them cut to its last two
parts and every number counted alike. The basis is shown next to each estimate (given, name, thread or
kind), and each waiting job shows when it should run, counted from the running job's estimate. Holds and
an exclusive job's wait for an idle machine are not foreseen. history.tsv's ninth column keeps the
estimate a job had when it started, and the finished table shows it beside the time the job took.

## Status

The lock writes `ROOT\status.html` (reloads every 5 seconds), `status.md` and `status.json` whenever a job
queues, starts or finishes, and `--status` writes them too. Each shows the running job, the queue, the
finished jobs and any hold. `history.tsv` gets one line per finished job: queued, started, finished, exit
code, kind, folder, label, thread, estimate. With `ROOT\publish.txt` (the board's address and posting
password), machine\publish.ps1 posts status.json to the board after every change.

## Config

`config.json` in the repository's root (kept out of git; `HEAVY_QUEUE_CONFIG` names another file). See
config.example.json. A config that is not valid JSON stops every script with an error. Every setting has a
default:

| setting | what | default |
|---|---|---|
| root | the data folder | `%ProgramData%\heavy-queue` |
| machine | the machine's name on the board | the computer's name |
| holdFile | its line 1 `HOLD: no` lets jobs start | `ROOT\hold.txt` |
| quietFlag | the flag `--exclusive` holds, and every job waits for | `ROOT\quiet.flag` |
| mutex | the slot's name (the publisher and the gate add `-publish`, `-machine-gate`) | `Global\heavy-queue` |
| heldVariable | one more variable set for the command, for scripts that check their own | none |
| title | the status page's heading | `MACHINE heavy slot` |
| idleLoad | `--exclusive`: idle below this total CPU percent | 15 |
| idleSeconds | `--exclusive`: for this many seconds in a row | 20 |
| computer | the computer this config belongs to: the lock refuses to run on another with it | none |
| travelRoots | this machine's folders that workers see at the same paths: jobs in them may travel | none (nothing travels) |
| samePaths | paths that are the same on every machine, which a travelling job may name | Program Files, Windows |
| fingerprint | commands whose output must be the same on two machines for one to run the other's jobs | none |
| home | on a worker: its home's data folder, as the worker sees it | none (not a worker) |
| travelStale | seconds without a heartbeat before the other side of a travelled job counts as gone | 90 |
