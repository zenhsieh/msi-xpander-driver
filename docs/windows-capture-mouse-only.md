# Windows task: capture what the official software sends when only the mouse moves

Audience: an agent or a person on the **Windows PC where the official MSI Xpander software drives the panel
in extended-display mode**. Goal: learn whether the official data path sends a cursor packet, partial
rectangles, or full frames. This decides how the open driver should implement extended mode.

Device: USB VID `0x0db0`, PID `0x7885` in extended/display mode (`0x7920` is the Dashboard HID mode).

## 0. Rules

- Capture only. Do not install the open driver on this PC and do not stop the official software.
- Do not include USB serial numbers or any personal desktop content in the report; the capture files
  may contain screen pixels, so keep them in the shared folder, not in a public commit.

## 1. Tools

1. Install Wireshark with the **USBPcap** component (default installer option on Windows).
2. Make sure the panel is in extended mode and shows part of the Windows desktop.
3. In Wireshark, choose the USBPcap interface that lists the Xpander (try each; the one with
   `0db0:7885` traffic is right). Apply display filter `usb.idVendor == 0x0db0` or, if that is empty,
   `usb.device_address == <addr>` after finding the address in the first packets.

## 2. Three captures, 10 seconds each, saved as pcapng

| File | What to do during the 10 s |
|---|---|
| `xpander-idle.pcapng` | Nothing. Mouse on the main screen, no window on the panel changes. |
| `xpander-mouse-only.pcapng` | Move the mouse continuously **on the Xpander desktop**, no clicks, no window moves. |
| `xpander-window-drag.pcapng` | Drag a small window around on the Xpander desktop. |

Start capture, wait 2 s, do the action for 10 s, stop. Note the wall-clock time of each capture.

## 3. Export and summarize

In a PowerShell or cmd window (adjust the Wireshark path if needed):

```
"C:\Program Files\Wireshark\tshark.exe" -r xpander-mouse-only.pcapng -Y "usb.idVendor == 0x0db0 || usb.transfer_type == 0x03" -T fields -E separator=, -e frame.time_relative -e usb.endpoint_address -e usb.transfer_type -e usb.data_len -e usb.capdata > xpander-mouse-only.csv
python tools\usb_capture_stats.py xpander-mouse-only.csv
```

Repeat for the other two files. If `python` is missing, install it from the Microsoft Store; the script
has no dependencies.

## 4. What to report

Write `docs/evidence/<YYYY-MM-DD>-windows-mouse-capture.md` (or put it in the shared folder) with:

1. Wireshark/USBPcap versions, Windows version, official software version.
2. For each capture: the script output in full (packet count, endpoint table, size histogram, kinds).
3. The verdict, exactly one of:
   - `CURSOR CHANNEL`: mouse-only shows many packets under 1 KB and a kind other than 0x01, or a non-0x01 kind with tiny declared length.
   - `PARTIAL RECTS`: mouse-only shows kind 0x01 (or another kind) with declared lengths of a few KB, far below the idle/window-drag full-frame size, and the unknown bytes [12..16] vary.
   - `FULL FRAMES`: mouse-only and window-drag both show ~100 KB frames at a steady rate; unknown bytes constant.
4. The first 5 headers of each kind, as printed by the script.

Keep the three `.pcapng` files and `.csv` files in the shared folder; name them as above.
