# Physical MSI 34-inch flash during desktop entry

The user reports a brief flash/blackout that recovers, and no flash when moving
from stopped output to Kiosk. They specifically note that an HDR off/on cycle
could be hidden by a final HDR-enabled reading.

The current bridge creates a CGVirtualDisplay on each desktop-process start,
applies settings, configures its mirror/origin, and selects a display mode.
Terminating that process removes the virtual monitor. These operations change
macOS display topology even though the panel itself receives ordinary JPEGs.
Kiosk and the new native renderer do not register a virtual monitor.

The previously deployed bridge used an undocumented SkyLight HDR getter to
record a baseline and conditionally restore a changed value. The existing log
contained 12 MSI reads with the raw value 1 before/after and no restoration
write indicated. The getter also returned 0 for the other displays. Those raw
values have not been validated as actual HDR preference/state and must not be
used to claim that another monitor has HDR disabled. The user's correction is
that all three physical screens are on and only the MSI flashes. Monitor power
and HDR state must not be conflated, and the user did not authorize changing
HDR preferences for this comparison.

Neither the sampled raw values nor final-state inspection rule out a transient
signal/colour-pipeline resynchronization. The new diagnostic observer avoids
that getter entirely and never writes physical display settings.

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
