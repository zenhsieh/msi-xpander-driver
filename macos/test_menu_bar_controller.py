"""Controller handoff tests: isolated state, no launchd, USB or display actions."""
import fcntl
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("controller", Path(__file__).with_name("menu_bar_controller.py"))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        values = {"SUPPORT": self.root, "LOGS": self.root / "logs", "CONFIG": self.root / "config.json",
                  "PREFS": self.root / "prefs.json", "STATE": self.root / "state.json"}
        p = patch.multiple(c, **values); p.start(); self.addCleanup(p.stop)
        self.driver = self.root / "bin/msi-xpander"
        self.driver.parent.mkdir(); self.driver.touch()
        self.helper = self.root / "desktop-helper"; self.helper.touch()
        c.write_json(c.CONFIG, {"resources_path": str(self.root), "desktop_helper": str(self.helper),
                                "frame_cmd": "test-renderer --png"})

    def test_desktop_stops_kiosk_before_spawning_and_uses_hardware_bulk(self):
        events = []
        process = Mock(pid=43210); process.poll.return_value = None
        def spawn(*args, **kwargs):
            events.append("spawn")
            kwargs["stdout"].write(b"Live desktop: 1 frames\n"); kwargs["stdout"].flush()
            self.assertEqual(kwargs["env"]["MSI_DESKTOP_TRANSPORT"], "bulk")
            self.assertEqual(kwargs["env"]["MSI_BRIDGE_ENCODER"], "vt")
            self.assertEqual(kwargs["env"]["MSI_DESKTOP_TEST_WINDOW"], "0")
            return process
        with patch.object(c, "stop_desktop", side_effect=lambda: events.append("stop-desktop")), \
             patch.object(c, "stop_kiosk", side_effect=lambda: events.append("stop-kiosk")), \
             patch.object(c.subprocess, "Popen", side_effect=spawn), \
             patch.object(c, "process_identity", return_value="stable process identity"):
            c.start_desktop()
        self.assertEqual(events, ["stop-desktop", "stop-kiosk", "spawn"])
        self.assertEqual(c.read_json(c.STATE, {})["desktop_pid"], 43210)

    def test_desktop_failure_returns_to_kiosk(self):
        with patch.object(c, "stop_desktop"), patch.object(c, "stop_kiosk"), \
             patch.object(c.subprocess, "Popen", side_effect=OSError("fixture failure")), \
             patch.object(c, "start_kiosk") as restore:
            with self.assertRaises(OSError): c.start_desktop()
        restore.assert_called_once_with(remember=False)

    def test_stop_failure_never_starts_second_usb_owner(self):
        with patch.object(c, "stop_desktop"), \
             patch.object(c, "stop_kiosk", side_effect=RuntimeError("still stopping")), \
             patch.object(c.subprocess, "Popen") as spawn:
            with self.assertRaises(RuntimeError): c.start_desktop()
        spawn.assert_not_called()

    def test_reused_pid_is_not_signalled(self):
        c.write_json(c.STATE, {"desktop_pid": 43210, "desktop_identity": "old process"})
        with patch.object(c, "process_identity", return_value="different process"), \
             patch.object(c.os, "killpg") as kill:
            c.stop_desktop()
        kill.assert_not_called()

    def test_black_stop_happens_after_both_producers_exit(self):
        events = []
        with patch.object(c, "stop_desktop", side_effect=lambda: events.append("desktop-exit")), \
             patch.object(c, "stop_kiosk", side_effect=lambda: events.append("kiosk-exit")), \
             patch.object(c, "blank_panel", side_effect=lambda: events.append("black")), \
             patch.object(c, "status", return_value={"ok": True, "mode": "stopped"}):
            c.main(["stop"])
        self.assertEqual(events, ["desktop-exit", "kiosk-exit", "black"])
        self.assertEqual(c.read_json(c.STATE, {})["resume_mode"], "stopped")

    def test_native_modes_use_native_renderer_without_capture_helper(self):
        renderer = self.root / "bin/NativeKioskRenderer"; renderer.touch()
        for mode in ("native-kiosk", "screensaver"):
            process = Mock(pid=43210); process.poll.return_value = None
            def spawn(argv, **kwargs):
                self.assertEqual(argv[-1], str(renderer))
                self.assertEqual(kwargs["env"]["MSI_NATIVE_KIOSK_STYLE"], mode)
                self.assertEqual(kwargs["env"]["MSI_VT_QUALITY"], "1.0")
                kwargs["stdout"].write(b"Live desktop: 1 frames\n"); kwargs["stdout"].flush()
                return process
            with patch.object(c, "stop_desktop"), patch.object(c, "stop_kiosk"), \
                 patch.object(c.subprocess, "Popen", side_effect=spawn), \
                 patch.object(c, "process_identity", return_value="native producer"):
                c.start_desktop(mode)
            state = c.read_json(c.STATE, {})
            self.assertEqual(state["producer_mode"], mode)
            self.assertEqual(state["resume_mode"], mode)

    def test_native_mode_is_reported_and_restored(self):
        c.write_json(c.STATE, {"resume_mode": "screensaver", "producer_mode": "screensaver"})
        with patch.object(c, "desktop_alive", return_value=True), patch.object(c, "service_info", return_value=None):
            self.assertEqual(c.status()["mode"], "screensaver")
        with patch.object(c, "status", return_value={"ok": True, "mode": "stopped"}), \
             patch.object(c, "start_desktop") as start:
            c.main(["resume"])
        start.assert_called_once_with("screensaver")

    def test_invalid_preferences_have_no_side_effect(self):
        for action, value in (("set-desktop-fps", "120"), ("set-desktop-quality", "NaN"),
                              ("set-kiosk-quality", "0")):
            with self.subTest(action=action):
                with self.assertRaises(RuntimeError): c.set_preference(action, value)
        self.assertFalse(c.PREFS.exists())

    def test_serve_kiosk_keeps_mutable_frames_outside_signed_bundle(self):
        with patch.object(c.os, "execvpe") as execute:
            c.serve_kiosk()
        _, argv, env = execute.call_args.args
        self.assertIn(str(self.root / "runtime/kiosk/run_kiosk.py"), argv)
        self.assertEqual(env["MSI_KIOSK_ENCODER"], "vt")
        self.assertEqual(env["MSI_KIOSK_TRANSPORT"], "bulk")
        self.assertEqual(env["MSI_VT_QUALITY"], "1.0")

    def test_concurrent_control_action_is_rejected(self):
        with (self.root / "menu-controller.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(RuntimeError, "正在切換"):
                c.main(["stop"])
        self.assertFalse(c.STATE.exists())

    def test_shutdown_then_reopen_restores_previous_desktop_mode(self):
        c.write_json(c.STATE, {"resume_mode": "desktop"})
        with patch.object(c, "status", return_value={"ok": True, "mode": "desktop"}), \
             patch.object(c, "stop_desktop"), patch.object(c, "stop_kiosk"), patch.object(c, "blank_panel") as blank:
            c.main(["shutdown"])
        blank.assert_called_once()
        self.assertEqual(c.read_json(c.STATE, {})["resume_mode"], "desktop")
        with patch.object(c, "status", return_value={"ok": True, "mode": "stopped"}), \
             patch.object(c, "start_desktop") as restore:
            c.main(["resume"])
        restore.assert_called_once()

    def test_explicit_stop_is_remembered_on_reopen(self):
        with patch.object(c, "status", return_value={"ok": True, "mode": "stopped"}), \
             patch.object(c, "stop_desktop"), patch.object(c, "stop_kiosk"), \
             patch.object(c, "start_desktop") as desktop, patch.object(c, "start_kiosk") as kiosk:
            with patch.object(c, "blank_panel"):
                c.main(["stop"]); c.main(["resume"])
        desktop.assert_not_called(); kiosk.assert_not_called()

    def test_test_window_is_optional_and_restarts_only_active_desktop(self):
        self.assertFalse(c.DEFAULTS["test_window"])
        with patch.object(c, "status", return_value={"mode": "kiosk"}), \
             patch.object(c, "start_desktop") as desktop:
            c.set_preference("set-test-window", "1")
        desktop.assert_not_called()
        with patch.object(c, "status", return_value={"mode": "desktop"}), \
             patch.object(c, "start_desktop") as desktop:
            c.set_preference("set-test-window", "0")
        desktop.assert_called_once()

    def test_resume_stopped_reconciles_an_autoloaded_kiosk(self):
        c.write_json(c.STATE, {"resume_mode": "stopped"})
        with patch.object(c, "status", return_value={"mode": "kiosk"}), \
             patch.object(c, "stop_desktop") as desktop, patch.object(c, "stop_kiosk") as kiosk:
            c.main(["resume"])
        desktop.assert_called_once(); kiosk.assert_called_once()

    def test_registered_but_crashing_kiosk_is_not_reported_running(self):
        with patch.object(c, "desktop_alive", return_value=False), \
             patch.object(c, "service_info", return_value={"running": False, "pid": None}):
            self.assertEqual(c.status()["mode"], "stopped")


if __name__ == "__main__": unittest.main()
