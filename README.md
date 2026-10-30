# msi-xpander-rust

Open-source driver for the **MSI Xpander** USB companion display (the 12.4"
1920×720 panel bundled with some MSI laptops / sold as MPG Xpander), written in
Rust, with a macOS extended-desktop bridge and a kiosk mode that shows any PNG.

Not affiliated with or endorsed by MSI. This is a research prototype built from
USB captures of the official software; see `docs/research-notes.txt` for the
exact validation status of each path.

## What works

| Path | Status |
|---|---|
| HID mode switch + RSA vendor handshake | confirmed on macOS and Windows |
| Dashboard mode (vendor HID, 1440×540 baseline JPEG 4:2:0) | confirmed, physical output verified |
| Extended-mode bulk streaming (`show420`, `show-prime420`) | experimental, macOS only |
| macOS extended desktop (`desktop`, ScreenCaptureKit bridge) | works at 1920×720; see `macos/README.md` for caveats |
| Kiosk mode (`kiosk frame.png`, any PNG source) | works; see `kiosk/README.md` |

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
cargo run --release --features hardware -- kiosk frame.png
```

`Run-Mac-Test.command`, `Run-Desktop.command` and `Run-Kiosk.command` wrap the
common macOS flows and log to a timestamped file next to the project.

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
