#!/usr/bin/env python3
"""Kiosk supervisor: fetch a 1920×720 PNG from any command, publish it atomically,
and feed it to the direct USB sender (`msi-xpander kiosk frame.png`).

The frame source is deliberately external: pass `--frame-cmd` (or set
KIOSK_FRAME_CMD) to any shell command that writes PNG bytes to stdout, for
example `ssh myhost render-dashboard`. The panel side never needs credentials
beyond what that command already has.
"""
import argparse
import io
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import threading
import time

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
FRAME = HERE / "frame.png"
SIZE = (1920, 720)
MONO_CANDIDATES = [
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Supplemental/Andale Mono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
]
FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def font(size, candidates=FONT_CANDIDATES):
    for path in candidates:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def publish(image):
    temporary = FRAME.with_suffix(".tmp")
    image.save(temporary, "PNG")
    os.replace(temporary, FRAME)       # atomic: the USB sender never reads a half-written file


def annotate(image, message, failed=False):
    image = image.copy()
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 684, 1919, 719), fill=(83, 28, 29) if failed else (11, 17, 27))
    draw.line((28, 684, 1892, 684), fill=(28, 42, 59))
    # Status dot + message are centred as one group on the 1920-wide strip.
    status_font = font(17)
    x = round((SIZE[0] - (18 + draw.textlength(message, font=status_font))) / 2)
    draw.ellipse((x, 699, x + 6, 705), fill=(242, 194, 104) if failed else (90, 210, 110))
    draw.text((x + 18, 693), message, font=status_font, fill=(234, 241, 250) if failed else (147, 167, 191))
    return image


def fetch(frame_cmd, timeout):
    # Spool stdout to a file so the child can never block on a full pipe.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(shlex.split(frame_cmd), stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=errors)
        try:
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(process.args, timeout)
                time.sleep(0.2)
            if process.returncode:
                errors.seek(0)
                tail = errors.read()[-300:].decode("utf-8", "replace").strip()
                raise subprocess.CalledProcessError(process.returncode, process.args, stderr=tail)
            output.seek(0)
            return output.read()
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def ago(seconds):
    seconds = max(0, int(seconds))
    return f"{seconds}s ago" if seconds < 60 else f"{seconds // 60}m ago" if seconds < 3600 else f"{seconds // 3600}h ago"


def draw_clock(image, now):
    """Live local clock in the top-right 56 px band: `<date> <time>`.

    It ticks every second on the panel side, independent of how long the frame
    command takes (the picture's age is in the footer, after RECEIVED). The frame
    source should leave that corner empty (the reference renderer has --no-clock).
    """
    draw = ImageDraw.Draw(image)
    stamp = time.localtime(now)
    big, mid = font(40, MONO_CANDIDATES), font(24, MONO_CANDIDATES)
    clock, day = time.strftime("%H:%M:%S", stamp), time.strftime("%Y-%m-%d", stamp)
    edge = SIZE[0] - 28
    day_edge = edge - draw.textlength(clock, font=big) - 24
    draw.rectangle((day_edge - draw.textlength(day, font=mid) - 12, 4, SIZE[0] - 1, 52),
                   fill=image.getpixel((SIZE[0] - 2, 2)))
    draw.text((edge, 28), clock, font=big, anchor="rm", fill=(234, 241, 250))
    draw.text((day_edge, 28), day, font=mid, anchor="rm", fill=(147, 167, 191))
    return image


class Feed:
    """Latest frame and fetch outcome, written by the fetch thread, read by the ticker."""

    def __init__(self, image):
        self.lock = threading.Lock()
        self.image, self.success_at, self.error = image, None, None

    def snapshot(self):
        with self.lock:
            return self.image, self.success_at, self.error


def fetch_once(args, feed):
    started = time.monotonic()
    try:
        data = fetch(args.frame_cmd, args.timeout)
        with Image.open(io.BytesIO(data)) as source:
            if source.size != SIZE:
                raise ValueError(f"frame command produced {source.size}, expected {SIZE}")
            image = source.convert("RGB")
        with feed.lock:
            feed.image, feed.success_at, feed.error = image, time.time(), None
        print(f"Fetched {len(data)} PNG bytes in {time.monotonic() - started:.1f}s", flush=True)
        return None
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        with feed.lock:
            feed.error = error
        detail = getattr(error, "stderr", "") or ""
        print(f"Fetch failed: {type(error).__name__} {detail}".strip(), flush=True)
        return error


def fetch_loop(args, feed):
    while True:
        started = time.monotonic()
        fetch_once(args, feed)
        time.sleep(max(1.0, args.interval - (time.monotonic() - started)))


def compose(feed, label, clock, now):
    image, success_at, error = feed.snapshot()
    if error is not None:
        stale = f"LAST RECEIVED {int(now - success_at)}s AGO" if success_at else "NO VALID FRAME YET"
        frame = annotate(image, f"FETCH FAILED  /  {stale}  /  RETRYING", True)
    elif success_at is None:
        frame = annotate(image, f"CONNECTING VIA {label}  /  AWAITING FIRST FRAME", True)
    elif now - success_at > 20:
        frame = annotate(image, f"STALE DATA  /  REFRESH IN PROGRESS  /  LAST RECEIVED {int(now - success_at)}s AGO", True)
    else:
        frame = annotate(image, f"{label} CONNECTED  /  RECEIVED "
                                f"{time.strftime('%H:%M:%S', time.localtime(success_at))} · {ago(now - success_at)}")
    return draw_clock(frame, now) if clock else frame


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--frame-cmd", default=os.environ.get("KIOSK_FRAME_CMD"),
                        help="shell command that writes a 1920x720 PNG to stdout (env KIOSK_FRAME_CMD)")
    parser.add_argument("--binary", default=os.environ.get("MSI_XPANDER_BIN", str(HERE.parent / "target/release/msi-xpander")),
                        help="path to the msi-xpander binary built with --features hardware")
    parser.add_argument("--interval", type=float, default=5.0, help="target seconds between fetches")
    parser.add_argument("--timeout", type=float, default=90.0, help="seconds to wait for one frame command")
    parser.add_argument("--once", action="store_true", help="fetch one preview into frame.png; no USB access")
    parser.add_argument("--clock", action="store_true", default=os.environ.get("KIOSK_CLOCK") == "1",
                        help="draw a live per-second clock and data age top-right (env KIOSK_CLOCK=1)")
    args = parser.parse_args()
    if not args.frame_cmd:
        parser.error("--frame-cmd (or KIOSK_FRAME_CMD) is required, e.g. 'ssh myhost render-dashboard'")
    words = shlex.split(args.frame_cmd)
    # For an SSH command, use its host as the label; otherwise use the command name.
    hosts = [w for w in words[1:] if not w.startswith("-")] if Path(words[0]).name == "ssh" else []
    label = (hosts[0].split("@")[-1] if hosts else Path(words[0]).name).upper()

    sender = None
    latest = Image.new("RGB", SIZE, (18, 22, 28))
    if FRAME.exists():
        try:
            with Image.open(FRAME) as previous:
                if previous.size == SIZE:
                    latest = previous.convert("RGB")
        except OSError:
            pass
    feed = Feed(latest)
    if args.once:
        error = fetch_once(args, feed)
        publish(compose(feed, label, args.clock, time.time()))
        if error is not None:
            raise error
        return
    publish(compose(feed, label, args.clock, time.time()))
    try:
        binary = Path(args.binary)
        if not binary.exists():
            raise SystemExit(f"USB sender not found: {binary} (build with: cargo build --release --features hardware)")
        sender = subprocess.Popen([str(binary), "kiosk", str(FRAME)])
        # Fetching runs on its own thread so a slow frame command never stalls the
        # per-second ticker (clock, data age, stale/failed banners).
        threading.Thread(target=fetch_loop, args=(args, feed), daemon=True).start()
        while True:
            if sender.poll() is not None:
                raise RuntimeError("USB sender exited")
            publish(compose(feed, label, args.clock, time.time()))
            time.sleep(1.0 - time.time() % 1.0)
    finally:
        if sender is not None:
            sender.terminate()
            try:
                sender.wait(timeout=5)
            except subprocess.TimeoutExpired:
                sender.kill()
                sender.wait()


if __name__ == "__main__":
    main()
