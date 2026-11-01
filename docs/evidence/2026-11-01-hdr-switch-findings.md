# Physical MSI 34-inch flash during desktop entry

The user reports a brief flash/blackout that recovers, and no flash when moving
from stopped output to Kiosk. They specifically note that an HDR off/on cycle
could be hidden by a final HDR-enabled reading.

The current bridge creates a CGVirtualDisplay on each desktop-process start,
applies settings, configures its mirror/origin, and selects a display mode.
Terminating that process removes the virtual monitor. These operations change
macOS display topology even though the panel itself receives ordinary JPEGs.
Kiosk and the new native renderer do not register a virtual monitor.

The physical display HDR preservation function reads an initial baseline and
calls SLSDisplaySetHDRModeEnabled only if a subsequent read differs. Reviewing
the existing local desktop log found 12 MSI MPG341CQR checks, all reporting
expected=1, before=1, after=1. No restoration write was indicated by those
checks. These sampled observations do **not** rule out an off/on transition
between checks or an HDR/link resynchronization while the enabled flag stays
unchanged. A final enabled reading is not proof of uninterrupted HDR output.

The observed trigger is consistent with virtual-output configuration causing
physical-output/compositor synchronization. HDR involvement is plausible but
not demonstrated as the exclusive cause. No claim is made that the monitor is
permanently dimmed or that this is a hardware JPEG/USB-bandwidth limitation.

A future persistent virtual-monitor process could avoid removal/recreation on
content-mode switches. That lifecycle change is not included in the native
kiosk work. The new native modes avoid this trigger entirely by drawing their
own AppKit/ScreenSaver frames directly and encoding them with hardware JPEG.

Stop behavior is separate: previously the sender released USB and the panel
held its last framebuffer. The new explicit Stop command sends black after
both producers have stopped, then releases USB. It does not power off the panel
or restore its factory dashboard.
