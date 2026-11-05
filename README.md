# InputBridge

InputBridge is a two-client, local-network profile switcher for a Windows PC and a Mac.

The first built-in hardware profile:

- Detects whether a Logitech G915/G913 keyboard is connected to the Mac through Bluetooth.
- When the keyboard is connected to the Mac, applies the **Mac profile**:
  - Logitech Z407 source → Bluetooth
  - configured DDC/CI monitors → Mac input
  - optional USB webcam on Windows → InputBridge Camera on the Mac (1080p, no microphone)
- When the keyboard disconnects from the Mac (for example, LIGHTSPEED is selected), applies the **Windows profile**:
  - Logitech Z407 source → AUX
  - configured monitors → Windows input
  - Windows webcam capture stops so local Windows apps can use the camera

InputBridge uses local multicast discovery and a one-time, user-approved pairing flow. Users do not enter a controller IP address or copy tokens between machines.

## Components

- **Windows Controller** — a WPF tray app that exposes an authenticated local API, answers discovery requests, switches selected monitors through DDC/CI, and can publish a USB camera over the paired local stream.
- **macOS Companion** — a SwiftUI menu-bar app that detects the configured keyboard, controls Z407 through CoreBluetooth, discovers the Windows Controller, installs the InputBridge Camera extension, and stores pairing credentials in Keychain.

## Supported adapters in this release

| Adapter type | Built-in support |
|---|---|
| Trigger | Logitech G915/G913 Bluetooth connected/disconnected |
| BLE action | Logitech Z407 Bluetooth/AUX source switching |
| Display action | DDC/CI VCP `0x60` input switching |
| Keyboard action | G915/G913 LIGHTSPEED ↔ Bluetooth host switching (HID++ CHANGE_HOST) |
| Camera share | Windows USB webcam → Mac virtual camera (signed macOS build) |

See [README_TR.md](README_TR.md) for the Turkish setup guide and [docs/RELEASING_TR.md](docs/RELEASING_TR.md) for release instructions.

## Development

### Windows

```powershell
cd windows
./scripts/run-dev.ps1
```

Requires the .NET 8 SDK on Windows.

### macOS

```zsh
brew install xcodegen
cd macos
xcodegen generate
open InputBridgeMac.xcodeproj
```

Requires macOS 13+ and Xcode 15+.

## Distribution

A version tag triggers GitHub Actions to build:

- `InputBridge-Windows-Setup.exe`
- `InputBridge-macOS.pkg` (installer for new users)
- `InputBridge-macOS.dmg` (used by the in-app updater)

```bash
git tag v0.2.0
git push origin v0.2.0
```

Without signing secrets the macOS build is ad-hoc signed and meant for testing; the camera extension needs a Developer ID signed build. When the signing and notarization secrets are configured (see [docs/RELEASING_TR.md](docs/RELEASING_TR.md)), the workflow signs, notarizes and staples the installer package and the DMG.

### Automatic updates

Both apps check `https://api.github.com/repos/ArdanucAKAR/InputBridge/releases/latest` 45 seconds after launch and every 6 hours. When the published release is newer than the running version, the app downloads its installer in the background and checks it against the SHA-256 digest that GitHub reports for the asset:

- **Windows** — the tray menu and *Updates* tab offer *Install and restart*. The Inno Setup installer runs silently (one UAC prompt), then relaunches InputBridge in the background.
- **macOS** — the menu bar and setup window offer *Install update and restart*. InputBridge quits, a helper swaps the app bundle in place and relaunches it. If the app is not in a writable folder (for example, it runs from the DMG), the DMG opens for a manual drag-and-drop.

Automatic install is opt-in in both apps; automatic checking can be turned off. Drafts are ignored, and pre-releases (tags such as `v0.3.0-beta.1`) are offered only when **Receive beta versions** is enabled. Beta builds turn that option on by default. Local development builds report version `0.0.0` and skip automatic checks. The updater relies on the asset names `InputBridge-Windows-Setup.exe` and `InputBridge-macOS.dmg`, so keep them unchanged.

## Security

InputBridge is intended for a trusted private network. Do not expose the Windows controller port to the public internet. See [SECURITY.md](SECURITY.md).

## License

MIT.
