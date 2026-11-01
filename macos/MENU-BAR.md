# MSI Xpander menu-bar app

The native AppKit menu controls the shared bulk display. The app bundles its
Python runtime, Pillow, USB driver, capture helper and hardware PNG-to-JPEG
encoder. People installing the built app do not need Cargo, Xcode or Python.
This build targets Apple Silicon on macOS 26 or later, matching the bundled
Homebrew Python runtime; the minimum OS in the app metadata reflects that limit.

## Use

Drag `MSI Xpander.app` from the disk image to Applications and open it. Use the
display icon in the menu bar to choose Kiosk, extended desktop or stop output.
Desktop update frequency offers 30 or 60 updates per second; JPEG quality is
separate for the desktop and kiosk. The live test window is off by default and
is available under the test-options submenu.

The first desktop session needs Screen Recording permission for **MSI Xpander**,
the responsible menu app. The permission menu opens the system privacy pane;
only the user changes that permission. Kiosk has no screen-capture requirement.

Kiosk takes a user-configured command which writes a 1920×720 PNG to stdout.
Existing kiosk configuration is migrated. New installations start stopped until
a source is configured; extended desktop can be used independently of a source.
Configuration, preferences, runtime frames and logs stay in the user's Library,
outside the signed bundle. No source command or private frames are packaged.

Selecting Stop is remembered. Quitting stops output but remembers the previous
mode, which is restored on reopening. Only the menu app is registered at login;
the kiosk job is bootstrapped on demand, so a stopped preference is respected.
The controller serializes handoffs and will not start a second USB owner before
the first has stopped. Failed desktop startup returns to kiosk if a source exists.

## Build and install locally

```sh
bash Build-Menu-Bar.command
bash Install-Menu-Bar.command
# Optional DMG and ZIP:
bash Package-Menu-Bar.command
```

Build dependencies are Cargo, Xcode command-line tools and a supported build
Python. The isolated freezer environment and pinned requirements are described
by `macos/freeze_controller.sh` and `macos/requirements-packaging.txt`.

Local builds create one code-signing-only certificate/private key in the user's
keychain. Temporary import key material is removed, and private signing material
is never bundled or committed. The actual designated requirement pins the app's
identifier and that certificate, so code changes do not change its identity.
Each nested helper keeps its own identifier; signing does not use `--deep`.
No TCC database or system-wide trust configuration is changed.

These are local development packages. For general public distribution, set
`MSI_SIGN_IDENTITY` to an appropriate Developer ID Application identity and
notarize/staple the disk image using the distributor's Apple credentials.
Local signing is not represented as Developer ID notarization.

The installed app is `~/Applications/MSI Xpander.app` when using the local
installer. A companion capture app retains the stable identifier
`com.digiter.msixpander.desktop`. The installer backs up prior kiosk settings
before migration and preserves the user's login preference on updates.
