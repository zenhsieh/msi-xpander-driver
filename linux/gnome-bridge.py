#!/usr/bin/python3
"""GNOME Wayland virtual monitor -> PipeWire -> framed BGRA on stdout.

Only the new virtual output is recorded. This process never opens USB devices.
Requires the host distribution's PyGObject and GStreamer (see README.md).
"""
import argparse
import os
import signal
import struct
import sys
import threading
import time

WIDTH, HEIGHT = 1920, 720
SERVICE = "org.gnome.Mutter.ScreenCast"
ROOT = "/org/gnome/Mutter/ScreenCast"
SESSION = SERVICE + ".Session"
STREAM = SERVICE + ".Stream"


def frame_packet(pixels, width, height, stride, offset=0, captured_us=None):
    """Remove row padding before using the existing BGR2 wire contract."""
    row = width * 4
    if (width, height) != (WIDTH, HEIGHT) or stride < row or offset < 0:
        raise ValueError("Unexpected BGRA geometry/stride")
    if len(pixels) < offset + (height - 1) * stride + row:
        raise ValueError("Truncated BGRA buffer")
    if stride == row:
        packed = pixels[offset:offset + row * height]
    else:
        packed = b"".join(pixels[offset + y * stride:offset + y * stride + row]
                          for y in range(height))
    header = struct.pack("<4sIIQQ", b"BGR2", width, height,
                         time.time_ns() // 1000 if captured_us is None else captured_us, 0)
    return struct.pack("<I", len(header) + len(packed)) + header + packed


class Bridge:
    def __init__(self, fps, test_pattern=False, max_frames=0):
        import gi
        gi.require_version("Gst", "1.0")
        gi.require_version("GstVideo", "1.0")
        from gi.repository import Gio, GLib, Gst, GstVideo
        self.Gio, self.GLib, self.Gst, self.GstVideo = Gio, GLib, Gst, GstVideo
        Gst.init(None)
        self.fps, self.test_pattern, self.max_frames = fps, test_pattern, max_frames
        self.loop = GLib.MainLoop()
        self.bus = None
        self.session_path = None
        self.pipeline = None
        self.subscriptions = []
        self.pending = threading.Condition()
        self.latest = None
        self.stopping = False
        self.error = None
        self.frames = 0
        self.started = time.monotonic()
        self.writer = threading.Thread(target=self.write_frames, daemon=True)

    def call(self, path, interface, method, arguments=None, reply=None):
        return self.bus.call_sync(SERVICE, path, interface, method, arguments,
                                  self.GLib.VariantType.new(reply) if reply else None,
                                  self.Gio.DBusCallFlags.NONE, 10000, None)

    def fail(self, message):
        if self.error is None:
            self.error = str(message)
        self.loop.quit()
        return False

    def write_frames(self):
        try:
            while True:
                with self.pending:
                    self.pending.wait_for(lambda: self.latest is not None or self.stopping)
                    if self.stopping:
                        return
                    packet, self.latest = self.latest, None
                # A slow USB consumer cannot block Mutter's capture thread.
                # At most one newer frame is retained while this write blocks.
                sys.stdout.buffer.write(packet)
                sys.stdout.buffer.flush()
                self.frames += 1
                if self.max_frames and self.frames >= self.max_frames:
                    self.GLib.idle_add(self.loop.quit)
                    return
        except (BrokenPipeError, OSError) as error:
            self.GLib.idle_add(self.fail, error)

    def sample(self, sink):
        Gst, GstVideo = self.Gst, self.GstVideo
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.EOS
        buffer = sample.get_buffer()
        mapped = None
        try:
            captured_us = time.time_ns() // 1000
            info = GstVideo.VideoInfo.new_from_caps(sample.get_caps())
            meta = GstVideo.buffer_get_video_meta(buffer)
            stride = meta.stride[0] if meta else info.stride[0]
            offset = meta.offset[0] if meta else info.offset[0]
            ok, mapped = buffer.map(Gst.MapFlags.READ)
            if not ok:
                raise ValueError("Could not map PipeWire BGRA buffer")
            packet = frame_packet(mapped.data, info.width, info.height, stride, offset, captured_us)
            with self.pending:
                self.latest = packet
                self.pending.notify()
            return Gst.FlowReturn.OK
        except Exception as error:
            self.GLib.idle_add(self.fail, error)
            return Gst.FlowReturn.ERROR
        finally:
            if mapped is not None:
                buffer.unmap(mapped)

    def pipeline_message(self, bus, message):
        if message.type == self.Gst.MessageType.ERROR:
            error, debug = message.parse_error()
            self.fail(f"GStreamer: {error.message} ({debug})")
        elif message.type == self.Gst.MessageType.EOS:
            self.loop.quit()

    def start_pipeline(self, node=None):
        if self.pipeline is not None:
            return
        source = ("videotestsrc is-live=true pattern=smpte" if self.test_pattern else
                  f"pipewiresrc path={int(node)} do-timestamp=true")
        # Fix the virtual monitor's size by negotiation before conversion.
        self.pipeline = self.Gst.parse_launch(
            f"{source} ! video/x-raw,width={WIDTH},height={HEIGHT},framerate={self.fps}/1 "
            "! videoconvert ! video/x-raw,format=BGRA "
            "! appsink name=frames emit-signals=true max-buffers=1 drop=true sync=false")
        self.pipeline.get_by_name("frames").connect("new-sample", self.sample)
        gst_bus = self.pipeline.get_bus()
        gst_bus.add_signal_watch()
        gst_bus.connect("message", self.pipeline_message)
        if self.pipeline.set_state(self.Gst.State.PLAYING) == self.Gst.StateChangeReturn.FAILURE:
            raise RuntimeError("Could not start PipeWire pipeline")

    def node_added(self, connection, sender, path, interface, signal_name, parameters, data):
        try:
            node, = parameters.unpack()
            print(f"GNOME virtual monitor: PipeWire node {node}, {WIDTH}x{HEIGHT}, ceiling {self.fps}/s",
                  file=sys.stderr, flush=True)
            self.start_pipeline(node)
        except Exception as error:
            self.fail(error)

    def closed(self, *args):
        self.fail("GNOME screen-cast session closed (logout, compositor restart or Stop)")

    def watchdog(self):
        if self.frames == 0 and time.monotonic() - self.started > 20:
            return self.fail("No GNOME/PipeWire frames within 20 seconds")
        return True

    def run(self):
        GLib, Gio = self.GLib, self.Gio
        for signum in (signal.SIGINT, signal.SIGTERM):
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, lambda: (self.loop.quit(), False)[1])
        try:
            self.writer.start()
            GLib.timeout_add_seconds(1, self.watchdog)
            if self.test_pattern:
                self.start_pipeline()
            else:
                if os.environ.get("XDG_SESSION_TYPE") != "wayland":
                    raise RuntimeError("Run inside the logged-in GNOME Wayland session, not a root/SSH session")
                self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
                # Keep the same D-Bus connection for the entire session. Mutter
                # checks the caller identity and closes it when this peer exits.
                self.session_path, = self.call(ROOT, SERVICE, "CreateSession",
                                              GLib.Variant("(a{sv})", ({},)), "(o)").unpack()
                properties = {"cursor-mode": GLib.Variant("u", 1),
                              "is-platform": GLib.Variant("b", True)}
                stream_path, = self.call(self.session_path, SESSION, "RecordVirtual",
                                         GLib.Variant("(a{sv})", (properties,)), "(o)").unpack()
                self.subscriptions.append(self.bus.signal_subscribe(
                    SERVICE, STREAM, "PipeWireStreamAdded", stream_path, None,
                    Gio.DBusSignalFlags.NONE, self.node_added, None))
                self.subscriptions.append(self.bus.signal_subscribe(
                    SERVICE, SESSION, "Closed", self.session_path, None,
                    Gio.DBusSignalFlags.NONE, self.closed, None))
                self.call(self.session_path, SESSION, "Start")
            self.loop.run()
        finally:
            with self.pending:
                self.stopping = True
                self.pending.notify_all()
            if self.pipeline:
                self.pipeline.set_state(self.Gst.State.NULL)
            if self.session_path:
                try:
                    self.call(self.session_path, SESSION, "Stop")
                except Exception:
                    pass  # Compositor may already have closed the session.
            if self.bus:
                for subscription in self.subscriptions:
                    self.bus.signal_unsubscribe(subscription)
        if self.error:
            raise RuntimeError(self.error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-pattern", action="store_true", help="Synthetic pipeline only; no GNOME session or USB")
    parser.add_argument("--frames", type=int, default=0, help="Stop after N output frames (0: unlimited)")
    args = parser.parse_args()
    fps = int(os.environ.get("MSI_DESKTOP_FPS", "30"))
    if not 1 <= fps <= 60 or args.frames < 0:
        parser.error("Update frequency must be 1..60 and frame count nonnegative")
    Bridge(fps, args.test_pattern, args.frames).run()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"GNOME bridge: {error}", file=sys.stderr)
        sys.exit(1)
