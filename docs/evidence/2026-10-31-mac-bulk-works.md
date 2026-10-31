# 2026-10-31 Mac: extended-mode bulk streaming works

Reported by the project owner after running `docs/mac-bulk-mode-test.md` on the Mac with the panel
attached: `show-prime420` / `show420` put the 4:2:0 test image on the panel over the extended-mode
bulk endpoint. Verdict: **BULK WORKS**. Detailed logs and baseline numbers live with the Mac run.

Consequence: the desktop path can move from the Dashboard HID channel to bulk (`docs/mac-desktop-over-bulk-task.md`).
Combined with the Windows capture (`2026-10-31-windows-mouse-capture.md`: official software sends full
100–200 KB JPEG frames over bulk, no cursor channel), full-frame JPEG over bulk at a steady rate is the
complete design; nothing else needs reverse-engineering for extended mode.
