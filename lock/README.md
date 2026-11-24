# The lock

    lock\heavy.cmd [--exclusive] [--name TEXT] [--estimate 90s, 10m or 2h] COMMAND LINE...
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
- **Only this machine:** a job runs where it was started, with that machine's files. The lock never
  moves a job to another machine; another machine takes work when something is started there.

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
