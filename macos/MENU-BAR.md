# MSI Xpander menu-bar app

The native AppKit menu controls the shared bulk display. The app bundles its
Python runtime, Pillow, USB driver, capture helper and hardware PNG-to-JPEG
encoder. People installing the built app do not need Cargo, Xcode or Python.
This build targets Apple Silicon on macOS 26 or later, matching the bundled
Homebrew Python runtime; the minimum OS in the app metadata reflects that limit.

## Use

Drag `MSI Xpander.app` from the disk image to Applications and open it. The
menu-bar display icon has a **Display / 顯示** submenu with four modes:

- Kiosk: the configured PNG source, whether local or remote.
- Extended Desktop / 延伸桌面: an ordinary interactive macOS virtual desktop.
  Users choose whether to place apps or macOS desktop widgets there and use it
  as a kiosk. There is no separate native-kiosk mode. Add widgets using the
  desktop's Edit Widgets menu.
- Screen Saver / 螢幕保護模式: the native clock ScreenSaverView.
- Screen Off / 關閉螢幕: send black after producers stop, then release USB.
  USB power remains on.

The root menu contains status, Display, Settings, Tools, and Quit. Settings
contains the Kiosk source, update rate, quality, login preference and Language.
Tools contains widget help, test options, restart, permission help and logs.
The old native-kiosk selection is migrated to Extended Desktop without exposing
another mode. A legacy widget-display identity is retained if it was used, so
existing macOS widget layout is not discarded.

## Language

Settings → Language offers Follow System, 繁體中文 and English. Menu titles,
alerts, guidance and backend errors are localized. A language selection applies
immediately by rebuilding the menu, without restarting a virtual output or USB
producer. The screen saver can restart to update its date locale. Unsupported
system locales fall back to English. Per-app macOS language choices are honoured
when Follow System is selected. Screen-recording usage text has standard en and
zh-Hant InfoPlist localizations; macOS owns the language of System Settings and
system permission dialogs.

Saved errors remain canonical and are translated on output, so a prior Chinese
error can be shown in English after a language change. Native .strings catalogs
have matching keys/format arguments; the frozen controller includes its error
catalog. Neither language changes nor menu inspection allocate a virtual display.

## Mac following

Manual choices affect only the Xpander panel. The app follows Mac screensaver
start/stop and workspace screen/system sleep/wake notifications. Automatic modes
do not replace the user's selection: display/system sleep takes priority over
the screensaver, and the previous selected mode is restored after those states
end. A manually selected Off remains off after wake. Rapid notifications are
coalesced on the app's existing serial command queue. Wake is sampled again
once after three seconds so a settling capture/USB stack can be retried.
Screensaver Settings previews are ignored. Following concerns lifecycle, not
copying Apple's Aerial/video assets: the panel's saver is the native clock.

The first launch samples physical screen sleep state and submits a fresh system
state, replacing stale state from an earlier app run. The app does not preallocate
or retain a hidden virtual output: only Extended Desktop creates one,
and leaving them releases it. The known MSI physical-display flash issue remains
[open](https://github.com/zenhsieh/msi-xpander-driver/issues/1); 1280x480 also flashed,
so no unverified resolution workaround is shipped. The bridge no longer reads
or writes physical HDR preferences through undocumented SkyLight functions.

Quit blanks active output while retaining the selected mode for reopening.
Failure to deliver black is reported. Desktop update frequency offers 30 or
60 updates per second; JPEG quality is separate for the desktop and kiosk
modes. The live test window remains off by default. Tools → Use Widgets on the Desktop explains macOS widget setup.

Desktop sessions need Screen Recording permission for **MSI Xpander**,
the responsible menu app. The permission menu opens the system privacy pane;
only the user changes that permission. Remote Kiosk and the native clock saver have no screen-capture requirement.

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
