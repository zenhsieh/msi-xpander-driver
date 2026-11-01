#!/bin/bash
# Freeze the Python/Pillow controller; no app installation or service changes.
set -euo pipefail

cd -- "$(dirname -- "$0")/.."
root="$PWD"
prepare_only=false
case "${1:-}" in
    "") ;;
    --prepare-only) prepare_only=true ;;
    *) echo "Usage: bash macos/freeze_controller.sh [--prepare-only]" >&2; exit 2 ;;
esac
[ "$(uname -s)" = Darwin ] || { echo "Build the controller on macOS." >&2; exit 1; }

build_python="${MSI_PACKAGING_PYTHON:-/opt/homebrew/bin/python3}"
if [ ! -x "$build_python" ]; then
    echo "Set MSI_PACKAGING_PYTHON to a Python >= 3.10 executable on the build Mac." >&2
    exit 1
fi
"$build_python" -c 'import sys; assert (3,10) <= sys.version_info[:2] < (3,16), "Packaging requires Python 3.10–3.15"'
venv="$root/target/packaging-venv"
mkdir -p "$root/target"
if [ ! -x "$venv/bin/python" ]; then
    "$build_python" -m venv "$venv"
fi
python="$venv/bin/python"
"$python" -m pip install --disable-pip-version-check --no-input --only-binary=:all: \
    --index-url https://pypi.org/simple -r "$root/macos/requirements-packaging.txt"
"$python" -m pip check

if $prepare_only; then
    "$python" -c 'import platform,sys,PyInstaller,PIL; print("Packaging environment:",sys.version.split()[0],platform.machine(),"PyInstaller="+PyInstaller.__version__,"Pillow="+PIL.__version__)'
    exit 0
fi

: "${MSI_SIGN_IDENTITY:?Set MSI_SIGN_IDENTITY to the identity used for the surrounding app}"
for input in macos/menu_bar_controller.py macos/install_menu_bar.py kiosk/run_kiosk.py; do
    [ -f "$input" ] || { echo "Missing controller input: $input" >&2; exit 1; }
done

# Snapshot source/dependency identities before analysis, not after compilation.
# A concurrent source edit must invalidate the result instead of receiving a
# misleading provenance record for code that was not actually frozen.
input_state="$root/target/controller-freeze-inputs-$$.json"
trap 'rm -f "$input_state"' EXIT
"$python" - "$root" "$input_state" <<'PY'
import hashlib
import importlib.metadata
import json
import os
import platform
from pathlib import Path
import sys
root, destination = map(Path, sys.argv[1:])
sources = ["macos/menu_bar_controller.py", "macos/install_menu_bar.py",
           "kiosk/run_kiosk.py", "macos/freeze_controller.sh", "macos/requirements-packaging.txt",
           "macos/controller-entitlements.plist"]
destination.write_text(json.dumps({
    "source_sha256": {name: hashlib.sha256((root/name).read_bytes()).hexdigest() for name in sources},
    "build_dependencies": {name: importlib.metadata.version(name) for name in
                           ("PyInstaller", "Pillow", "pyinstaller-hooks-contrib", "altgraph", "macholib", "packaging", "setuptools")},
    "python": platform.python_version(),
    "architecture": platform.machine(),
    "signing_identity": os.environ["MSI_SIGN_IDENTITY"],
}, indent=2)+"\n")
PY

"$python" -m PyInstaller --noconfirm --clean --onedir --console --noupx \
    --name XpanderController \
    --distpath "$root/target/frozen" \
    --workpath "$root/target/pyinstaller-work" \
    --specpath "$root/target/pyinstaller-spec" \
    --paths "$root/kiosk" --paths "$root/macos" \
    --hidden-import run_kiosk --hidden-import install_menu_bar \
    --hidden-import PIL.Image --hidden-import PIL.ImageDraw --hidden-import PIL.ImageFont \
    --hidden-import PIL.PngImagePlugin --hidden-import PIL.JpegImagePlugin \
    --collect-submodules PIL --collect-data PIL --copy-metadata Pillow \
    --exclude-module tkinter --exclude-module _tkinter \
    --codesign-identity "$MSI_SIGN_IDENTITY" \
    --osx-entitlements-file "$root/macos/controller-entitlements.plist" \
    --osx-bundle-identifier com.digiter.msixpander.controller \
    "$root/macos/menu_bar_controller.py"

bundle="$root/target/frozen/XpanderController"
"$python" - "$root" "$bundle" "$input_state" <<'PY'
import hashlib
import importlib.metadata
import json
import platform
from pathlib import Path
import subprocess
import sys

root, bundle, input_state = map(Path, sys.argv[1:])
before = json.loads(input_state.read_text())
after_hashes = {name: hashlib.sha256((root/name).read_bytes()).hexdigest() for name in before["source_sha256"]}
if after_hashes != before["source_sha256"]:
    changed = [name for name in after_hashes if after_hashes[name] != before["source_sha256"][name]]
    raise SystemExit("Controller sources changed during freezing; rerun the build: " + ", ".join(changed))
after_dependencies = {name: importlib.metadata.version(name) for name in before["build_dependencies"]}
if after_dependencies != before["build_dependencies"]:
    raise SystemExit("Packaging dependencies changed during freezing; rerun the build")
# PyInstaller processes framework dylibs in its cache as standalone Mach-O files.
# Once collected into a .framework, they need the bundle's Info.plist/resource
# seal signed at the final framework root as well. Sign nested frameworks first.
frameworks = sorted((path for path in bundle.rglob("*.framework")
                     if path.is_dir() and not path.is_symlink()),
                    key=lambda path: len(path.parts), reverse=True)
for framework in frameworks:
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", before["signing_identity"],
                    "--options", "runtime", str(framework)], check=True)
# Verify every collected Mach-O, including embedded Python/Pillow libraries.
# PyInstaller signs these with the supplied identity; no signing key is copied.
checked = []
verified_targets = set()
for path in sorted(bundle.rglob("*")):
    if not path.is_file() or path.is_symlink():
        continue
    kind = subprocess.check_output(["/usr/bin/file", "-b", str(path)], text=True)
    if "Mach-O" in kind:
        # A framework's main executable is verified as part of its code bundle;
        # verifying that file as a standalone dylib loses the resource context.
        target = path
        for framework in frameworks:
            if path.is_relative_to(framework) and path.name == framework.stem:
                target = framework
                break
        if target not in verified_targets:
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(target)], check=True)
            verified_targets.add(target)
        checked.append(str(path.relative_to(bundle)))
if not checked:
    raise SystemExit("Frozen controller contains no Mach-O executable")

# Static signature verification does not prove the hardened executable can load
# its embedded Python. Exercise only read-only status, never resume/install.
smoke = subprocess.run([str(bundle/"XpanderController"), "status"],
                       capture_output=True, text=True, timeout=30)
if smoke.returncode:
    (root/"target/controller-status.stderr").write_text(smoke.stderr)
    raise SystemExit(f"Frozen controller status failed with exit {smoke.returncode}; inspect target/controller-status.stderr")
status = json.loads(smoke.stdout)
if not isinstance(status, dict) or status.get("ok") is not True:
    raise SystemExit("Frozen controller status returned an invalid result")
# Status may contain a private source command; retain only these public fields.
public_status = {name: status.get(name) for name in
                 ("ok", "mode", "desktop_fps", "desktop_quality", "kiosk_quality", "test_window", "configured")}

metadata = {
    "format": "PyInstaller onedir",
    "executable": "XpanderController",
    "python": platform.python_version(),
    "architecture": platform.machine(),
    "build_dependencies": before["build_dependencies"],
    "source_sha256": before["source_sha256"],
    "signing_identity": before["signing_identity"],
    "source_unchanged_during_freeze": True,
    "bundle_bytes_before_metadata": sum(path.stat().st_size for path in bundle.rglob("*") if path.is_file() and not path.is_symlink()),
    "verified_macho_count": len(checked),
    "verified_macho_files": checked,
    "resigned_frameworks": [str(path.relative_to(bundle)) for path in frameworks],
    "recipient_requires_python_install": False,
    "runtime_status_smoke": public_status,
}
(bundle/"build-provenance.json").write_text(json.dumps(metadata, indent=2)+"\n")
print(json.dumps({key: metadata[key] for key in
                  ("python", "architecture", "bundle_bytes_before_metadata", "verified_macho_count")}, indent=2))
PY
echo "Frozen controller: $bundle/XpanderController"
echo "Copy the complete $bundle directory into Contents/Resources/controller/."
