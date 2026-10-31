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
import time

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
FRAME = HERE / "frame.png"
SIZE = (1920, 720)
FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def font(size):
    for path in FONT_CANDIDATES:
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


def fetch(frame_cmd, latest, success_at, timeout):
    # Spool stdout to a file so the child can never block on a full pipe.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(shlex.split(frame_cmd), stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=errors)
        try:
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(process.args, timeout)
                if success_at is not None and time.time() - success_at > 20:
                    publish(annotate(latest, f"STALE DATA  /  REFRESH IN PROGRESS  /  LAST RECEIVED {int(time.time() - success_at)}s AGO", True))
                time.sleep(1)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--frame-cmd", default=os.environ.get("KIOSK_FRAME_CMD"),
                        help="shell command that writes a 1920x720 PNG to stdout (env KIOSK_FRAME_CMD)")
    parser.add_argument("--binary", default=os.environ.get("MSI_XPANDER_BIN", str(HERE.parent / "target/release/msi-xpander")),
                        help="path to the msi-xpander binary built with --features hardware")
    parser.add_argument("--interval", type=float, default=5.0, help="target seconds between fetches")
    parser.add_argument("--timeout", type=float, default=90.0, help="seconds to wait for one frame command")
    parser.add_argument("--once", action="store_true", help="fetch one preview into frame.png; no USB access")
    args = parser.parse_args()
    if not args.frame_cmd:
        parser.error("--frame-cmd (or KIOSK_FRAME_CMD) is required, e.g. 'ssh myhost render-dashboard'")
    label = shlex.split(args.frame_cmd)[0].upper()

    sender = None
    latest = Image.new("RGB", SIZE, (18, 22, 28))
    success_at = None
    if FRAME.exists():
        try:
            with Image.open(FRAME) as previous:
                if previous.size == SIZE:
                    latest = previous.convert("RGB")
        except OSError:
            pass
    publish(annotate(latest, f"CONNECTING VIA {label}  /  AWAITING FIRST FRAME", True))
    try:
        if not args.once:
            binary = Path(args.binary)
            if not binary.exists():
                raise SystemExit(f"USB sender not found: {binary} (build with: cargo build --release --features hardware)")
            sender = subprocess.Popen([str(binary), "kiosk", str(FRAME)])
        while True:
            if sender is not None and sender.poll() is not None:
                raise RuntimeError("USB sender exited")
            started = time.monotonic()
            try:
                data = fetch(args.frame_cmd, latest, success_at, args.timeout)
                with Image.open(io.BytesIO(data)) as source:
                    if source.size != SIZE:
                        raise ValueError(f"frame command produced {source.size}, expected {SIZE}")
                    latest = source.convert("RGB")
                success_at = time.time()
                publish(annotate(latest, f"{label} CONNECTED  /  RECEIVED {time.strftime('%H:%M:%S')}"))
                print(f"Updated {FRAME}: {len(data)} PNG bytes; fetch {time.monotonic() - started:.1f}s", flush=True)
                if args.once:
                    return
            except (subprocess.SubprocessError, OSError, ValueError) as error:
                stale = f"LAST RECEIVED {int(time.time() - success_at)}s AGO" if success_at else "NO VALID FRAME YET"
                publish(annotate(latest, f"FETCH FAILED  /  {stale}  /  RETRYING", True))
                detail = getattr(error, "stderr", "") or ""
                print(f"Fetch failed: {type(error).__name__} {detail}".strip(), flush=True)
                if args.once:
                    raise
            time.sleep(max(1.0, args.interval - (time.monotonic() - started)))
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
