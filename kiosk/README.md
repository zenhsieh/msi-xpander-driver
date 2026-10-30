# Kiosk mode

`run_kiosk.py` turns the Xpander into a status screen for *anything* that can
produce a 1920×720 PNG. It runs a frame command on an interval, writes the result
atomically to `frame.png`, and keeps `msi-xpander kiosk frame.png` (the direct
USB sender) fed. No virtual display, desktop capture, or display-setting change.

```sh
# one-off preview, no USB access
python3 kiosk/run_kiosk.py --frame-cmd "ssh myhost render-dashboard" --once

# run for real (builds the hardware feature first)
export KIOSK_FRAME_CMD="ssh myhost render-dashboard"
./Run-Kiosk.command
```

The frame command is any shell command that writes PNG bytes to stdout. The
reference setup renders a fleet dashboard on a server and ships only the image
over an existing SSH connection, so the machine driving the panel holds no
credentials beyond that SSH key. A local script that paints a clock works just as
well.

Behaviour:

- Frames are fetched sequentially, targeting `--interval` seconds (default 5);
  a slow frame command simply lowers the refresh rate.
- The footer shows receipt time; after 20 s without a new frame a stale banner is
  drawn over the last known image, and fetch failures are shown immediately.
- On USB failure the sender reopens and primes the panel, then resends the latest
  file. Static images are resent every 5 s as a reconnect check.
- `kiosk/kiosk.env` (git-ignored) is sourced by `Run-Kiosk.command` if present,
  so the frame command and target dir can live outside the repo.

Requires Pillow on the machine running `run_kiosk.py`.
