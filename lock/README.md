# The lock

    lock\heavy.cmd [--exclusive] [--name TEXT] [--estimate 90s, 10m or 2h] [--travel] COMMAND LINE...
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

A waiting job may run on another machine, a worker, while it waits here (every job but an `--exclusive`
one unless `travelExclusive`, and none unless `--travel` when `travelByDefault` is false; never with
`--local`). Its folders travel with it: the git checkout or folder it runs in, and the folders its command
line names and the scripts it names name (a path under one of `travelFolderRoots` stands for its first-level
folder there, such as one thread's scratch folder; paths under `samePaths` are the same on every machine and
stay). The worker keeps its own copy of each folder at the same path; once it claims the job it says what
its copies hold, this machine sends what differs and what to delete through the exchange folder both see
(`travelExchange`, a NAS share), build outputs and uncommitted files included, and a checkout's git state
by git (from a mirror of the remote the worker keeps, the commits no remote has as a bundle, HEAD and the
index at this machine's). So the first job from a folder moves all of it and the next ones little. The
worker runs the command in the same folder. Its output comes back to heavy.cmd as it is written; when it
ends, every file it made, changed or deleted in those folders comes back the same way, then its exit code,
with a line saying where it ran. For whoever started it, the job ran here.

- **Which jobs:** any job whose folders are not whole drives or their first-level folders (too wide) and
  hold at most `travelMaxFiles` files each. A path the job uses that neither its command line nor the
  scripts it names show is not seen: such a folder does not travel. The pages say why a job stays
  ("stays here: ...") or that it may travel.
- **Which worker:** an open worker whose slot is free and that has nothing queued claims the oldest job it
  may run: the same tools (the offer names its `fingerprint` commands and their output here; the worker runs
  the same commands, again right before it claims), and no `--exclusive` job on a no-benchmarks machine.
  Whoever claims first runs the job, this machine included (a claim is a file made with CreateNew).
- **What it takes along:** the command line, the folder, the label, the thread, the estimate and the
  environment, without what names this machine (COMPUTERNAME, TEMP, ...) and without secrets (any variable
  whose name has TOKEN, SECRET, PASSWORD, KEY, AUTH, CREDENTIAL, ...): a worker keeps its own.
- **Tools that come along:** folders in `travelTools` (such as `C:\Program Files\kpp`, installed from an
  unreleased build) are copied into the exchange once per version; a worker mirrors the home's version into
  its own copy (`ROOT\tools`, never the folder itself, which its own programs use) and runs the job and its
  fingerprint with that copy in place of the folder.
- **When it cannot go:** more than `travelLimitMB` (2000) differing between its folders and the worker's
  copies, or a worker that cannot make the checkout (its remote out of reach): the job runs here after all, in its place in the line, and says so.
- **When something dies:** a worker that stops answering for `travelStale` seconds (90) ends the job here
  with `heavy: STOPPED: ... Run it again.` and exit 1; its lock and everything the job started are in a job
  object that ends with the lock, so nothing keeps running there. A waiter here that goes away makes the
  worker stop the job.
- **Files:** `EXCHANGE\ID.*` (lock\travel.ps1 lists them); a worker's copies are at the homes' paths
  (`ROOT\copies.txt` lists them), a folder of its own in the way renamed aside, never deleted. The worker writes its note (what it does, or why
  it takes nothing, such as other tools) to its `ROOT\worker.txt`, which its pages and the board show.

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
| travelExchange | the folder every machine sees (a NAS share) through which jobs travel | none (nothing travels) |
| samePaths | paths that are the same on every machine, which a travelling job may name | Program Files, Windows |
| fingerprint | commands whose output must be the same on two machines for one to run the other's jobs | none |
| travelLimitMB | the most that may differ between a travelling job's folders and the worker's copies | 2000 |
| travelMaxFiles | a job with a folder holding more files stays here | 300000 |
| travelFolderRoots | folders whose first-level folders are the unit that travels (such as a scratch folder of per-thread folders) | none |
| travelExclusive | `--exclusive` jobs (timing runs) travel too, without `--travel`: for machines of the same hardware | false |
| travelByDefault | jobs travel without `--travel`; false offers only `--travel` jobs, for homes whose jobs use build outputs git ignores (those do not travel: the worker's checkout is clean) | true |
| travelTools | folders a worker takes from its home when its own differ, mirrored at the same path (such as a compiler installed from an unreleased build); setup-worker.ps1 -Tools gives the worker's user those folders | none |
| travelCheckouts | on a worker, for testing two machines on one computer: where its checkouts go instead of the homes' paths | none |
| travelStale | seconds without a heartbeat before the other side of a travelled job counts as gone | 90 |
