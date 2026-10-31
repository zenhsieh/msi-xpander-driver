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
| Kiosk mode (`kiosk frame.png`, any PNG source) | works; see `kiosk/README.md` |

## Why the cursor is not as smooth as on Windows

The current macOS desktop path captures and encodes each full frame as JPEG,
then sends it over the Dashboard HID channel. A typical frame is about 100 KB:
roughly 100 HID reports of 1000 bytes each. Each frame must be sent again when
the picture changes, so cursor motion can lag or look less fluid. The official
Windows software also sends full JPEG frames (about 100–200 KB each, no separate
cursor channel; see `docs/evidence/2026-10-31-windows-mouse-capture.md`), but over
the extended mode's bulk endpoint at a steady rate. This project now offers
paced bulk desktop sending as an option; capture/encode cost and physical cursor
smoothness still need to be compared at 30 and 60 fps.

Select `MSI_DESKTOP_TRANSPORT=bulk` to use that bulk endpoint for desktop frames.
The first real desktop frame uses the configured JPEG quality, without a separate
quality-1 startup image. A freshly connected Dashboard-mode panel is primed and
switched once; reconnecting an already extended-mode panel only reopens and
authenticates the bulk session. Each new session starts frame sequence `0x100000`.
HID remains the default and can be selected explicitly with `MSI_DESKTOP_TRANSPORT=hid`.

These settings can help tune the current desktop path:

| Setting | Expected effect |
|---|---|
| `MSI_DESKTOP_MODE=native` | Use a 1920×720 display mode without HiDPI backing; it can reduce capture and encoding work. |
| `MSI_DESKTOP_JPEG_QUALITY` | Lower quality reduces JPEG size and HID traffic, at the cost of image detail (20–95; default 55). |
| `MSI_DESKTOP_TRANSPORT` | `hid` is the default/fallback; `bulk` enables the extended-mode endpoint. |
| `MSI_DESKTOP_FPS` | Capture ceiling (1–60; HID default 60, bulk default 30). Bulk also spaces send starts at this ceiling and selects the latest frame after waiting, without catch-up bursts. |

Bulk write failures drop the session and retry after one second. The latest-frame
capture slot keeps updating while USB is unavailable; recovery does not queue old
frames or automatically switch transports.

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
