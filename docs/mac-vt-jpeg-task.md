# Mac task: hardware JPEG in the bridge (VideoToolbox), higher quality

Audience: an agent on the Mac with the panel attached and this repo cloned. Goal: replace the software
JPEG path (raw BGRA piped to Rust, encoded by `jpeg-encoder`) with Apple's hardware JPEG encoder inside
`macos/DesktopBridge.m`, and raise quality so frames land at about **150–250 KB** (the official software
keeps 100–200 KB; the panel takes full baseline 4:2:0 frames).

Hard constraint: the panel only accepts **baseline JPEG, SOF0, 4:2:0 with sampling factors `22 11 11`**.
The checker already exists: `msi_xpander::jpeg_profile` (used by `src/jpeg420.rs`). Every frame must pass it.

## Step 1 — 30-minute spike before touching the bridge

Write `macos/VTJpegProbe.m` (build with the same flags as `macos/build-bridge.sh`):

1. Create a 1920×720 `CVPixelBuffer` (32BGRA) filled with a gradient plus text, or grab one frame from SCK.
2. `VTCompressionSessionCreate` with codec `kCMVideoCodecType_JPEG`, encoder spec
   `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder = true`.
   Set `kVTCompressionPropertyKey_Quality` from env `MSI_VT_QUALITY` (default 0.75).
3. Encode 100 frames, print: whether `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` is true,
   mean encode ms, bytes per frame at quality 0.6 / 0.75 / 0.9. Write one frame to `/tmp/vt-probe.jpg`.
4. Check the file: `cargo run --release --features hardware -- jpeg-profile /tmp/vt-probe.jpg`
   (add that tiny CLI subcommand if missing: print width, height, sampling, progressive yes/no).

Stop and report if: hardware flag is false, sampling is not `22 11 11`, or it is progressive/SOF2.
In that case the fallback is libjpeg-turbo in Rust (`turbojpeg` crate), not more VideoToolbox tuning.

## Step 2 — wire it into the bridge behind a switch

- Env `MSI_BRIDGE_ENCODER=vt` selects the new path; default stays `raw` until step 3 passes.
- In the SCK output callback, pass the `CVPixelBuffer` straight to the compression session (no memcpy),
  and emit the JPEG with a new frame magic `JPEG` through the existing `writeRawFrame` framing
  (length, magic, width, height, timestamps).
- Rust `src/desktop_frame.rs`: accept magic `JPEG` and pass the bytes through unchanged, still running
  the `jpeg_profile` check; keep `BGR2`/`RGB2` handling as is.
- Keep the capture→latest-slot→USB loop unchanged. Log per-frame bytes and encode ms in the existing
  `Recent throughput` line (encode ms is now the bridge's number; pass it in the frame header or log it in the bridge).

## Step 3 — measure, same way as the baseline

```sh
MSI_BRIDGE_ENCODER=vt MSI_VT_QUALITY=0.75 bash Run-Desktop.command     # move the mouse for 60 s, Ctrl-C
MSI_BRIDGE_ENCODER=vt MSI_VT_QUALITY=0.9  bash Run-Desktop.command
```

Report the `Live desktop:` / `Recent throughput` lines for both, next to the baseline numbers from
`docs/mac-bulk-mode-test.md` step 2, plus one sentence on how the cursor felt and how the image looked
(text sharpness, colour banding).

## Done means

- `cargo test --features hardware` green; the new subcommand has a unit test on a fixture JPEG.
- Branch `feat/vt-jpeg`, commits pushed; evidence in `docs/evidence/<YYYY-MM-DD>-vt-jpeg.md`.
- No change to the HID/bulk transport code in this task. If bulk mode (`show420`) has already been
  confirmed working, say so in the evidence file; otherwise the VT path still goes over the Dashboard HID
  channel and the fps ceiling is the transport, not the encoder.
