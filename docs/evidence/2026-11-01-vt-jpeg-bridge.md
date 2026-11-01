# VideoToolbox JPEG desktop bridge — 2026-11-01

## Result and scope

The optional VideoToolbox desktop bridge was tested on the physical 1920×720 MSI
panel together with the separate paced desktop-bulk feature. Both quality 0.75
and 0.9 completed a 60-second active run at a capture/send ceiling of 60 fps.
The user reported:

- Quality 0.75: 「超順，比之前還順」 (extremely smooth, smoother than before).
- Quality 0.9: 「滑鼠超順，畫質銳利」 (extremely smooth cursor and sharp image).

These observations establish visible output and perceived improvement on this
Mac/panel. They do not establish sustained 60 displayed frames per second.
Raw/software encoding remains the source default; VT is selected explicitly with
`MSI_BRIDGE_ENCODER=vt`. USB transport is independently selected by the bulk
feature. No silent software encoder fallback is used by the selected VT path.

## Hardware identity and format

The actual compression session EncoderID was matched to Apple's public registry
before and after encoding: `com.apple.videotoolbox.videoencoder.jpeg.ajpeg`,
`IsHardwareAccelerated=true`. This resolves the original spike's unsupported
hardware-use-property query; see [the hardware identity investigation](2026-11-01-vt-jpeg-hardware-confirmed.md).

The bridge encodes captured CVPixelBuffers and sends JPEG payloads through the
existing bounded latest-frame pipeline. Rust validates **every transmitted JPEG**
for native dimensions, SOF0 baseline, 8-bit/three components and sampling
**22 11 11**, then forwards the bytes unchanged. JPEG worker timings for this path
come from the bridge's encode-to-callback duration, not a Rust re-encode.

## 60-second measurements

Commands used on the combined VT + desktop-bulk test build:

```sh
MSI_BRIDGE_ENCODER=vt MSI_VT_QUALITY=0.75 MSI_DESKTOP_TRANSPORT=bulk MSI_DESKTOP_FPS=60 target/release/msi-xpander desktop
MSI_BRIDGE_ENCODER=vt MSI_VT_QUALITY=0.9 MSI_DESKTOP_TRANSPORT=bulk MSI_DESKTOP_FPS=60 target/release/msi-xpander desktop
```

Both runs used native 1920×720 continuous ScreenCaptureKit capture. Active times
were 60.23 s at 0.75 and 60.16 s at 0.9; the harness then sent Ctrl-C/SIGINT.
Neither run logged USB errors.

| VT quality | Median JPEG bytes | Median encode ms | Median USB ms | Median capture-to-send age ms | Recent FPS median / max | Last cumulative FPS | Dropped captures |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0.75 | 239,384 | 2.7 | 5.5 | 14.88 | 37.41 / 54.99 | 14.34 | 98 (first frame 55) |
| 0.90 | 408,208 | 3.1 | 9.6 | 18.81 | 53.66 / 57.03 | 17.70 | 44 (first frame 11) |

JPEG/age medians use the sampled `Live desktop:` lines. Encode/USB medians use
logged per-20-frame means. The conversations and idle periods during these runs
make cumulative 14.34 / 17.70 fps unsuitable as steady-motion display rates.
Recent batches also include idle gaps and are not independently timed panel
refreshes. Scene content and movement differed, so this is not a controlled
quality-only speed comparison. Capture-to-send age excludes panel decode/display
latency. Quality 0.75's approximately 239 KB median met the 150–250 KB target on
this scene; quality 0.9's approximately 408 KB median exceeded that target.

The first 0.75 log still printed the raw-path quality setting `55` in one generic
line; the hardware bridge's actual quality was 0.75 and its JPEG was passed
through unchanged. That logging label was subsequently corrected.

## Startup and handoff observations

The initial HID-kiosk to VT/bulk-desktop 0.75 run replayed the bundled Dashboard
startup JPEG. The user noticed that flash; it was not hidden from this evidence.
The shared normal bulk connector was subsequently changed in `feat/mode-switch`
to the captured unprimed transition. The explicit `show-prime420` diagnostic is
unchanged. The warm quality-0.9 run began with PID 7885 already present and did
not issue host Dashboard priming or require a cable replug.

A later VT quality-1.0 desktop run completed about 10.10 active seconds between
native VT kiosk sessions, with no unplug, reset or bundled Dashboard priming.
[Its handoff log](2026-11-01-vt-kiosk-warm-handoff-result.txt) is a functional warm
switch check, not a third 60-second controlled comparison.

## Validation and artifacts

The VT-only feature has **24 passing Rust tests** (11 library, 10 binary,
3 integration), recorded in [the feature test log](2026-11-01-vt-bridge-rust-tests.txt).
The combined test build initially had 28 tests, then 30 after transport-switch
and software kiosk-quality options. The final combined build with the separate
kiosk hardware helper has 33 passing tests, as reported by the coordinating
agent; this is a different composition from the VT-only feature.

- [Quality 0.75 full result](2026-11-01-vt-bulk-q075-result.txt) and [metrics JSON](2026-11-01-vt-bulk-q075-metrics.json).
- [Quality 0.9 full result](2026-11-01-vt-bulk-q090-result.txt) and [metrics JSON](2026-11-01-vt-bulk-q090-metrics.json).
- [Initial combined tests](2026-11-01-vt-bulk-combined-tests.txt) and [30-test combined checks](2026-11-01-vt-switch-combined-tests.txt).

No private desktop frame, kiosk PNG/JPEG, credentials or USB serial number is
included in these added result artifacts. Sleep/wake, unplug recovery and panel
internal display latency were not measured by these two runs.
