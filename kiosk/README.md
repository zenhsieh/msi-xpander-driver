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

- `MSI_KIOSK_TRANSPORT=bulk` sends native 1920×720 JPEGs over the extended-mode
  endpoint; the default remains `hid`. `MSI_KIOSK_JPEG_QUALITY` accepts 1–100
  (default 85); this setting controls the default Rust software encoder.
- `MSI_KIOSK_ENCODER=vt` selects native hardware JPEG for each PNG update without
  a virtual display or screen capture. Build `bash macos/build-vt-image-encoder.sh`
  and set `MSI_KIOSK_VT_HELPER` to the resulting `target/VTImageEncoder` path (or
  install it at `~/Library/Application Support/digiter-xpander-kiosk/VTImageEncoder`).
  `MSI_VT_QUALITY` controls VT quality, from 0 to 1 (default 0.75); use 1.0 for the
  highest JPEG quality on a low-frequency dashboard. `MSI_KIOSK_ENCODER=raw`
  restores software encoding. Desktop's `MSI_BRIDGE_ENCODER` is independent.
- The VT helper decodes the PNG into a local pixel buffer, verifies the actual
  hardware encoder ID and uses an explicit JPEG BT.601 color matrix. Rust checks
  every returned JPEG's dimensions, baseline format and `22 11 11` sampling before
  USB transmission. Each helper invocation has a 10-second deadline; failures
  retain the last panel image and retry rather than sending unchecked output.
- Frames are fetched on a background thread, targeting `--interval` seconds
  (default 5); a slow frame command simply lowers the refresh rate.
- The panel itself is republished every second, independent of fetching. The
  footer shows receipt time; after 20 s without a new frame a stale banner is
  drawn over the last known image, and fetch failures are shown immediately.
- The footer reads `RECEIVED hh:mm:ss · Ns ago`, the age ticking every second.
- `--clock` (or `KIOSK_CLOCK=1`) draws a live `<date> <time>` clock top-right.
  Have the frame command leave that 56 px corner empty.
- On USB failure the sender reopens the selected transport and resends the latest
  file. HID primes the panel; bulk reauthenticates without replaying a Dashboard
  startup image. Static images are resent every 5 s as a reconnect check.
- `kiosk/kiosk.env` (git-ignored) is sourced by `Run-Kiosk.command` if present,
  so the frame command and target dir can live outside the repo.

Requires Pillow on the machine running `run_kiosk.py`.
