# Mac task: test extended-mode bulk streaming on the physical panel

Audience: an agent (Codex or Claude Code) running **on the Mac that has the MSI Xpander plugged in**.
Goal: find out whether the panel accepts the extended-mode **bulk** transport (`show420` / `show-prime420`).
That transport is what the official Windows software uses; the current macOS desktop path uses the
Dashboard HID channel and is why the cursor is not smooth. Collect evidence, do not refactor code.

## 0. Rules

- Work only inside this repository. Do not run anything with `sudo`.
- The desktop bridge (`Run-Desktop.command`) creates a virtual display and, on at least one Mac, changed
  the colours of a physical MSI MPG341CQR monitor (see `macos/README.md`). Run it only for the 60-second
  baseline in step 2 and stop it with Ctrl-C.
- Between every USB test, **unplug and replug the panel** and wait until it shows its default screen.
- Never paste USB serial numbers or anything that looks like a credential into the report.

## 1. Setup and environment

```sh
git clone https://github.com/zenhsieh/msi-xpander-driver.git ~/work/msi-xpander-driver   # skip if present
cd ~/work/msi-xpander-driver && git pull
sw_vers; uname -m; cargo --version; rustc --version
system_profiler SPUSBDataType 2>/dev/null | grep -B3 -A12 -i xpander | grep -vi serial
```

Record: macOS version, chip, cargo/rustc versions, and the panel's USB **Speed** line
(`Up to 480 Mb/s` = High-Speed; anything lower changes the whole analysis).

```sh
cargo test --features hardware
cargo run --release --features hardware -- verify
cargo run --release --features hardware -- probe
```

Record the test count and the full `probe` output.

## 2. Baseline: current HID desktop path (60 seconds)

```sh
MSI_DESKTOP_JPEG_QUALITY=55 bash Run-Desktop.command
```

Move the mouse across the Xpander desktop continuously for 60 seconds, then Ctrl-C.
Copy every line that starts with `Live desktop:`, `Recent throughput`, `Captured desktop output`,
`Live JPEG quality`. These give fps, JPEG bytes, capture-to-send age, dropped frames, encode ms, USB ms.
Repeat once with `MSI_DESKTOP_JPEG_QUALITY=35`. Describe how the cursor looked in one sentence each.

## 3. Bulk transport tests

Each run writes `../msi-xpander-<action>-<timestamp>-result.txt` next to the repository folder.

Run A (prime with captured Dashboard startup, then switch to extended mode):

```sh
bash Run-Mac-Test.command show-prime420
```

Run B (extended mode directly):

```sh
bash Run-Mac-Test.command show420
```

For each run record:

1. What the panel shows and when: colour bars / gray ramp / checkerboard, black, frozen Dashboard image,
   partial image, flicker. Note seconds after the command started. A phone photo is welcome.
2. Whether the panel's own mode indicator changed (if it has one) and whether it recovered after replug.
3. The last 40 lines of the result log, especially any `bulk`, `timeout`, `pipe`, `LIBUSB` or `ensure`
   messages.

If both runs are black, do these two extra runs, replugging before each:

```sh
bash Run-Mac-Test.command show-prime420      # second attempt, sometimes the first handshake after plug-in differs
MSI_LIVE_REPORT_DELAY_US=500 bash Run-Mac-Test.command show420
```

Stop after that. Do not keep inventing variants; the next step is comparing against Windows captures.

## 4. Report

Write `docs/evidence/<YYYY-MM-DD>-mac-bulk-test.md` with these sections, in this order:

1. Environment (from step 1).
2. Baseline table: quality, fps, JPEG bytes, age ms, dropped, encode ms, USB ms, cursor impression.
3. One subsection per bulk run: command, panel observation, log excerpt.
4. Verdict, exactly one of: `BULK WORKS` (panel showed the 4:2:0 test image),
   `BULK PARTIAL` (something changed on the panel but not the full image), `BULK BLACK`.
5. Open questions you could not answer from the logs.

Then:

```sh
git checkout -b evidence/mac-bulk-$(date +%Y%m%d)
git add docs/evidence && git commit -m "evidence: Mac extended-mode bulk test"
git push -u origin HEAD      # if this Mac has push access; otherwise copy the evidence file back into the shared inbox folder this task came from
```

Also copy the `../msi-xpander-*-result.txt` logs next to the evidence file (they are small text files).
