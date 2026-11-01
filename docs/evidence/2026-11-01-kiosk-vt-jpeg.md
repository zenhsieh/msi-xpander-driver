# Native hardware JPEG for PNG kiosk — 2026-11-01

## Result

Native 1920×720 kiosk PNG updates were encoded with Apple's verified hardware
JPEG encoder and sent over the extended-mode bulk endpoint. The user confirmed
「正常，而且更清楚」 (normal, and clearer). The persistent local service was
configured for **bulk + VT quality 1.0**. Source defaults remain HID transport and
raw/software encoding; this deployment choice does not silently change those
source defaults.

Kiosk does **not** create a virtual display or capture the desktop. Its independent
`VTImageEncoder` helper decodes the supplied PNG into an owned local CVPixelBuffer
and encodes that image. The helper is separate from the ScreenCaptureKit desktop
bridge, though both use the same public VideoToolbox hardware JPEG implementation.

## Configuration and validation

```sh
bash macos/build-vt-image-encoder.sh
MSI_KIOSK_TRANSPORT=bulk MSI_KIOSK_ENCODER=vt MSI_VT_QUALITY=1.0 \
  MSI_KIOSK_VT_HELPER="$PWD/target/VTImageEncoder" \
  cargo run --release --features hardware -- kiosk kiosk/frame.png
```

`MSI_KIOSK_ENCODER=raw` restores the existing Rust software encoder, with its
independent `MSI_KIOSK_JPEG_QUALITY` setting. `MSI_VT_QUALITY` accepts 0–1 and
defaults to 0.75 when not explicitly set. Desktop's `MSI_BRIDGE_ENCODER` does not
select kiosk encoding.

Each helper session verifies the actual EncoderID before and after encoding:
`com.apple.videotoolbox.videoencoder.jpeg.ajpeg`, matched to a public registry
entry with `IsHardwareAccelerated=true`. Rust validates every returned JPEG as
native 1920×720, SOF0 baseline, three 8-bit components, sampling **22 11 11** before
USB writes. A helper error, malformed format or 10-second helper deadline retains
the last panel image and triggers retry rather than transmitting unchecked data.

The standalone helper passes qualities 0.75, 0.9 and 1.0, including PNG input
without a filename extension. Invalid/non-finite qualities, missing input and
wrong dimensions reject with empty stdout. Strict `-Wall -Wextra -Werror`
compilation and the clang static analyzer pass. See [the helper results](2026-11-01-kiosk-vt-helper-result.txt).

## Owned buffer, orientation and color matrix

The helper constructs its own pixel buffer from the PNG; it does not depend on
a transient capture callback's buffer. Synthetic tests used top red / bottom blue
areas and asymmetric green/white markers to detect vertical inversion and channel
mixups. Explicit `kCVImageBufferYCbCrMatrix_ITU_R_601_4` attachment corrects the
JPEG/BT.709 matrix tint seen during development: the pure-red sample that had
previously decoded near 232 now decodes as **254,0,0** for source **255,0,0**.
The corrected blue sample is **0,0,254**; green/white and orientation are retained.
All sampled channel errors are at most five at the tested qualities.

The public synthetic validation metadata is in [the orientation/color JSON](2026-11-01-kiosk-vt-helper-orientation.json).
No actual private kiosk image is included. A separate real-frame profile check
reported `width=1920 height=720 sampling=22 11 11 progressive=no baseline=yes`;
[only the output metadata](2026-11-01-kiosk-vt-live-frame-encode.txt) is included.

## Runtime observations

Initial deployment observations were approximately **579 KB per JPEG**, typically
**13–14 ms USB**, **330–450 ms total helper/encode pipeline**, and roughly
**20–40 ms** inside the hardware encode callback. These are representative
observations of a changing dashboard, not a controlled fixed-scene benchmark.
The separate saved real-frame helper sample was **573,472 bytes** at quality 1.0,
with **12.763 ms** callback encode time.

The pipeline metric includes helper process startup, its PNG decoding, session
setup, I/O and validation; it is not the same as the callback-only hardware encode
metric. It excludes the remote dashboard fetch and panel internal decode/display
latency. Later runtime-tail samples vary with image content and system activity;
see [the filtered timing/identity log](2026-11-01-kiosk-vt-runtime-stats.txt) and
[its numeric summary](2026-11-01-kiosk-vt-runtime-metrics.json). These retain
outliers and do not claim a fixed latency ceiling or 60 fps kiosk throughput.

The native hardware kiosk remained in PID **0db0:7885** when taking over from the
software bulk kiosk and when returning from a roughly 10-second VT desktop test.
The coordinating agent performed these warm content handoffs without a physical
replug, USB reset or host-sent bundled Dashboard startup JPEG. The source default
HID path remains available; no reverse firmware-mode command is claimed.

## Checks and delivery scope

- This kiosk feature: **28 passing Rust tests** (11 library, 14 binary,
  3 integration), [full test log](2026-11-01-kiosk-vt-rust-tests.txt).
- The final combined VT-desktop + bulk + kiosk build has **33 passing tests**,
  reported by the coordinating agent; this is a different composition.
- [Deployment event](2026-11-01-kiosk-vt-deployment.txt): persistent native helper
  and sender installed, local service bulk + VT quality 1.0. Configuration remains
  local; no private kiosk PNG/JPEG, environment file, signing private key, USB
  serial or credential was copied into these added artifacts.

The later menu application's lifecycle and switching checks are separate from
this encoder evidence. Cold final-code transitions, long-duration recovery and
panel-internal display latency are not established by these warm runtime checks.
