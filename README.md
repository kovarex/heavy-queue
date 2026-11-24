# heavy-queue

One heavy job at a time per machine, a time estimate for every job, waiting jobs that travel to an idle
machine, and a public board that shows every machine's queue.

- `lock/`: `heavy.cmd [--exclusive] [--name TEXT] [--estimate 10m] [--local | --travel] COMMAND LINE...`
  runs a command while holding the machine's one heavy slot, in arrival order. `--exclusive` (benchmarks,
  timing runs) also waits until the machine is otherwise idle. A waiting job may run on an idle worker
  instead, in the same folder, with its output and exit code coming back. It writes status.html,
  status.md and status.json into its data folder whenever a job queues, starts or finishes, and
  history.tsv when one ends. lock\README.md.
- `board/`: heavyboard, the CGI program (written in kpp) that shows all machines on one page, with
  Open / Close / Close now buttons for the machines whose gate asks it. board\README.md.
- `machine/`: what runs on each machine besides the lock: publish.ps1 (posts the status to the board),
  machine-gate.ps1 (opens and closes the machine from the board), worker.ps1 (runs another machine's
  jobs), and the setups: setup-machine.ps1, share-home.ps1 (a machine whose jobs travel) and
  setup-worker.ps1 (a machine that runs them).
- `deploy/`: uploading a new board program, or a page, to its host.

Windows machines (PowerShell 5.1); the board runs as a CGI program on a FreeBSD web host.

## Setting up

- **A machine:** clone this repository on it, copy config.example.json to config.json and set what
  differs from the defaults (lock\README.md lists them), then run
  `machine\setup-machine.ps1 -PublishFile PATH` with a publish.txt (machine\publish.example.txt).
- **Jobs that travel:** on the machine whose jobs travel, set `travelRoots` (and `fingerprint`) in
  config.json and run machine\share-home.ps1 as administrator; on each worker, run
  machine\setup-worker.ps1 as administrator (it runs setup-machine.ps1 too).
- **The board:** board\README.md, Install.

## Secrets

None are in this repository, and .gitignore keeps them out: the posting password (publish.txt on each
machine, `password` on the host), the buttons' password (`control-password`), the host's SSH login
(deploy\site.txt) and each machine's config.json. A travelling job's environment leaves its secrets at
home.
