<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="InputBridge icon">
</p>

<h1 align="center">InputBridge</h1>

<p align="center">
  <b>One desk, two computers.</b><br>
  Move your monitors, speakers, keyboard and webcam between a Windows PC and a Mac with a single switch.
</p>

<p align="center">
  <a href="https://github.com/ArdanucAKAR/InputBridge/releases/latest"><img src="https://img.shields.io/github/v/release/ArdanucAKAR/InputBridge?label=latest&color=2f81f7" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078d4?logo=windows" alt="Windows 10 or 11">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://github.com/ArdanucAKAR/InputBridge/releases/latest/download/InputBridge-macOS.pkg"><b>Download for Mac</b></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/ArdanucAKAR/InputBridge/releases/latest/download/InputBridge-Windows-Setup.exe"><b>Download for Windows</b></a>
  &nbsp;·&nbsp;
  <a href="README_TR.md">Türkçe</a>
</p>

---

If your Windows PC and your Mac share the same monitors, speakers and keyboard, switching usually means pressing input buttons on every screen, changing the speaker source and re-pairing the keyboard. InputBridge does all of that for you: switch your Logitech keyboard to the Mac and the whole desk follows; switch it back and everything returns to Windows.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-menu-dark.png">
    <img src="docs/images/mac-menu.png" width="376" alt="InputBridge in the Mac menu bar, with the Mac profile active">
  </picture>
</p>

## What it switches

| | Windows profile | Mac profile |
|---|---|---|
| **Monitors** (DDC/CI) | Windows input | Mac input |
| **Logitech Z407 speakers** | AUX | Bluetooth |
| **Logitech G915 / G913 keyboard** | LIGHTSPEED receiver | Bluetooth |
| **USB webcam** plugged into the PC | Used by Windows apps | Available on the Mac as **InputBridge Camera** |

- **Automatic** — switching the keyboard's host is enough. You can also pick a profile from the Mac menu bar or the Windows tray.
- **Your webcam on both computers** — the camera stays plugged into the PC. On the Mac it shows up as *InputBridge Camera* in Zoom, Meet, Teams or FaceTime, and it only turns on while one of those apps is actually using it.
- **No setup files or IP addresses** — the Mac finds the PC on your network by itself, and you approve the pairing once on Windows.
- **Stays up to date** — both apps update themselves from GitHub Releases.

## Screenshots

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-settings-dark.png">
    <img src="docs/images/mac-settings.png" width="760" alt="Mac settings window showing the paired Windows PC">
  </picture>
  <br><sub>Mac settings: the Windows PC is found automatically and paired once.</sub>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mac-camera-dark.png">
    <img src="docs/images/mac-camera.png" width="620" alt="Camera settings on the Mac">
  </picture>
  <br><sub>InputBridge Camera brings the PC's webcam to the Mac and turns it on only when an app uses it.</sub>
</p>

## What you need

- A **Windows 10 or 11** PC and a **Mac with macOS 13 Ventura or later**, on the same home or office network.
- Monitors that support **DDC/CI** (most do; it may need to be turned on in the monitor's menu).
- Optional: **Logitech Z407** speakers, a **Logitech G915 / G913** keyboard paired with the PC's LIGHTSPEED receiver and with the Mac over Bluetooth, and a **USB webcam** plugged into the PC.

## Install

### 1. Windows

1. Download and run **[InputBridge-Windows-Setup.exe](https://github.com/ArdanucAKAR/InputBridge/releases/latest/download/InputBridge-Windows-Setup.exe)**.
2. InputBridge starts in the system tray. Open it and go to **Monitors**: tick the screens on your shared desk and choose which input each one uses for Windows and for the Mac (for example *DisplayPort 1* and *HDMI 1*).

### 2. Mac

1. Download and open **[InputBridge-macOS.pkg](https://github.com/ArdanucAKAR/InputBridge/releases/latest/download/InputBridge-macOS.pkg)**, then click **Continue** and **Install**. InputBridge opens by itself and lives in the menu bar.
2. Allow what macOS asks for, once:
   - **Bluetooth** — to talk to the keyboard and the speakers.
   - **Local network** — to find and talk to your PC.
   - **Camera** — so InputBridge can set up *InputBridge Camera*. It never turns a camera on by itself.
   - **InputBridge Camera** — in the window that appears, click **Open System Settings** and turn it on.
3. In **Settings… → Windows Controller**, your PC appears under *Discovered controllers*. Click **Pair**, then click **Approve** on the PC's **Pairing** page.

That's it. In Zoom, Meet or FaceTime, choose **InputBridge Camera** once.

## Everyday use

- **Switch the keyboard** to the Mac (Bluetooth) or back to the PC (LIGHTSPEED), and the monitors, speakers and camera follow.
- **Or pick a profile** — *Windows* or *Mac* in the Mac menu bar, or *Apply Windows / Mac profile* in the Windows tray menu.
- **Pause automation** with *Switch with keyboard* in the Mac menu if you want to move the keyboard without moving the rest of the desk.

## Troubleshooting

<details>
<summary><b>My PC does not appear under Discovered controllers</b></summary>

Make sure both computers are on the same network and that Windows treats it as a *Private* network (the installer only opens InputBridge's ports on private networks). If your router blocks discovery, enter the PC's IP address under *Manual connection* and click **Check address** — InputBridge remembers it.
</details>

<details>
<summary><b>InputBridge Camera is black or missing</b></summary>

- On the PC, open **Camera** and check that sharing is on and the right camera is selected.
- On the Mac, open **Settings… → Camera**. If it asks for camera access, click **Allow in System Settings…**, allow InputBridge, then quit and reopen InputBridge.
- The camera only streams while the Mac profile is active; on the Windows profile it stays with Windows apps.
</details>

<details>
<summary><b>A monitor does not switch</b></summary>

Turn on DDC/CI in the monitor's on-screen menu and check the input codes on the PC's **Monitors** page. Common values are `0x0F` (DisplayPort 1), `0x11` (HDMI 1) and `0x12` (HDMI 2).
</details>

## Privacy and security

- InputBridge only works on your local network; nothing goes through the internet except update checks against GitHub.
- A Mac can only control the PC after you approve its pairing on Windows. The pairing key is stored in the Mac's Keychain.
- The webcam stream goes directly from your PC to your Mac, and only while an app on the Mac is using InputBridge Camera.
- Do not expose the PC's InputBridge port to the internet. See [SECURITY.md](SECURITY.md).

## Contributing

Bug reports and pull requests are welcome. Building from source and the release process are described in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

[MIT](LICENSE)
