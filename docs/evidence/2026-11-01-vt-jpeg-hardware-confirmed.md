# Hardware JPEG confirmed — 2026-11-01

## Finding

This Apple M4 Mac's native VideoToolbox JPEG encoder is hardware accelerated. The original JPEG compression session selected `com.apple.videotoolbox.videoencoder.jpeg.ajpeg`, and Apple's public encoder registry identifies that exact ID as **JPEG (HW)** with **IsHardwareAccelerated = true**. The live session EncoderID was checked before and after each 100-frame encode run.

This resolves the previous spike's uncertainty. It does not imply that the installed desktop bridge has been changed: the bridge still uses the existing raw/software path. No USB test, capture session, virtual display, or kiosk restart was needed for this investigation.

## Why the original query failed

`UsingHardwareAcceleratedVideoEncoder` is absent from this JPEG encoder's supported-property dictionary. Querying it returns `-12900` (`kVTPropertyNotSupportedErr`). The same error occurs for both the hardware JPEG selection and the hardware-disabled JPEG selection.

As a control, an H.264 hardware session advertises that property and returns true. Thus the error is a property-support limitation of this JPEG encoder on this runtime; it is not a USB version issue, panel rejection, access-permission denial, or a false hardware-use result.

The inspector compares these cases without encoding or accessing a display:

| Selection | Actual EncoderID | Registry hardware | Hardware-use query |
| --- | --- | --- | --- |
| JPEG default | `com.apple.videotoolbox.videoencoder.jpeg.ajpeg` | true; name JPEG (HW) | unsupported, -12900 |
| JPEG require hardware | same `.jpeg.ajpeg` ID | true | unsupported, -12900 |
| JPEG disable hardware | `com.apple.videotoolbox.videoencoder.jpeg` | hardware flag not listed | unsupported, -12900 |
| JPEG explicit hardware ID + require hardware | `.jpeg.ajpeg` ID | true | unsupported, -12900 |
| JPEG explicit alternate ID + require hardware | `.jpeg` ID | hardware flag not listed | unsupported, -12900 |
| H.264 require hardware | `com.apple.videotoolbox.videoencoder.ave.avc` | not needed for this control | true, status 0 |

Session creation also succeeds when the alternate JPEG encoder ID is explicitly requested alongside RequireHardware=true. Therefore, on this runtime, session-creation success alone does not distinguish the two JPEG implementations. Matching the session's actual EncoderID to the registry's explicit true hardware flag is the stronger public-API evidence.

## Corrected probe and actual encoding

`VTJpegProbe.m` retains RequireHardware=true. When the direct query is unavailable, it matches the session EncoderID with `VTCopyVideoEncoderList` and requires an explicit true `kVTVideoEncoderList_IsHardwareAccelerated` value. A missing flag is not treated as true. An explicit false direct hardware-use result still stops the probe. The registry check runs again after all 100 frame callbacks at each quality.

| Quality | Frames | Mean callback encode ms | Mean bytes | Encoder before / after |
| --- | --- | --- | --- | --- |
| 0.60 | 100 | 1.162 | 72,982 | `.jpeg.ajpeg`, hardware=true / same |
| 0.75 | 100 | 1.226 | 72,982 | `.jpeg.ajpeg`, hardware=true / same |
| 0.90 | 100 | 1.491 | 152,108 | `.jpeg.ajpeg`, hardware=true / same |

The corrected probe exits **0**. The saved quality-0.75 output again passes the existing Rust checker: **1920×720, SOF0 baseline, sampling 22 11 11, progressive=no**.

These are timings for sequential encoding of a synthetic gradient/text image, not actual desktop CPU-use, frame-rate, image-quality or power measurements. Quality 0.75 is below the 150–250 KB target on this scene; 0.90 is approximately 152 KB. The final desktop integration still needs per-frame format checks and separate measurements.

## Reproduce and evidence

```sh
xcrun clang -fobjc-arc -fblocks -O2 \
  -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  macos/VTJpegInspect.m -o target/VTJpegInspect
target/VTJpegInspect
bash macos/build-vt-probe.sh
target/VTJpegProbe
target/release/msi-xpander jpeg-profile /tmp/vt-probe.jpg
```

- [Encoder enumeration and selection controls](2026-11-01-vt-jpeg-encoder-inspection.txt).
- [300-frame hardware-confirmation run](2026-11-01-vt-jpeg-hardware-confirmation.txt).
- [Output JPEG profile](2026-11-01-vt-jpeg-hardware-profile.txt).
- `macos/VTJpegInspect.m` is a standalone inspection tool; no private APIs or credential/device identifiers are accessed.

## Apple references

- [Encoder registry hardware flag](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderlist_ishardwareaccelerated). The installed public SDK header documents that an explicit true value identifies a hardware-accelerated encoder.
- [Actual session EncoderID](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_encoderid). The SDK states it matches the ID from `VTCopyVideoEncoderList`.
- [Hardware-use query](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder).
- [Required hardware selection option](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder).
