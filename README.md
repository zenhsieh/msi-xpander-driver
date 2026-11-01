# MSI Xpander driver for macOS and Linux (Rust)

Open-source MSI Xpander driver for macOS and Linux: a USB display with extended desktop, secondary display, and kiosk modes.
MSI Xpander 在 Windows 以外（macOS、Linux）的開源驅動。

It targets the 12.4" 1920×720 companion display. The macOS desktop bridge
and kiosk mode can show desktop frames or any PNG.

Not affiliated with or endorsed by MSI. This is a research prototype built from
USB captures of the official software; see `docs/research-notes.txt` for the
exact validation status of each path.

## What works

| Path | Status |
|---|---|
| HID mode switch + RSA vendor handshake | confirmed on macOS and Windows |
| Dashboard mode (vendor HID, 1440×540 baseline JPEG 4:2:0) | confirmed, physical output verified |
| macOS extended desktop (`desktop`, ScreenCaptureKit bridge) | Dashboard HID remains the default/fallback; opt-in bulk desktop confirmed on the panel 2026-10-31 at 30/60 fps ceilings, with visibly smoother cursor motion ([evidence](docs/evidence/2026-10-31-desktop-bulk.md)) |
| Extended-mode bulk streaming (`show420`, `show-prime420`) | confirmed on the panel 2026-10-31 (`docs/evidence/2026-10-31-mac-bulk-works.md`); desktop transport now selectable with `MSI_DESKTOP_TRANSPORT` |
| Kiosk mode (`kiosk frame.png`, any PNG source) | HID default/fallback; `MSI_KIOSK_TRANSPORT=bulk` shares the extended-mode endpoint with bulk desktop, allowing content-producer switches without a physical replug; see `kiosk/README.md` |

## macOS menu-bar app and hardware JPEG

The **顯示** submenu offers remote Kiosk, extended desktop, a real macOS widgets
desktop, a native clock screensaver, and screen Off (black frame). Manual choices
control only Xpander. Screen saver and screen/system sleep/wake events on the Mac
automatically override and then restore the selected panel mode. A manually
selected Off stays off after wake. Widget mode is interactive macOS desktop,
not an AppKit picture of widgets; add widgets through macOS's Edit Widgets UI.
See [installation, modes and packaging](macos/MENU-BAR.md).

The Mac app uses bulk USB and verified VideoToolbox hardware JPEG. The older
command-line HID default remains for compatibility. Capture activity and USB
transfer time affect achieved update frequency: the selected setting is a ceiling.
The physical MSI monitor can briefly blank when activating certain virtual
modes; see [issue #1](https://github.com/zenhsieh/msi-xpander-driver/issues/1).
No preallocated/retained hidden output or HDR-setting rewrite is used as a fix.

## Switch between kiosk and desktop without a USB replug

Use bulk for both producers and stop the current producer before starting the
other. For example (the kiosk PNG must already exist):

```sh
MSI_KIOSK_TRANSPORT=bulk MSI_KIOSK_JPEG_QUALITY=100 cargo run --release --features hardware -- kiosk kiosk/frame.png
# Stop with Ctrl-C, then start the desktop:
MSI_DESKTOP_TRANSPORT=bulk MSI_DESKTOP_FPS=60 bash Run-Desktop.command
# Stop with Ctrl-C, then restart the bulk kiosk command above.
```

Once the panel is already in extended mode (`0db0:7885`), each producer only opens
and authenticates that bulk session. It does not request Dashboard mode, replay
Dashboard priming or reset/re-enumerate the USB device. The panel may retain the
last picture while no producer runs. Initial startup from Dashboard mode uses
the captured unprimed forward mode switch, without sending the bundled startup
JPEG. The explicit `show-prime420` diagnostic retains its priming procedure.
Do not run both producers concurrently.

Kiosk's transport defaults to HID unless `MSI_KIOSK_TRANSPORT=bulk` is supplied;
its 250 ms PNG polling and 5-second static-image resend remain unchanged. An
existing HID-only background kiosk must be stopped before testing bulk desktop.
This feature switches the image producer while keeping the firmware in the same
mode; a reverse extended-to-Dashboard firmware command has not been established.

Bulk kiosk sends the PNG at native 1920×720 as baseline JPEG 4:2:0. Set
`MSI_KIOSK_JPEG_QUALITY` from 1 to 100 to tune its JPEG detail/size; the default is
85, preserving previous kiosk output. This quality setting belongs to kiosk's
existing Rust encoder. It is independent of the desktop bridge's VideoToolbox
encoder/quality controls. To select hardware JPEG for kiosk frames, use
`MSI_KIOSK_ENCODER=vt` and `MSI_VT_QUALITY=1.0`; the menu-bar app configures this
automatically. See `kiosk/README.md` for the helper path.

## Build

```sh
cargo test                                  # offline: fixtures, handshake, JPEG headers
cargo test --features hardware              # compiles USB code, still no device access
cargo build --release --features hardware   # hidapi + rusb; needs libusb on Linux
```

`cargo run -- verify` replays the captured fixtures without touching USB.

## Run

Connect the panel, unplug/replug once so it starts in Dashboard mode, then:

```sh
cargo run --release --features hardware -- dashboard      # colour bars / gray ramp / checkerboard
cargo run --release --features hardware -- show420        # extended-mode stream (experimental)
cargo run --release --features hardware -- desktop        # macOS: extra display, see macos/
MSI_DESKTOP_TRANSPORT=bulk MSI_DESKTOP_FPS=30 bash Run-Desktop.command
MSI_DESKTOP_TRANSPORT=bulk MSI_DESKTOP_FPS=60 bash Run-Desktop.command
cargo run --release --features hardware -- kiosk frame.png
```

`Run-Mac-Test.command`, `Run-Desktop.command` and `Run-Kiosk.command` wrap the
common macOS flows and log to a timestamped file next to the project.

## Kiosk example: token meter

`kiosk/examples/token_meter_frame.py` reads only a JSON summary file and writes
a 1920×720 PNG to stdout. It shows today's and this month's token usage plus
each session's last context size. Copy the sample data before trying it:

```sh
cp kiosk/examples/summary.example.json summary.json
python3 kiosk/run_kiosk.py --frame-cmd 'python3 kiosk/examples/token_meter_frame.py --summary summary.json' --once
```

Remove `--once` to feed the panel continuously. The frame generator uses Pillow
when available and otherwise writes the PNG with the Python standard library.

## Layout

```
src/            driver, JPEG 4:2:0 encoder, desktop frame pipeline, CLI
tests/          handshake replay against captured fixtures
fixtures/       control frames, public RSA proof, Dashboard HID reports, JPEG headers
assets/         vendor public key, a generic Dashboard capture used for priming
macos/          ScreenCaptureKit bridge app (Objective-C) and build script
kiosk/          PNG-fed status screen supervisor
docs/           research notes and validation history
```

No USB serial numbers or private images are included. `assets/vendor-public.pem`
is the vendor's public key as shipped in the official software.

## License

Apache License 2.0 — see `LICENSE` and `NOTICE`.
