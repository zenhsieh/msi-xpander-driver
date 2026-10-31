# Desktop streaming over bulk — 2026-10-31

## Result and default

**Desktop bulk streaming works on the physical panel at requested capture/send ceilings of 30 and 60 fps.** The user confirmed normal output and a marked improvement over the earlier HID baseline at 30 fps, then a further clear improvement at 60 fps. These are configured ceilings, not claims of sustained 30/60 displayed frames per second.

**HID remains the default/fallback.** `MSI_DESKTOP_TRANSPORT=bulk` opts into extended-mode desktop streaming; bulk defaults to 30 fps if `MSI_DESKTOP_FPS` is absent. No installed kiosk configuration was changed. Both physical runs used the first real desktop JPEG at quality 55 and sequence `0x100000`; no quality-1 startup frame was necessary.

## Implementation and validation

- Tested local source implementation: `2c9f67048cbc47d4c79586e400842d958a8e175d`, based on `b379b5d0700ba9abb767b0453fadf906b9274e8a`.
- `src/hardware.rs` reuses `switch_to_extended`, `open_display`, `authenticate`, then `send_jpeg` for each frame. Sequence increments by 1 per successful frame and resets to `0x100000` for a newly authenticated session.
- A panel present as PID `0x7920` receives captured Dashboard priming before mode switch. A panel already enumerated as PID `0x7885` is opened and authenticated directly.
- Fixed pacing is applied before selecting the latest encoded frame. It spaces sends without catching up in bursts after stalls, while the capture/latest-slot pipeline remains intact.
- Bulk write errors drop the transport, wait 1 second, then reopen/authenticate. HID priming only happens if the panel has re-enumerated in Dashboard mode. Runtime USB failure/reconnect recovery was not deliberately induced during these two measurements.
- HID behavior remains available explicitly with `MSI_DESKTOP_TRANSPORT=hid` and remains default when unset.
- `cargo test --features hardware`: **23 passed**, 0 failed (11 library + 9 binary + 3 integration). Four new tests cover wire sequences/payload preservation, short-write failure/new-session sequence reset, settings validation, and 30/60 fps pacing without catch-up bursts.
- Release build succeeded. The installed existing ScreenCaptureKit desktop helper was used; no VideoToolbox bridge integration was used.

## Environment and procedure

Apple M4 Mac mini, arm64; macOS 26.5.1 (25F80); cargo 1.99.0 / rustc 1.99.0. The panel was previously confirmed on a 480 Mb/s USB link. No USB serial numbers or credentials are recorded.

The kiosk LaunchAgent was stopped before tests. The user confirmed physical unplug/replug and return to the default panel screen before each run. Both runs captured 1920×720 native output, targeted software JPEG quality 55 and were stopped using process-group SIGINT (Ctrl-C) after 60 seconds from the first successfully sent desktop frame. The desktop helper exited after each run. Final unplug/replug recovery was confirmed by the user, then the original kiosk LaunchAgent was restored.

```sh
MSI_DESKTOP_TRANSPORT=bulk MSI_DESKTOP_FPS=30 MSI_DESKTOP_JPEG_QUALITY=55 bash Run-Desktop.command
MSI_DESKTOP_TRANSPORT=bulk MSI_DESKTOP_FPS=60 MSI_DESKTOP_JPEG_QUALITY=55 bash Run-Desktop.command
```

30 fps: 60.04 active seconds; 60 fps: 60.05 active seconds. Full logs and all requested metric lines are adjacent to this report.

## Host measurements against HID baseline

FPS is last logged cumulative FPS (includes initialization)/median of recent 20-frame-batch FPS. JPEG bytes and age are medians of logged frame samples; encode/USB are medians of logged per-batch mean times. Dropped captures show cumulative total (includes initialization)/additional captures dropped after the first sent frame. Cursor motion and desktop scenes were not replayed identically, so these are practical observations rather than a controlled quality-only benchmark. Host capture-to-send age excludes panel decoding/display latency.

| Transport / quality | FPS ceiling | FPS cumulative / recent median | JPEG bytes median | Age ms median | Dropped total / active added | Encode ms median | USB ms median | User observation |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| HID / quality 55 | 60 | 29.40 / 34.16 | 109,340 | 38.472 | 1036 / +824 | 5.3 | 28.0 | 微卡頓 |
| HID / quality 35 | 60 | 27.59 / 34.17 | 95,090 | 42.983 | 883 / +779 | 5.3 | 26.6 | Slight improvement, very small difference |
| Bulk / quality 55 | 30 | 21.37 / 26.79 | 120,560 | 28.525 | 257 / +93 | 5.7 | 3.0 | Normal display, noticeably smoother; 非常棒 |
| Bulk / quality 55 | 60 | 35.79 / 49.94 | 107,492 | 20.648 | 408 / +217 | 6.2 | 2.8 | Noticeably smoother than bulk 30; 更流暢，差異明顯 |

### Bulk 30 fps

- First real JPEG used regular quality 55 without a quality-1 bootstrap image; physical output worked.
- User selected normal display and noticeably smoother motion, adding: 「非常棒，但我不知道能不能再進步」.
- No black screen/freeze was reported. Host log: 0 USB interruptions and 0 pending reconnect errors.
- [Full result](2026-10-31-desktop-bulk-30fps-result.txt), [all metric lines](2026-10-31-desktop-bulk-30fps-metrics.txt), [numeric summary](2026-10-31-desktop-bulk-30fps-metrics.json).

### Bulk 60 fps

- Same regular-quality first-frame procedure, fresh Dashboard-mode physical reconnect beforehand.
- User observation versus 30 fps: 「更流暢，差異明顯」.
- No black screen/freeze was reported. Host log: 0 USB interruptions and 0 pending reconnect errors.
- [Full result](2026-10-31-desktop-bulk-60fps-result.txt), [all metric lines](2026-10-31-desktop-bulk-60fps-metrics.txt), [numeric summary](2026-10-31-desktop-bulk-60fps-metrics.json).

Earlier HID baseline raw logs and metrics for qualities 55/35 are also included alongside this report.

## VideoToolbox and remaining limits

The separate `feat/vt-jpeg` spike produced a compatible baseline 4:2:0 JPEG, but hardware acceleration could not be attested: the hardware-use property query returned `-12900` (unsupported). It did not integrate VT into the bridge, so the conditional 60 fps VT desktop run was not performed. Software/raw encoding remains in use for both bulk measurements. See the [VT spike evidence](https://github.com/zenhsieh/msi-xpander-driver/blob/feat/vt-jpeg/docs/evidence/2026-10-31-vt-jpeg.md).

These tests establish visibly improved bulk desktop streaming, not steady 60 fps panel output or full equivalence with the official Windows encoding path. Sleep/wake and injected USB-write-failure recovery remain untested. One-click bulk-to-HID mode reversal without physically replugging has not been established by these tests.
