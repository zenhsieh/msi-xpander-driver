# Mac task: desktop streaming over the extended-mode bulk endpoint

Audience: an agent on the Mac with the panel attached. Prerequisite: `show420` confirmed working
(`docs/evidence/2026-10-31-mac-bulk-works.md`). Goal: make `desktop` send frames the way `show420` does,
instead of Dashboard HID reports. Do this **before** or **independently of** the VideoToolbox task; the two
touch different files.

## What to change

1. `src/hardware.rs`, `desktop()`: add env `MSI_DESKTOP_TRANSPORT` with values `hid` (current default) and
   `bulk`. For `bulk`, reuse exactly what `show_internal` does: `switch_to_extended` (with priming when the
   panel is freshly connected, same rule as `show-prime420`), `open_display`, `authenticate`, then per frame
   `send_jpeg(transport, &jpeg, sequence)` with `sequence` starting at `0x100000` and incrementing by 1.
   Keep the first-frame trick from `show_internal` (a quality-1 frame, then the real frame) only if the panel
   needs it; try without first and note the result.
2. Keep the capture → latest-slot → send loop. Add fixed pacing: env `MSI_DESKTOP_FPS` already exists as a
   capture ceiling; for bulk, also sleep so sends are evenly spaced at that rate (default 30, try 60).
3. Reconnect handling: on a bulk write error, drop the transport, wait 1 s, redo `open_display` +
   `authenticate` (not the HID priming unless the panel re-enumerated as PID `0x7920`).
4. Do not change the HID path; it stays as the fallback.

## Measure

```sh
MSI_DESKTOP_TRANSPORT=bulk MSI_DESKTOP_FPS=30 bash Run-Desktop.command   # 60 s, move the mouse, Ctrl-C
MSI_DESKTOP_TRANSPORT=bulk MSI_DESKTOP_FPS=60 bash Run-Desktop.command
```

Report the `Live desktop:` / `Recent throughput` lines against the HID baseline, the number of dropped
captures, whether the panel ever went black or froze, and one sentence on cursor smoothness.
If the VideoToolbox path is already merged, run the 60 fps case once more with `MSI_BRIDGE_ENCODER=vt`.

## Done means

- `cargo test --features hardware` green. Branch `feat/desktop-bulk`, pushed.
- Evidence file `docs/evidence/<YYYY-MM-DD>-desktop-bulk.md` with the numbers above.
- README status row for "macOS extended desktop" updated to say which transport is default after your test.
