# Kiosk / extended desktop content switching — 2026-11-01

## Approach

`MSI_KIOSK_TRANSPORT=bulk` lets the existing PNG kiosk use the same extended-mode
transport as `MSI_DESKTOP_TRANSPORT=bulk`. HID remains the kiosk default/fallback.
Stop one producer before starting the other; never open the panel concurrently.

When the panel is already `0db0:7885`, the shared connection function skips
`switch_to_extended`'s HID commands and priming, opens the existing bulk device,
and performs the captured authentication sequence. Regular-quality JPEG frames
start at sequence `0x100000` per authenticated session and increment after each
successful frame. No quality-1 starter image is added to the kiosk path.

The kiosk retains its 250 ms PNG polling, atomic-frame-source convention and
5-second static-image resend. Bulk errors drop the session and retry after one
second; HID's previous two-second retry delay remains unchanged. The current
producer's last image can remain on the panel during the handoff.

`MSI_KIOSK_JPEG_QUALITY` accepts 1–100 and defaults to the previous value 85.
It is validated alongside the transport setting before opening USB. This controls
only kiosk's existing Rust JPEG encoder; desktop/VideoToolbox quality is separate.
Quality 100 remains baseline 4:2:0 with native 1920×720 kiosk frames.

This switches content producers, not the firmware's USB mode. On an initial
Dashboard-mode connection, bulk performs the captured **unprimed** forward
transition. Normal desktop/bulk-kiosk startup does not send
`assets/dashboard-prime.jpg`, including a transition from an already running HID
kiosk. The explicit `show-prime420` diagnostic is unchanged and still primes when
requested. This avoids the known host-generated startup-JPEG flash; whether the
firmware shows any transient image is a physical observation, not a guarantee
made by the transport code.
Returning from extended mode to a HID-only kiosk is a separate unsolved transition.

The unprimed `show420` path was previously confirmed to display the full test
pattern (see the 2026-10-31 bulk evidence). The final normal connector's **cold**
Dashboard-to-bulk transition has not been separately re-tested in this build.
The warm handoffs below are the actual integration tests; they do not establish
a firmware reverse-mode command or eliminate every possible firmware transient.

## Reverse-mode investigation (read-only)

- `fixtures/commands.json` records `realtimeDisplay` enable/disable and
  `extendedDisplay` **enable=true**. It contains no captured reverse
  `extendedDisplay enable=false` request.
- `docs/evidence/2026-10-31-windows-mouse-capture.md` establishes that the official
  software sends full JPEG frames over bulk, but provides no reverse-mode command.
- Thus no vendor reverse request, endpoint or payload is invented here.

The installed `rusb 0.9.4` exposes `DeviceHandle::reset()`, delegating to
`libusb_reset_device`. Its vendored `libusb1-sys 0.7.0` Darwin backend
(`libusb/libusb/os/darwin_usb.c`, `darwin_reset_device` /
`darwin_reenumerate_device`) ordinarily calls `USBDeviceReEnumerate` with options
zero when the device has not been captured/detached. It waits up to ten seconds;
changed descriptors can produce `LIBUSB_ERROR_NOT_FOUND`, requiring rediscovery.
The backend notes that the older `ResetDevice` no longer works from macOS 10.11,
and uses it only for the special already-captured-device case on macOS.

The installed Apple SDK's `IOKit/usb/IOUSBLib.h` documents
`USBDeviceReEnumerate` as terminating the selected device's clients and emulating
an unplug/replug. Normal options-zero re-enumeration is distinct from the
capture/release options requiring authorization or root privilege. Neither that
API nor the libusb implementation guarantees that this panel's firmware will
return from PID `7885` to PID `7920` or avoid displaying its startup picture.

**No reset, detach, sudo, unknown firmware write or physical USB operation was
performed during this investigation.** A reset CLI was deliberately not added:
keeping both producers in extended mode addresses the desired handoff without
resetting the device.

## Validation

`cargo test --features hardware`: **25 passed**, zero failures (11 library,
11 binary, 3 integration). `cargo build --release --features hardware` succeeds.
Physical handoffs were coordinated sequentially on the attached panel, as recorded below. The combined build with VT desktop and kiosk helper features has 33 passing tests; that is a different feature composition from this branch alone.
Existing desktop bulk tests already cover JPEG payload and
sequence preservation, short-write failure and new-session sequence restart.
A new kiosk setting test checks the default HID choice, bulk selection and
invalid-value errors before any connection is attempted.
The quality test covers the unchanged default, valid/invalid bounds, and a
decodable baseline 4:2:0 JPEG at quality 100.


## Physical warm-handoff evidence

The coordinating agent stopped the active producer before opening the next one.
The connected panel remained in extended mode, PID **0db0:7885**. No physical
USB replug, USB reset or reverse-mode firmware request was used between these
content producers, and no bundled Dashboard JPEG was sent during these warm
handoffs.

1. **VT bulk desktop quality 0.9 -> software bulk kiosk.** After the 60-second
   desktop run, the original kiosk supervisor was restarted using the bulk sender
   on the same panel. The user described the improvement as 「Dsub 變 DVI」, an
   analogy for visible clarity rather than a claim that the USB interface became
   DVI. [The event record](2026-11-01-switch-events.txt) states that the initial
   software sender used its existing JPEG quality 85; quality 100 was staged for
   the subsequently compiled setting option.
2. **Software bulk kiosk -> hardware JPEG bulk kiosk.** The separate
   `feat/kiosk-vt-jpeg` helper was deployed, with explicit hardware identity checks,
   BT.601 color handling and quality 1.0. The panel stayed PID 7885. The user
   confirmed 「正常，而且更清楚」 (normal and clearer).
3. **Hardware JPEG bulk kiosk -> VT bulk desktop quality 1.0 -> hardware JPEG
   bulk kiosk.** The [warm-handoff result](2026-11-01-vt-kiosk-warm-handoff-result.txt)
   records native 1920×720 output, hardware identity verification, successful bulk
   authentication and regular-quality frames. Desktop ran for **10.10 active
   seconds**, then the kiosk service was restored. This was a functional switch
   check, not a new 60-second performance comparison.

The [quality-0.9 desktop log](2026-11-01-vt-bulk-q090-result.txt) explicitly records
a direct bulk-to-bulk restart without unplug/replug, and contains no Dashboard
image priming. The earlier initial quality-0.75 run did replay the bundled
Dashboard asset; the user flagged that flash, and normal shared connection code
was then changed to `switch_to_extended(context, false, false)`. The explicit
`show-prime420` diagnostic remains unchanged.

Source defaults remain HID transport and raw/software kiosk encoding. This Mac's
persistent local service was separately configured for bulk + VT quality 1.0;
no private service configuration, actual kiosk PNG/JPEG or signing material is
included in this evidence. The mode-switch branch provides shared bulk transport
and software kiosk quality; VT encoders are independent features tested in the
combined build.
