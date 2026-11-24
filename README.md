# heavy-queue

One heavy job at a time per machine, with a time estimate for every job, and a public board that shows
every machine's queue.

- `lock/`: `heavy.cmd [--exclusive] [--name TEXT] [--estimate 10m] COMMAND LINE...` runs a command while
  holding the machine's one heavy slot, in arrival order. `--exclusive` (benchmarks, timing runs) also
  waits until the machine is otherwise idle. It writes status.html, status.md and status.json into its
  data folder whenever a job queues, starts or finishes, and history.tsv when one ends. lock\README.md.
- `board/`: heavyboard, the CGI program (written in kpp) that shows all machines on one page, with
  Open / Close / Close now buttons. board\README.md.
- `machine/`: what runs on each machine besides the lock: publish.ps1 (posts the status to the board),
  machine-gate.ps1 (opens and closes the machine from the board) and setup-machine.ps1 (sets a computer
  up).
- `deploy/`: uploading a new board program to its host.

Windows machines (PowerShell 5.1); the board runs as a CGI program on a FreeBSD web host.

## Setting up

- **A machine:** clone this repository on it, copy config.example.json to config.json and set the data
  folder and the rest (or leave it out for the defaults), then run
  `machine\setup-machine.ps1 -PublishFile PATH` with a publish.txt (machine\publish.example.txt).
- **The board:** board\README.md, Install.

## Secrets

None are in this repository, and .gitignore keeps them out: the posting password (publish.txt on each
machine, `password` on the host), the buttons' password (`control-password`), the host's SSH login
(deploy\site.txt) and each machine's config.json.
