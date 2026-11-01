# MSI Xpander live desktop prototype

Known unresolved issue on this Mac: activating the prototype can visibly change the separate physical MSI MPG341CQR monitor's colors. Reproductions include HiDPI virtual-display-only creation and native-mode continuous capture without USB traffic. Stopping capture restored color in a staged test. Omitting forced sRGB capture conversion did not fix it. The full prototype is currently stopped for investigation; do not treat the native mode as a verified color-safe workaround. See the adjacent `msi-xpander-color-and-wake-investigation.txt` report.

This bridge creates a separate macOS display named **MSI Xpander Desktop**, places it to the right of the existing displays, captures only that display, and sends it over the confirmed HID Dashboard image transport. By default it uses a 1920×720-point HiDPI desktop, rendered at 3840×1440 and captured/downscaled to the panel's native 1920×720 pixels. The default capture backend is a continuous ScreenCaptureKit SCStream targeting 60 fps. BGRA pixels are encoded directly in a JPEG worker while the main thread sends the previous JPEG over USB. With JPEG quality 55, live measurements showed multiple consecutive active batches near 58–60 fps, with capture-callback-to-send completion about 20–23 ms during those batches. Other active batches were slower (roughly 33–50 fps), and idle gaps reduced averages further. This does not prove stable physical 60 fps in every scene; user-confirmed responsiveness improved.

Physical output at this HiDPI/native-output configuration was confirmed by the user: normal display and continuously updating clock. Native macOS Displays settings also listed MSI Xpander Desktop as an extended display with 1920×720 selected. The existing physical BenQ, Dell, and MSI MPG341CQR modes were checked before and after and remained unchanged.

Set `MSI_DESKTOP_MODE=native` for 1920×720 without HiDPI (the current default), or `MSI_DESKTOP_MODE=legacy` for the earlier 1440×540 mode. The experimental `hidpi` mode requests 960×360 logical / 1920×720 backing, but macOS rejected it with error 1001 and it is not the working default. The bridge explicitly selects the matching mode from CoreGraphics' offered mode list rather than relying on the initial WindowServer default. Existing display IDs are excluded before any virtual display configuration.

Performance controls: `MSI_DESKTOP_FPS` sets the capture ceiling (1–60, default 60). `MSI_CAPTURE_BACKEND=stream` (default) uses continuous BGRA capture; `screenshots` restores the older screenshot backend. Raw frames travel through a bounded pipe to the JPEG worker, with a single replaceable latest-JPEG slot; older prepared captures are discarded when USB cannot keep up. This removes intermediate PNG compression/decompression, overlaps encoding and transport, and avoids an ever-growing latency queue. `MSI_LIVE_REPORT_DELAY_US` optionally restores deliberate delay between live HID reports (0–10000 microseconds, default 0; old behavior was 1000). Startup priming retains its original pacing. Runtime logs report recent throughput (including idle gaps), average JPEG-worker/USB times, dropped frames, and capture-callback-to-send age (excluding capture time before callback and panel decoding/display latency). Physical panel behavior must be checked separately from host throughput.

`MSI_DESKTOP_JPEG_QUALITY` sets JPEG quality (20–95, default 55). Lower values reduce full-frame traffic but sacrifice image detail; quality 75 restores the earlier image-quality setting. The latest quality-55 run produced about 103 KB frames and capture-to-send completion ages mostly 28–36 ms. These values do not include the panel's own decode/display latency.

Resolution changes while running are detected by both logical and backing-pixel dimensions. The bridge rebuilds its ScreenCaptureKit display filter, updates the source rectangle, and stretches the complete desktop into the fixed panel output rectangle. Frames captured during a mode transition are discarded. Runtime testing observed both 1600×600 and 1280×480 transitions refreshing correctly to 1920×720 output; physical confirmation of removal of black padding is recorded separately.

## Build and run

### Optional hardware JPEG encoding

`MSI_BRIDGE_ENCODER=vt` selects native VideoToolbox JPEG encoding inside the
ScreenCaptureKit bridge. The default remains `raw`; select `MSI_BRIDGE_ENCODER=raw`
to use the existing BGRA-to-Rust software encoder. Encoder selection is separate
from USB transport selection (`MSI_DESKTOP_TRANSPORT` on the desktop-bulk feature).

The VT path requires continuous capture and native 1920×720 output. It passes the
captured `CVPixelBuffer` directly to the explicitly selected hardware JPEG encoder.
The encoder's actual ID must match a registry entry marked hardware accelerated.
Unsupported hardware, incompatible settings or encoding errors stop the selected
VT path rather than silently switching to software.

`MSI_VT_QUALITY` sets VT quality from 0 to 1 (default 0.75). The existing
`MSI_DESKTOP_JPEG_QUALITY` setting only controls raw/software encoding. Frame size
depends on content; 150–250 KB is a measurement target, not a fixed output size.

Each compressed frame carries capture time, capture generation and bridge encode
duration through the pipe. Rust checks the JPEG's dimensions, SOF0/8-bit/three
components and `22 11 11` sampling on every frame, then forwards the JPEG unchanged.
`Recent throughput` keeps its existing format: its JPEG worker time reports the
bridge's encode-to-callback duration for VT, and Rust encode time for raw frames.
Capture-to-send age still includes encoding, pipe transfer and USB sending, but
does not measure the panel's internal decoding/display delay.

After rebuilding the bridge:

```sh
MSI_BRIDGE_ENCODER=vt MSI_VT_QUALITY=0.75 bash Run-Desktop.command
MSI_BRIDGE_ENCODER=vt MSI_VT_QUALITY=0.9 bash Run-Desktop.command
```

From the project directory:

```sh
bash macos/build-bridge.sh
export CARGO_TARGET_DIR=/private/tmp/msi-xpander-target
cargo run --offline --release --features hardware -- desktop
```

The helper is installed at `~/Applications/MSI Xpander Desktop.app`. On first run, allow its Screen Recording access in System Settings → Privacy & Security → Screen & System Audio Recording, then run the command again. No screen frames are written to disk: raw RGBA pixels travel through a bounded process pipe and are encoded as baseline JPEG 4:2:0 for the panel. Capture conversion uses an sRGB bitmap local to this process; no physical display color profiles are set by the bridge.

The panel must be in Dashboard/HID mode. USB initialization waits until the first virtual-desktop capture is available. A test window on the new display shows a live clock. Drag another window past the rightmost edge of your existing desktop to verify real extension. You can rearrange the new display in macOS Displays settings. Existing display origins are not changed by this program.

Stop with Ctrl-C in the launching terminal. The helper owns the virtual display; it disappears when the helper exits. On a Rust transport/capture error, the child is killed and reaped to remove the display. The panel may retain its last image.

## Implementation and limits

- `DesktopBridge.m`: AppKit application, runtime `CGVirtualDisplay` creation, continuous ScreenCaptureKit capture with geometry refresh, packed BGRA output with dimensions and callback timestamps; optional screenshot/RGBA fallback.
- `desktop_frame.rs`: bounded raw-frame validation and direct BGRA/RGBA JPEG encoding, with legacy PNG compatibility; tests cover malformed frames and JPEG red/blue channel order.
- Rust `desktop`: receives bounded frames, encodes 1440×540 or 1920×720 baseline JPEG 4:2:0, sends HID reports, logs measured fps.
- Virtual-display creation uses undocumented CoreGraphics interfaces; it can require adjustments after a macOS update. The runtime approach is described in [Chromium's virtual display test source](https://github.com/chromium/chromium/blob/main/ui/display/mac/test/virtual_display_util_mac.mm).
- Capture uses [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager).
- Build and protocol tests do not establish physical display success. Confirm a changing clock and draggable windows on the actual panel separately.
