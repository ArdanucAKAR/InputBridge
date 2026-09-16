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
- `InputBridge-macOS.dmg`

```bash
git tag v0.2.0
git push origin v0.2.0
```

Unsigned macOS builds are intended for testing. Public macOS distribution should use Developer ID signing and notarization.

## Security

InputBridge is intended for a trusted private network. Do not expose the Windows controller port to the public internet. See [SECURITY.md](SECURITY.md).

## License

MIT.
