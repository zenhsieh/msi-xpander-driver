# GNOME Wayland driver

This backend uses the shared Rust USB authentication/JPEG bulk transport and a
GNOME Mutter virtual monitor captured through PipeWire. It is a userspace
driver; it does not install a DRM kernel module. The 1920×720 virtual monitor
extends the current GNOME desktop, with the pointer embedded in its frames.
It does not capture the user's physical monitors or inject input events.

Status: builds and passes tests in Debian Linux arm64, including actual
GStreamer synthetic capture. A physical Linux GNOME session and panel test is
still required. No claim of on-panel Linux success is made yet.

## Install

Run inside a logged-in **GNOME Wayland** session. A root shell, an ordinary SSH
shell, X11 and other compositors are not supported by this capture helper.
Mutter's ScreenCast interface is private and version dependent: availability
of `CreateSession`, `RecordVirtual`, and PipeWire is checked through actual calls.

Debian/Ubuntu dependencies (also install a current Rust toolchain):

```sh
sudo apt install build-essential pkg-config libudev-dev libusb-1.0-0-dev \
  python3-gi gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-pipewire
bash linux/install-user.sh
sudo install -m 644 linux/70-msi-xpander.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
# Replug the panel so both USB and hidraw access ACLs are assigned.
~/.local/bin/msi-xpander probe
~/.local/bin/msi-xpander show420
```

The udev rules grant access to the active local seat user, for this vendor and
the two recorded product IDs only. The rule precedes the seat ACL rule.
Linux automatically detaches a kernel driver only while claiming the validated
vendor bulk interface 0 and reattaches it on release. Keyboard HID interfaces
are never opened for mode switching.

## Extended desktop and kiosk

```sh
MSI_DESKTOP_FPS=30 ~/.local/bin/msi-xpander desktop
MSI_DESKTOP_FPS=60 ~/.local/bin/msi-xpander desktop
# From a development checkout, an explicit helper can also be supplied:
MSI_DESKTOP_FPS=30 target/release/msi-xpander desktop "$PWD/linux/gnome-bridge.py"

# A native-size PNG source can use the shared bulk kiosk path independently:
MSI_KIOSK_TRANSPORT=bulk target/release/msi-xpander kiosk frame.png
```

Bulk is the Linux desktop default; `MSI_DESKTOP_TRANSPORT=hid` remains an
explicit fallback. Initial JPEG encoding is CPU baseline 4:2:0 in the existing
Rust worker. There is no VideoToolbox on Linux, and Linux hardware JPEG is not
implemented by this change. Start with `MSI_DESKTOP_JPEG_QUALITY=85`; allowed
values are 20..95. The update setting is a ceiling, not a measured rate.

The bridge retains one latest frame, removes row padding, and sends the existing
timestamped BGR2 protocol to Rust. Rust validates geometry and encodes on a
separate worker. The first capture is read before USB is touched. The helper
fails after 20 seconds without a first frame, and closes its Mutter session
on termination; peer disconnect also lets Mutter destroy that virtual output.
GNOME chooses its placement; use GNOME Displays to arrange it as desired.

Ctrl-C stops capture and releases USB. The panel retains its last image;
this is not hardware power-off or a return to the factory dashboard.
Stop the current producer before starting another. No two senders may own USB.

## Tests without USB

```sh
docker build -f linux/Dockerfile.test -t msi-xpander-linux-test .
docker run --rm -v "$PWD:/src" msi-xpander-linux-test \
  bash -c 'cargo test --locked --features hardware && python3 -m unittest linux/test_bridge.py'
# In GNOME, capture a preview stream without touching USB:
linux/gnome-bridge.py --frames 2 > /tmp/xpander-gnome.frames
# GStreamer synthetic source works without a desktop:
linux/gnome-bridge.py --test-pattern --frames 2 > /tmp/xpander-test.frames
```

Frame files may contain private desktop content: keep actual captures local.
Only synthetic data and sanitized logs belong in public evidence.

API sources: [Mutter interface](https://github.com/GNOME/mutter/blob/gnome-48/data/dbus-interfaces/org.gnome.Mutter.ScreenCast.xml),
[GStreamer appsink](https://gstreamer.freedesktop.org/documentation/app/appsink.html),
[rusb interface ownership](https://docs.rs/rusb/0.9.4/rusb/struct.DeviceHandle.html#method.set_auto_detach_kernel_driver).
