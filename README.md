# HyperSwitch

**English** | [简体中文](README.zh-CN.md)

A keyboard-first app and window switcher for macOS. Hold a hotkey to browse running apps or windows with live thumbnails, then release to switch — similar in spirit to classic app switchers, rebuilt natively for current macOS.

HyperSwitch is a menu-bar (agent) app: no Dock tile of its own by default, runs in the background, and opens Settings from the menu-bar icon.

| | |
|---|---|
| **Version** | 1.0.0 |
| **Platform** | macOS 26.0+, Apple Silicon (`arm64`) |
| **Bundle ID** | `com.hyperswitch.HyperSwitch` |
| **Languages** | English, Simplified Chinese |
| **License** | [MIT](LICENSE) |

---

## Features

### App & window switcher
- Global hotkeys to open an app switcher or window switcher
- Live thumbnails (with Screen Recording) and optional full-size preview
- Search, arrow-key navigation, Return to activate, Escape to cancel
- Space / desktop indicators for off-Space windows
- Configurable delay, thumbnail size, appearance, and interaction options

### Settings
- **General** — launch at login, language, presence / menu-bar behaviour
- **App Switcher** — hotkeys, delay calibration, include filters
- **Interaction** — keyboard and pointer behaviour while the switcher is open
- **Appearance** — theme, colours, layout
- **About** — version and permission status

---

## Requirements

- **macOS 26.0** or later
- **Apple Silicon** Mac
- **Xcode** with command-line tools (to build from source)
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen` locally)

### Permissions

| Permission | Required? | Purpose |
|---|---|---|
| **Accessibility** | Yes | Event tap, raise windows, drive the switcher |
| **Screen Recording** | Optional | Live thumbnails and window titles |

Grant both in **System Settings → Privacy & Security**. Without Accessibility, HyperSwitch cannot operate.

---

## Install (from source)

```bash
# Optional but recommended: stable local signing so permissions survive rebuilds
./scripts/setup-signing.sh

# Debug build → /Applications/HyperSwitch.app
./scripts/build.sh

# Release build
CONFIG=Release ./scripts/build.sh

# Always launch via Launch Services
open /Applications/HyperSwitch.app
```

> **Important:** Do not run the binary from a shell. That inherits the *terminal’s* TCC grants, so permissions will look granted when they are not.

### Release package (DMG)

```bash
./scripts/release.sh
```

Produces `dist/HyperSwitch.dmg`. With a **Developer ID Application** certificate and Notary credentials (`HyperSwitchNotary` profile), the script also signs and notarizes. Otherwise it keeps a local / ad-hoc signature.

Pushes to `main` run GitHub Actions, which publish the same DMG on [Releases](../../releases). CI builds are typically **ad-hoc signed**. After downloading a DMG from a browser or AirDrop, clear quarantine if Gatekeeper blocks it:

```bash
xattr -d com.apple.quarantine /path/to/HyperSwitch.dmg
```

Then open the disk image and drag HyperSwitch into Applications.

### App icon

```bash
swift scripts/make-icon.swift /tmp
# copy PNGs into Sources/HyperSwitch/Resources/Assets.xcassets/AppIcon.appiconset/
```

---

## Usage

1. Install and open HyperSwitch.
2. Grant **Accessibility** (and optionally **Screen Recording**).
3. Use the configured hotkeys to open the switcher; navigate and release (or press Return) to switch.
4. Open Settings from the menu-bar icon.

---

## Project layout

```
hyperswitch/
├── project.yml                 # XcodeGen project definition
├── scripts/
│   ├── build.sh                # Generate project, build, install, sign
│   ├── release.sh              # Release build + DMG (+ optional notarize)
│   ├── setup-signing.sh        # Local self-signed identity for stable TCC
│   ├── make-icon.swift         # Generate iconset
│   ├── extract-strings.py      # Report missing / stale localisation keys
│   └── write-translations.py   # Regenerate Localizable.xcstrings
├── Sources/HyperSwitch/
│   ├── App/                    # Entry, status item, presence
│   ├── Core/                   # Preferences, permissions, localisation
│   ├── Settings/               # Settings panes
│   ├── Switcher/               # Switcher UI, hotkeys, model
│   ├── System/                 # AX, CGS, key codes
│   ├── Thumbnails/             # ScreenCaptureKit thumbnails
│   ├── Windows/                # Window index and actions
│   └── Resources/              # Info.plist, entitlements, assets, strings
└── Tests/HyperSwitchTests/
```

`HyperSwitch.xcodeproj/`, `.build/`, and `dist/` are generated and gitignored.

---

## Development

```bash
xcodegen generate
./scripts/build.sh
open HyperSwitch.xcodeproj
```

### Notes

- **App Sandbox is off** — required for Accessibility against other apps.
- **Signing:** `build.sh` prefers “HyperSwitch Local Signing” from `setup-signing.sh`, else ad-hoc.
- **Swift 6**, default actor isolation `MainActor`, strict concurrency.
- Interface language can follow the system or force English / Simplified Chinese.

### Localisation helpers

```bash
scripts/extract-strings.py          # missing / stale keys
scripts/write-translations.py       # rewrite Localizable.xcstrings from the table
```

---

## Uninstall

1. Quit HyperSwitch from the menu-bar icon.
2. `rm -rf /Applications/HyperSwitch.app`
3. Optional: `defaults delete com.hyperswitch.HyperSwitch 2>/dev/null || true`

---

## License

This project is licensed under the [MIT License](LICENSE).
