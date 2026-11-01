#!/usr/bin/env python3
"""Install the current user's local menu-bar app and migrate their kiosk job."""
import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys
import time


def env_value(path, name):
    if not path.is_file():
        return None
    for line in path.read_text().splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[7:]
        if line.startswith(name + "="):
            words = shlex.split(line.split("=", 1)[1], comments=True)
            return words[0] if len(words) == 1 else None
    return None


def install(source, frame_cmd=None, launch=True, inplace=False, manage_ui=True, start_output=True):
    if not importlib.util.find_spec("PIL"):
        raise RuntimeError("目前 Python 缺少 Pillow，請先安裝後再執行安裝程式。")
    home = Path.home()
    support = home / "Library/Application Support/digiter-xpander-kiosk"
    logs = home / "Library/Logs/digiter-xpander-kiosk"
    agents = home / "Library/LaunchAgents"
    app = source if inplace else home / "Applications/MSI Xpander.app"
    helper = home / "Applications/MSI Xpander Desktop.app"
    plist = agents / "com.digiter.xpander-kiosk.plist"
    config_file = support / "app-config.json"
    was_installed = config_file.exists()
    old = plistlib.loads(plist.read_bytes()) if plist.exists() else {}
    config = json.loads(config_file.read_text()) if config_file.exists() else {}
    working = Path(old.get("WorkingDirectory", str(home)))
    frame_cmd = frame_cmd or config.get("frame_cmd") or old.get("EnvironmentVariables", {}).get("KIOSK_FRAME_CMD")
    frame_cmd = frame_cmd or env_value(working / "kiosk/kiosk.env", "KIOSK_FRAME_CMD")
    frame_cmd = frame_cmd or env_value(working / "kiosk.env", "KIOSK_FRAME_CMD")
    frame_cmd = frame_cmd or ""
    resources = source / "Contents/Resources"
    for required in (source / "Contents/MacOS/MenuBarApp", resources / "bin/msi-xpander",
                     resources / "bin/VTImageEncoder", resources / "controller.py"):
        if not required.is_file():
            raise RuntimeError(f"App 元件不完整：{required}")
    for directory in (support, logs, agents, app.parent):
        directory.mkdir(parents=True, exist_ok=True)
    backup = support / ("before-menu-app-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    backup.mkdir()
    if plist.exists():
        shutil.copy2(plist, backup / plist.name)
    if config_file.exists():
        shutil.copy2(config_file, backup / config_file.name)
    # An update must quiesce both the UI and its output producer before any
    # executable is replaced. Keep the remembered mode for the new version.
    menu_binary = str(app / "Contents/MacOS/MenuBarApp")
    processes = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True)
    for line in processes.splitlines() if manage_ui else []:
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and (parts[1] == menu_binary or parts[1].startswith(menu_binary + " ")):
            try:
                os.kill(int(parts[0]), signal.SIGTERM)
            except ProcessLookupError:
                pass
    installed_controller = app / "Contents/Resources/controller.py"
    installed_binary = app / "Contents/Resources/controller/XpanderController"
    if manage_ui and (installed_binary.exists() or installed_controller.exists()):
        old_command = [str(installed_binary)] if installed_binary.exists() else [sys.executable, str(installed_controller)]
        stopped = subprocess.run([*old_command, "shutdown"],
                                 capture_output=True, text=True, timeout=30)
        if stopped.returncode:
            raise RuntimeError("目前輸出程序尚未停止，未替換 App。")
    # Stop the known kiosk job, and wait before replacing its resources.
    target = f"gui/{os.getuid()}/com.digiter.xpander-kiosk"
    existing = subprocess.run(["launchctl", "print", target], capture_output=True)
    if existing.returncode == 0:
        subprocess.run(["launchctl", "bootout", target], check=True)
        until = time.monotonic() + 10
        while subprocess.run(["launchctl", "print", target], capture_output=True).returncode == 0:
            if time.monotonic() >= until:
                raise RuntimeError("既有 Kiosk 尚未停止。")
            time.sleep(0.1)
    if source.resolve() != app.resolve():
        subprocess.run(["/usr/bin/ditto", str(source), str(app)], check=True)
    subprocess.run(["/usr/bin/ditto", str(app / "Contents/Helpers/MSI Xpander Desktop.app"), str(helper)], check=True)
    runtime = support / "runtime/kiosk"
    runtime.mkdir(parents=True, exist_ok=True)
    shutil.copy2(app / "Contents/Resources/kiosk/run_kiosk.py", runtime / "run_kiosk.py")
    # Frame state belongs outside the signed app bundle.
    if not (runtime / "frame.png").exists():
        previous = working / "kiosk/frame.png"
        if previous.exists():
            shutil.copy2(previous, runtime / "frame.png")
    installed_resources = app / "Contents/Resources"
    service_plist = support / "agents/com.digiter.xpander-kiosk.plist"
    service_plist.parent.mkdir(parents=True, exist_ok=True)
    config.update({"frame_cmd": frame_cmd, "clock": config.get("clock", True),
        "python_path": sys.executable, "app_path": str(app),
        "resources_path": str(installed_resources), "kiosk_script": str(runtime / "run_kiosk.py"),
        "desktop_helper": str(helper / "Contents/MacOS/MSIXpanderDesktop"),
        "kiosk_plist": str(service_plist)})
    config_file.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    config_file.chmod(0o600)
    controller = installed_resources / "controller.py"
    controller_binary = installed_resources / "controller/XpanderController"
    controller_command = [str(controller_binary)] if controller_binary.exists() else [sys.executable, str(controller)]
    data = {"Label": "com.digiter.xpander-kiosk", "ProgramArguments": [*controller_command, "serve-kiosk"],
        "WorkingDirectory": str(runtime), "EnvironmentVariables": {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
        "StandardOutPath": str(logs / "stdout.log"), "StandardErrorPath": str(logs / "stderr.log"),
        "ProcessType": "Background"}
    service_plist.write_bytes(plistlib.dumps(data))
    if plist.exists():
        # The menu app is the sole login coordinator; a stopped preference must
        # not be overridden by an independently autoloaded kiosk job at login.
        plist.unlink()
    if not was_installed:
        menu = {"Label": "com.digiter.xpander-menu", "ProgramArguments": ["/usr/bin/open", "-g", str(app)], "RunAtLoad": True}
        (agents / "com.digiter.xpander-menu.plist").write_bytes(plistlib.dumps(menu))
        if not frame_cmd:
            (support / "menu-state.json").write_text(json.dumps({"mode": "stopped", "resume_mode": "stopped"}) + "\n")
    if start_output:
        resumed = subprocess.run([*controller_command, "resume"])
        if resumed.returncode:
            print("App 已安裝；輸出恢復需要檢查權限，請從選單重新啟動。")
    if launch:
        subprocess.run(["/usr/bin/open", "-g", str(app)], check=True)
    print(f"Installed: {app}\nBackups: {backup}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--frame-cmd")
    parser.add_argument("--no-launch", action="store_true")
    args = parser.parse_args()
    install(args.app.resolve(), args.frame_cmd, not args.no_launch)
