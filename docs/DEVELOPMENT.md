# Developing InputBridge

User documentation lives in the [README](../README.md). This page covers building, releasing and how updates work.

## Building from source

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

Without signing secrets the macOS build is ad-hoc signed and meant for testing; the camera extension needs a Developer ID signed build. When the signing and notarization secrets are configured (see [docs/RELEASING_TR.md](RELEASING_TR.md)), the workflow signs, notarizes and staples the installer package and the DMG.

### Automatic updates

Both apps check `https://api.github.com/repos/ArdanucAKAR/InputBridge/releases/latest` 45 seconds after launch and every 6 hours. When the published release is newer than the running version, the app downloads its installer in the background and checks it against the SHA-256 digest that GitHub reports for the asset:

- **Windows** — the tray menu and *Updates* tab offer *Install and restart*. The Inno Setup installer runs silently (one UAC prompt), then relaunches InputBridge in the background.
- **macOS** — the menu bar and setup window offer *Install update and restart*. InputBridge quits, a helper swaps the app bundle in place and relaunches it. If the app is not in a writable folder (for example, it runs from the DMG), the DMG opens for a manual drag-and-drop.

Automatic install is opt-in in both apps; automatic checking can be turned off. Drafts are ignored, and pre-releases (tags such as `v0.3.0-beta.1`) are offered only when **Receive beta versions** is enabled. Beta builds turn that option on by default. Local development builds report version `0.0.0` and skip automatic checks. The updater relies on the asset names `InputBridge-Windows-Setup.exe` and `InputBridge-macOS.dmg`, so keep them unchanged.

Release and signing setup (Apple Developer account, GitHub secrets) is described in Turkish in [RELEASING_TR.md](RELEASING_TR.md). The local network protocol is documented in [shared/PROTOCOL.md](../shared/PROTOCOL.md).
