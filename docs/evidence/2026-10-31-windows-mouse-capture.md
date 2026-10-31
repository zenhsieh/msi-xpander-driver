# 2026-10-31 Windows capture: mouse-only traffic from the official software

Reported by the project owner from a USB capture on the Windows PC running the official MSI
software in extended-display mode (procedure: `docs/windows-capture-mouse-only.md`). Capture files
stay in the private shared folder; this note records the conclusion only.

## Verdict: FULL FRAMES

- Moving only the mouse produces complete JPEG frames, not cursor packets and not partial rectangles.
- The official software keeps each frame at roughly **100–200 KB** by controlling JPEG size, and sends
  frames over the extended-mode **bulk** endpoint.
- No separate cursor channel was observed.

## What this means for the open driver

- The protocol gap is the transport, not the frame format: full-frame JPEG over bulk is what the
  official path does too. Finishing extended-mode bulk streaming (`show420` / `show-prime420`, see
  `docs/mac-bulk-mode-test.md`) is the whole job; no rect or cursor packet needs reverse-engineering.
- 200 KB × 60 fps ≈ 12 MB/s, well inside USB 2.0 High-Speed bulk throughput, so the target is a steady
  frame rate with bounded encode time, not a smaller frame.
- The remaining engineering is on the macOS side: a hardware-assisted JPEG encoder (ImageIO / VideoToolbox)
  or a faster software encoder, and fixed-interval pacing so frame intervals stay even.

## Open items

- The 4 bytes at offset 12..16 of the bulk packet header were not characterized in this capture.
- Frame rate used by the official software (frames per second) was not recorded; worth reading from the
  capture timestamps with `tools/usb_capture_stats.py` (header interval line).
