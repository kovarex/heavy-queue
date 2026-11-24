# heavyboard

heavyboard is the board: one public page with every machine's heavy slot (the job running now, the queue
with estimates, the finished jobs) and the Open / Close / Close now buttons for the machines that take
them. It is a CGI program written in kpp. Each machine posts its status to it with a password.

- `GET index.cgi`: the page. Its script reads `?json` every 5 seconds and counts running times and ETAs
  in the browser, in the viewer's own time zone.
- `GET index.cgi?json`: every machine, whether it is open, and the status it last posted.
- `POST index.cgi?update&machine=NAME`: a machine's new status, a JSON object, with the header
  `X-Heavy-Password` (403 wrong password, 503 none set, 400 not a JSON object or no machine, 413 over
  1 MB, 204 stored).
- `GET index.cgi?state&machine=NAME`: what a machine's gate asks: `open`, `closed` or `stopped`.
- `POST index.cgi?open=1|0|hard&machine=NAME`: the buttons, with the control password (5 wrong ones in
  10 minutes lock the buttons for 10 minutes).
- `POST index.cgi?page`: a new page (HTML) with the posting password, so the page can change without a
  new program.

## Data

The data directory is `/home/protected/heavyboard`, or `HEAVYBOARD_DATA` when set; the web must not be
able to read it. It holds:
- `password`: the machines' posting password (first line).
- `control-password`: the buttons' password (first line).
- `always-open`: machines that are open unless closed and get no buttons, one name a line. Any other
  machine is closed until opened on the page.
- `status-NAME.json`, `seen-NAME`, `open-NAME`: each machine's status, when its gate last asked, and its
  button state.

## Building and testing

- `kpp --test` here runs the handler's tests.
- `kpp debug` builds a local version: `build\debug\heavyboard.exe` serves at http://127.0.0.1:8765/
  (set `HEAVYBOARD_DATA` to a test folder).
- `kpp --release --target freebsd heavyboard` builds the program for a FreeBSD host. Add
  `--sysroot DIR` when the kpp you use has no FreeBSD sysroot of its own.

## Install

Upload a folder with index.cgi (the FreeBSD build), .htaccess, password, and optionally
control-password and always-open, and run `sh install.sh` in it on the host (install.sh says where
things go). Later program updates: deploy\upload.cmd.
