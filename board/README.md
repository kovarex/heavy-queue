# heavyboard

heavyboard is the board: one public page with every machine's heavy slot (the job running now, the queue
with estimates and ETAs, the finished jobs) and Open / Close / Close now buttons for the machines that are
controlled from it. It is a CGI program written in kpp. Each machine posts its status to it with a
password.

- `GET index.cgi`: the page. Its script reads `?json` every 5 seconds and counts running times and ETAs
  in the browser, in the viewer's own time zone.
- `GET index.cgi?json`: every machine (whether it is open, the status it last posted) and the names of
  the other pages.
- `POST index.cgi?update&machine=NAME`: a machine's new status, a JSON object (403 wrong password, 503
  none set, 400 not a JSON object or no machine, 413 over 1 MB, 204 stored).
- `GET index.cgi?state&machine=NAME`: what a machine's gate (machine\machine-gate.ps1) asks: `open`,
  `closed` or `stopped`. Asking makes the machine gated.
- `POST index.cgi?open=1|0|hard&machine=NAME`: the buttons, with the control password (5 wrong ones in
  10 minutes lock the buttons for 10 minutes).
- `POST index.cgi?page`: a new main page (HTML), so the page can change without a new program
  (deploy\post-page.ps1).
- `GET` / `POST index.cgi?page=NAME`: another page (HTML), linked from the main page.
- `GET` / `POST index.cgi?doc=NAME`: a JSON document (an object or an array, up to 16 MB), for such a
  page's script to read. A page and its data, such as a benchmarks history, live on the board this way
  without being part of its code.

Every POST except the buttons' takes the posting password in the header `X-Heavy-Password`. A POST the
board does not know is refused (400).

**Gated machines:** a machine whose gate asks for its state is opened and closed on the page: it is closed
until opened, and its card has the buttons. A machine without a gate only posts its status; the board
cannot hold it, so it shows as open, without buttons (its own hold file decides, and a hold shows on its
card).

## Data

The data directory is `/home/protected/heavyboard`, or `HEAVYBOARD_DATA` when set; the web must not be
able to read it. It holds:
- `password`: the machines' posting password (first line).
- `control-password`: the buttons' password (first line).
- `status-NAME.json`, `seen-NAME`, `open-NAME`: each machine's status, when its gate last asked, and its
  button state.
- `page.html`, `page-NAME.html`, `doc-NAME.json`: the posted pages and documents.

## Building and testing

- `kpp --test` here runs the handler's tests.
- `kpp debug` builds a local version: `build\debug\heavyboard.exe` serves at http://127.0.0.1:8765/
  (set `HEAVYBOARD_DATA` to a test folder).
- `kpp --release --target freebsd heavyboard` builds the program for a FreeBSD host (`--sysroot DIR`
  when the kpp you use has no FreeBSD sysroot of its own). A release build splits its debug information
  out with llvm-objcopy, which must be on PATH (Visual Studio's is in VC\Tools\Llvm\x64\bin).

## Install

Upload a folder with index.cgi (the FreeBSD build), .htaccess, password and, optionally,
control-password, and run `sh install.sh` in it on the host (install.sh says where things go). Later
program updates: deploy\upload.cmd.
