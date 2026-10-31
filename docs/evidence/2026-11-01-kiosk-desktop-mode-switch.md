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

This switches content producers, not the firmware's USB mode. On an initial
Dashboard-mode connection, bulk still performs the captured forward transition.
Returning from extended mode to a HID-only kiosk is a separate unsolved transition.

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

`cargo test --features hardware`: **24 passed**, zero failures (11 library,
10 binary, 3 integration). `cargo build --release --features hardware` succeeds.
Physical handoff measurements are recorded separately by the coordinating agent.
Existing desktop bulk tests already cover JPEG payload and
sequence preservation, short-write failure and new-session sequence restart.
A new kiosk setting test checks the default HID choice, bulk selection and
invalid-value errors before any connection is attempted.
