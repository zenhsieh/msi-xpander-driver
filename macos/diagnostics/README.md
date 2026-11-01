# Display activation diagnostics

These two small processes isolate virtual-output creation from mode activation
and collect read-only state from the other monitors. They do not capture a
screen, send USB frames, write HDR preferences, move physical displays explicitly,
or change the installed app. macOS may rearrange desktop coordinates when it
adds/removes the owned virtual output; record and verify restoration afterward.

Build on macOS with the Xcode command-line tools:

```sh
mkdir -p target/display-diagnostics
xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror \
  -framework AppKit -framework CoreGraphics -framework IOKit \
  macos/diagnostics/DisplayObserver.m -o target/display-diagnostics/DisplayObserver
xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror \
  -framework AppKit -framework CoreGraphics \
  macos/diagnostics/VirtualDisplayProbe.m -o target/display-diagnostics/VirtualDisplayProbe
```

Run the observer in one terminal and the interactive probe in another:

```sh
target/display-diagnostics/DisplayObserver > target/display-diagnostics/observer.jsonl
target/display-diagnostics/VirtualDisplayProbe
```

Probe commands:

- `create`: allocate the display object; do not apply settings yet.
- `create-srgb`: allocate the same descriptor with explicit sRGB primaries/white.
- `create-720p`: allocate the same descriptor, choosing 1280x720 for `apply`.
- `create-480`: choose the aspect-correct 1280x480 mode.
- `apply`: apply the chosen width/height at 60 Hz.
- `apply-native`: apply 1920x720 to the same retained object.
- `apply-720p`: apply 1280x720 to the same retained object.
- `apply-480`: apply 1280x480 to the same retained object.
- `release`: destroy only the probe-owned virtual display.
- `quit`: release it and exit. EOF also exits and releases it.

Finish with `release`/`quit` and Ctrl-C the observer. Do not run a second virtual
output owner while a desktop producer is already active. Ask the person watching
the monitor to confirm each stage; silence is not an observation.

The observer runs an AppKit event loop so display cache updates and CoreGraphics
callbacks are processed. CG state is sampled on the main loop at a nominal 20 ms.
IORegistry work runs separately because framebuffer queries can block; connection
state is sampled more slowly and cannot rule out short physical link events.
The maximum observed CG poll gap is emitted at termination. Capture parameters,
connection descriptions, mode IDs and clock values are observations, not proof
of physical signal continuity. No private SkyLight HDR getter is used.

Only whitelisted connection/framebuffer properties are exported. EDID, monitor
serial numbers, UUIDs and arbitrary registry fields are omitted. Raw system
profiler, IORegistry and unified-log dumps must remain local and should not be
published without review.

The CoreGraphics virtual-display interface is private. Its allocation/settings
pattern can be compared to [Chromium's implementation](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm).
