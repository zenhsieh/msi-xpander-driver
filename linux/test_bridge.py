"""Wire contract and real GStreamer tests; never enumerate USB."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).with_name("gnome-bridge.py")
spec = importlib.util.spec_from_file_location("bridge", SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class FrameTests(unittest.TestCase):
    def test_stride_offset_timestamp_and_channel_order(self):
        row = b"\x03\x02\x01\xff" * bridge.WIDTH
        data = b"prefix" + (row + b"padding!") * bridge.HEIGHT
        packet = bridge.frame_packet(data, bridge.WIDTH, bridge.HEIGHT,
                                     len(row) + 8, 6, captured_us=123456)
        size, = struct.unpack_from("<I", packet)
        self.assertEqual(size, len(packet) - 4)
        self.assertEqual(struct.unpack_from("<4sIIQQ", packet, 4),
                         (b"BGR2", 1920, 720, 123456, 0))
        self.assertEqual(packet[32:], row * bridge.HEIGHT)

    def test_truncated_buffer_and_wrong_geometry_fail(self):
        for args in ((b"",1920,720,7680), (b"",1440,540,5760),
                     (b"",1920,720,1), (b"",1920,720,7680,-1)):
            with self.assertRaises(ValueError):
                bridge.frame_packet(*args)

    @unittest.skipUnless(sys.platform == "linux", "Requires distribution GStreamer")
    def test_real_gstreamer_produces_two_complete_bgra_frames(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--test-pattern", "--frames", "2"],
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        remaining = result.stdout
        for _ in range(2):
            length, = struct.unpack_from("<I", remaining)
            frame, remaining = remaining[4:4+length], remaining[4+length:]
            magic, w, h, stamp, epoch = struct.unpack_from("<4sIIQQ", frame)
            self.assertEqual((magic,w,h,epoch),(b"BGR2",1920,720,0))
            self.assertGreater(stamp, 1_000_000)
            self.assertEqual(len(frame), 28 + w*h*4)
            self.assertGreater(len(set(frame[28:])), 4)
        self.assertEqual(remaining, b"")


if __name__ == "__main__":
    unittest.main()
