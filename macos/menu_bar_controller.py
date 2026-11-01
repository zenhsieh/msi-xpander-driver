#!/usr/bin/env python3
"""Local menu-bar controller. JSON over stdout; no USB or GUI code here."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

RESOURCES = (Path(sys.executable).resolve().parent.parent if getattr(sys, "frozen", False)
             else Path(__file__).resolve().parent)
SUPPORT = Path.home() / "Library/Application Support/digiter-xpander-kiosk"
LOGS = Path.home() / "Library/Logs/digiter-xpander-kiosk"
CONFIG = SUPPORT / "app-config.json"
PREFS = SUPPORT / "menu-preferences.json"
STATE = SUPPORT / "menu-state.json"
LABEL = "com.digiter.xpander-kiosk"
MENU_LABEL = "com.digiter.xpander-menu"
DEFAULTS = {"desktop_fps": 60, "desktop_quality": 0.75, "kiosk_quality": 1.0, "test_window": False}


def read_json(path, default):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else default.copy()
    except (OSError, ValueError):
        return default.copy()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    os.replace(temporary, path)


def run(argv, **kwargs):
    return subprocess.run(argv, capture_output=True, text=True, timeout=15, **kwargs)


def service_info():
    result = run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{LABEL}"])
    if result.returncode:
        return None
    match = re.search(r"^\s*pid = (\d+)$", result.stdout, re.M)
    return {"pid": int(match[1]) if match else None, "running": "state = running" in result.stdout}


def process_identity(pid):
    if not isinstance(pid, int) or pid <= 1:
        return None
    result = run(["/bin/ps", "-ww", "-p", str(pid), "-o", "lstart=,command="])
    return result.stdout.strip() if result.returncode == 0 else None


def desktop_alive(state):
    identity = process_identity(state.get("desktop_pid"))
    return bool(identity and identity == state.get("desktop_identity"))


def paths(config):
    return Path(config.get("resources_path", str(RESOURCES))) / "bin" / "msi-xpander"


def status():
    prefs = {**DEFAULTS, **read_json(PREFS, {})}
    state = read_json(STATE, {})
    config = read_json(CONFIG, {})
    desktop = desktop_alive(state)
    service = service_info()
    kiosk = bool(service and service.get("running") and service.get("pid")
                 and process_identity(service["pid"]))
    mode = state.get("producer_mode", "desktop") if desktop else "kiosk" if kiosk else "stopped"
    error = state.get("last_error", "")
    if state.get("desktop_pid") and not desktop and not service and not error:
        error = "延伸桌面程序已結束，請查看日誌或重新啟動輸出。"
    return {"ok": True, "mode": mode, **prefs, "last_error": error,
            "launch_at_login": (Path.home() / "Library/LaunchAgents" / f"{MENU_LABEL}.plist").exists(),
            "logs_path": str(LOGS), "configured": bool(config.get("frame_cmd")),
            "source_cmd": config.get("frame_cmd", "")}


def save_state(**values):
    write_json(STATE, {**read_json(STATE, {}), **values})


def stop_desktop():
    state = read_json(STATE, {})
    if desktop_alive(state):
        pid = state["desktop_pid"]
        # Only the session group we created, with an unchanged process identity.
        if os.getpgid(pid) != pid:
            raise RuntimeError("無法確認延伸桌面程序的擁有者，已停止切換。")
        for sig, duration in ((signal.SIGINT, 5), (signal.SIGTERM, 3)):
            try:
                os.killpg(pid, sig)
            except ProcessLookupError:
                break
            until = time.monotonic() + duration
            while desktop_alive(state) and time.monotonic() < until:
                time.sleep(0.1)
            if not desktop_alive(state):
                break
        if desktop_alive(state):
            raise RuntimeError("延伸桌面尚未停止，未啟動另一個輸出程序。")
    save_state(desktop_pid=None, desktop_identity=None)


def stop_kiosk():
    existing = service_info()
    if not existing:
        return
    result = run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"])
    if result.returncode and service_info():
        raise RuntimeError("無法停止 Kiosk，未啟動另一個輸出程序。")
    until = time.monotonic() + 10
    while time.monotonic() < until:
        if not service_info() and not process_identity(existing.get("pid")):
            return
        time.sleep(0.1)
    raise RuntimeError("Kiosk 尚未停止，請稍後再試。")


def start_kiosk(remember=True):
    config = read_json(CONFIG, {})
    if not config.get("frame_cmd"):
        raise RuntimeError("尚未設定 Kiosk 畫面來源，請開啟設定檔。")
    stop_desktop()
    existing = service_info()
    if existing and not existing.get("running"):
        stop_kiosk()
    if not service_info():
        target = f"gui/{os.getuid()}/{LABEL}"
        run(["/bin/launchctl", "enable", target])
        plist = Path(config.get("kiosk_plist", Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"))
        result = run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)])
        if result.returncode:
            raise RuntimeError("Kiosk 啟動失敗，請查看日誌。")
    until = time.monotonic() + 8
    while time.monotonic() < until:
        running = service_info()
        if running and running.get("running") and running.get("pid"):
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("Kiosk 未能啟動，請查看日誌。")
    save_state(mode="kiosk", last_error="", **({"resume_mode": "kiosk"} if remember else {}))


def blank_panel():
    config = read_json(CONFIG, {})
    result = subprocess.run([str(paths(config)), "blank"], capture_output=True, text=True, timeout=35)
    if result.returncode:
        raise RuntimeError("輸出已停止，但未能送出黑畫面，請查看日誌。")


def start_desktop(mode="desktop"):
    config = read_json(CONFIG, {})
    driver = paths(config)
    native = mode in ("native-kiosk", "screensaver")
    helper = (Path(config.get("resources_path", str(RESOURCES))) / "bin/NativeKioskRenderer"
              if native else Path(config.get("desktop_helper", "")))
    if not driver.is_file() or not helper.is_file():
        raise RuntimeError("桌面元件不完整，請重新安裝 App。")
    save_state(resume_mode=mode)
    stop_desktop()
    stop_kiosk()
    prefs = {**DEFAULTS, **read_json(PREFS, {})}
    env = {**os.environ, "MSI_DESKTOP_TRANSPORT": "bulk", "MSI_BRIDGE_ENCODER": "vt",
           "MSI_DESKTOP_FPS": str(prefs["desktop_fps"]), "MSI_VT_QUALITY": str(prefs["desktop_quality"]),
           "MSI_DESKTOP_TEST_WINDOW": "1" if prefs["test_window"] else "0",
           "MSI_DESKTOP_MODE": "native", "MSI_VIRTUAL_COLOR_MODE": "system-default"}
    if native:
        env.update(MSI_NATIVE_KIOSK_STYLE=mode, MSI_VT_QUALITY=str(prefs["kiosk_quality"]),
                   MSI_DESKTOP_FPS="30" if mode == "screensaver" else "1")
    LOGS.mkdir(parents=True, exist_ok=True)
    process = None
    try:
        with (LOGS / "desktop.log").open("ab") as output:
            offset = output.tell()
            process = subprocess.Popen([str(driver), "desktop", str(helper)], env=env,
                                       stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                                       start_new_session=True)
        started = False
        until = time.monotonic() + 25
        while time.monotonic() < until and process.poll() is None:
            with (LOGS / "desktop.log").open("rb") as stream:
                stream.seek(offset)
                started = b"Live desktop:" in stream.read(128 * 1024)
            if started:
                break
            time.sleep(0.1)
        identity = process_identity(process.pid)
        if not started or process.poll() is not None or not identity:
            raise RuntimeError("延伸桌面啟動失敗；請確認螢幕錄製權限並查看日誌。")
    except Exception:
        if process and process.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    raise RuntimeError("桌面程序尚未停止，未啟動 Kiosk，請重新開啟 App。")
        with contextlib.suppress(Exception):
            start_kiosk(remember=False)
        raise
    save_state(mode=mode, producer_mode=mode, desktop_pid=process.pid, desktop_identity=identity, last_error="")


def serve_kiosk():
    config = read_json(CONFIG, {})
    if not config.get("frame_cmd"):
        raise RuntimeError("尚未設定 Kiosk 畫面來源。")
    prefs = {**DEFAULTS, **read_json(PREFS, {})}
    resources = Path(config.get("resources_path", str(RESOURCES)))
    # The clock/frame loop and its fonts are the existing frontend; only its USB
    # sender and encoder settings are selected here.
    env = {**os.environ, "MSI_KIOSK_TRANSPORT": "bulk", "MSI_KIOSK_ENCODER": "vt",
           "MSI_VT_QUALITY": str(prefs["kiosk_quality"]),
           "MSI_KIOSK_FRAME_PATH": str(SUPPORT / "runtime/kiosk/frame.png"),
           "MSI_KIOSK_VT_HELPER": str(resources / "bin/VTImageEncoder")}
    arguments = [config.get("python_path", sys.executable), "-u",
                 str(config.get("kiosk_script", SUPPORT / "runtime/kiosk/run_kiosk.py")), "--binary", str(paths(config)),
                 "--frame-cmd", config["frame_cmd"]]
    if config.get("clock", True):
        arguments.append("--clock")
    if getattr(sys, "frozen", False):
        import run_kiosk
        os.environ.update(env)
        run_kiosk.FRAME = SUPPORT / "runtime/kiosk/frame.png"
        run_kiosk.FRAME.parent.mkdir(parents=True, exist_ok=True)
        sys.argv = ["run_kiosk", *arguments[3:]]
        run_kiosk.main()
        return
    os.execvpe(arguments[0], arguments, env)


def set_preference(action, value):
    if action == "set-test-window":
        if value not in ("0", "1"):
            raise RuntimeError("測試視窗設定無效。")
        current = status()["mode"]
        prefs = {**DEFAULTS, **read_json(PREFS, {})}
        selected = value == "1"
        if prefs["test_window"] != selected:
            prefs["test_window"] = selected
            write_json(PREFS, prefs)
            if current == "desktop": start_desktop()
        return
    choices = {"set-desktop-fps": ("desktop_fps", (30, 60), int),
               "set-desktop-quality": ("desktop_quality", (0.75, 0.9, 1.0), float),
               "set-kiosk-quality": ("kiosk_quality", (0.75, 0.9, 1.0), float)}
    key, allowed, convert = choices[action]
    try:
        selected = convert(value)
    except (ValueError, TypeError):
        raise RuntimeError("設定值無效。")
    if selected not in allowed:
        raise RuntimeError("設定值不在支援範圍。")
    current = status()["mode"]
    prefs = {**DEFAULTS, **read_json(PREFS, {})}
    if prefs[key] == selected:
        return
    prefs[key] = selected
    write_json(PREFS, prefs)
    if current == "desktop" and key.startswith("desktop_"):
        start_desktop()
    elif current in ("native-kiosk", "screensaver") and key.startswith("kiosk_"):
        start_desktop(current)
    elif current == "kiosk" and key.startswith("kiosk_"):
        stop_kiosk()
        start_kiosk()


def set_login(value):
    import plistlib
    if value not in ("0", "1"):
        raise RuntimeError("登入啟動設定無效。")
    plist = Path.home() / "Library/LaunchAgents" / f"{MENU_LABEL}.plist"
    if value == "1":
        app = RESOURCES.parent.parent
        config = read_json(CONFIG, {})
        app = Path(config.get("app_path", str(app)))
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_bytes(plistlib.dumps({"Label": MENU_LABEL,
            "ProgramArguments": ["/usr/bin/open", "-g", str(app)], "RunAtLoad": True}))
    else:
        # This job just invokes open once; deleting its file disables next login.
        with contextlib.suppress(FileNotFoundError):
            plist.unlink()


@contextlib.contextmanager
def control_lock():
    SUPPORT.mkdir(parents=True, exist_ok=True)
    with (SUPPORT / "menu-controller.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("正在切換模式，請稍候。")
        try:
            yield
        except Exception as error:
            save_state(last_error=str(error) if isinstance(error, RuntimeError) else "操作失敗，請查看日誌。")
            raise


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    action = argv[0] if argv else "status"
    if getattr(sys, "frozen", False) and action == "resume":
        config = read_json(CONFIG, {})
        if config.get("resources_path") != str(RESOURCES):
            app = RESOURCES.parent.parent
            if str(app).startswith("/Volumes/"):
                raise RuntimeError("請先將 MSI Xpander 拖到應用程式資料夾，再開啟。")
            import install_menu_bar
            import io
            with contextlib.redirect_stdout(io.StringIO()):
                install_menu_bar.install(app, launch=False, inplace=True, manage_ui=False, start_output=False)
    if action == "serve-kiosk":
        serve_kiosk()
        return
    if action == "status":
        print(json.dumps(status(), ensure_ascii=False))
        return
    with control_lock():
        if action == "kiosk":
            start_kiosk()
        elif action in ("desktop", "native-kiosk", "screensaver"):
            start_desktop() if action == "desktop" else start_desktop(action)
        elif action == "stop":
            stop_desktop(); stop_kiosk(); save_state(mode="stopped", resume_mode="stopped", last_error="")
            blank_panel()
        elif action == "shutdown":
            current = status()["mode"]
            remembered = read_json(STATE, {}).get("resume_mode", current)
            stop_desktop(); stop_kiosk()
            save_state(mode="stopped", resume_mode=remembered, last_error="")
            if current != "stopped":
                blank_panel()
        elif action == "resume":
            remembered = read_json(STATE, {}).get("resume_mode", "kiosk")
            current = status()["mode"]
            if current != remembered:
                if remembered == "desktop": start_desktop()
                elif remembered in ("native-kiosk", "screensaver"): start_desktop(remembered)
                elif remembered == "kiosk": start_kiosk()
                elif remembered == "stopped":
                    stop_desktop(); stop_kiosk(); save_state(mode="stopped", last_error="")
            else:
                save_state(last_error="")
        elif action == "restart":
            current = status()["mode"]
            if current == "desktop":
                start_desktop()
            elif current in ("native-kiosk", "screensaver"):
                start_desktop(current)
            elif current == "kiosk":
                stop_kiosk(); start_kiosk()
        elif action == "set-frame-cmd":
            import shlex
            value = argv[1] if len(argv) > 1 else ""
            if not value.strip() or len(value) > 8192:
                raise RuntimeError("請輸入有效的 Kiosk 來源指令。")
            try:
                if not shlex.split(value): raise ValueError()
            except ValueError:
                raise RuntimeError("來源指令的引號不完整。")
            config = read_json(CONFIG, {}); config["frame_cmd"] = value
            write_json(CONFIG, config); CONFIG.chmod(0o600)
            if status()["mode"] == "kiosk": stop_kiosk(); start_kiosk()
        elif action.startswith("set-") and action != "set-login":
            if action not in ("set-desktop-fps", "set-desktop-quality", "set-kiosk-quality", "set-test-window"):
                raise RuntimeError("不支援的設定。")
            set_preference(action, argv[1] if len(argv) > 1 else None)
        elif action == "set-login":
            set_login(argv[1] if len(argv) > 1 else None)
        else:
            raise RuntimeError("不支援的操作。")
    print(json.dumps(status(), ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        message = str(error) if isinstance(error, RuntimeError) else "操作失敗，請查看日誌。"
        print(json.dumps({"ok": False, "last_error": message}, ensure_ascii=False))
        sys.exit(1)
