# Device Battery Indicators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show wireless device battery levels as per-device tray icons on Windows and as one menu-bar strip on macOS, with the G915 shared between the two machines.

**Architecture:** Each platform has pluggable battery sources (`IBatterySource` / `BatterySource`) feeding one aggregator that applies the visibility rules and merges the remote G915 reading. Windows listens on the LIGHTSPEED receivers (HID++ connection notifications + battery events) instead of polling; macOS reads connected devices every 5 minutes. Windows tray icons use `Shell_NotifyIcon` with stable GUIDs; macOS uses a second `NSStatusItem`.

**Tech Stack:** .NET 8 WPF + WinForms + ASP.NET Core minimal API, xUnit; Swift 5.9 / SwiftUI / AppKit / IOKit, XCTest via XcodeGen; GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-19-battery-indicators-design.md`

## Global Constraints

- Do not copy code from BatteryHub, Solaar or HeadsetControl (GPL). InputBridge stays MIT; write parsers and the voltage curve from protocol facts.
- App UI text is English, like the rest of the app.
- Low battery: `percent <= 15` is drawn red. Charging shows a charging mark.
- A disconnected device is hidden immediately; a connected device with no reading yet is not shown; an AirPods component without a value is not shown.
- The shared keyboard (the one matching the existing keyboard name pattern, default `G915|G913`) uses the fixed `deviceId` `"logitech-keyboard"` on both machines. Only readings with this id cross the network.
- A reading of the shared keyboard that came from the other machine is drawn faded ("remote").
- Windows: never ping sleeping receiver slots periodically. One startup scan is allowed; afterwards read only on link-established notifications, on battery events, and at most every 30 minutes for devices known to be online.
- Windows battery HID++ requests use software id `0x0C` (the keyboard switch keeps `0x0B`) and take the shared `HidppGate`; a profile switch must never wait more than one in-flight battery request.
- When enabling receiver notifications, read register `0x00` first and OR in only the wireless-notification bit; never clear flags another app (G HUB) set.
- macOS: no new permission prompts. If Input Monitoring is not granted, skip the G915 reading silently.
- Setting "Show battery levels" on both apps, default on: Windows `AppSettings.BatteryIndicatorsEnabled`, macOS `UserDefaults` key `battery-indicators-enabled`.
- macOS cannot be built on the Windows dev PC. Swift tasks are verified by the `ci.yml` workflow on `macos-14` (push the branch only with the user's OK) or on the user's Mac.

## Review Focus

- G HUB running at the same time: InputBridge must not break G HUB or be broken by it (shared receiver, notification flags). Test: in Task 3, `EnableWirelessNotifications_PreservesExistingFlags`.
- Keyboard sleeps / wakes repeatedly: the icon must disappear on link-lost and come back with a fresh value on link-established, without InputBridge waking it. Test: in Task 3, `Tracker_LinkLostHidesAndLinkEstablishedRequestsRead`.
- Explorer restarts (or the user signs in slowly): tray icons must come back. Test: manual check in Task 5 (kill `explorer.exe`); code handles `TaskbarCreated`.
- Mac paired controller offline / older controller without `/api/battery` (404): the Mac strip still shows local devices, no error spam. Test: in Task 9, `RemoteMerge_IgnoresMissingController`.
- macOS `system_profiler` output varies (no case value, extra keys, localized names): parser must not crash and must ignore not-connected devices. Test: in Task 7, `Profiler_IgnoresNotConnectedAndMissingCase`.

---

### Task 1: Windows test project, battery model and HID++ battery parsers

**Files:**
- Create: `windows/tests/InputBridge.Windows.Tests/InputBridge.Windows.Tests.csproj` (xUnit, `net8.0-windows10.0.19041.0`, `UseWPF`+`UseWindowsForms` true, ProjectReference to the app)
- Create: `windows/src/InputBridge.Windows/Core/Battery/BatteryModels.cs`
- Create: `windows/src/InputBridge.Windows/Core/Battery/HidppBattery.cs`
- Create: `windows/tests/InputBridge.Windows.Tests/HidppBatteryTests.cs`
- Create: `shared/fixtures/battery-readings.json` (API contract, used by Task 4 and Task 7)
- Create: `.github/workflows/ci.yml` (on `push` to any branch and `pull_request`: `windows-latest` → `dotnet test windows/tests/InputBridge.Windows.Tests`; the macOS job is added in Task 7)

**Interfaces:**
- Produces:
  - `enum DeviceKind { Keyboard, Mouse, Headset, Trackpad, Other }`
  - `enum ComponentRole { Main, Left, Right, Case }`
  - `sealed record BatteryComponent(ComponentRole Role, int Percent, bool Charging)`
  - `sealed record BatteryReading(string DeviceId, string Name, DeviceKind Kind, IReadOnlyList<BatteryComponent> Components, DateTimeOffset ReadAt, bool Remote = false)`
  - `static class BatteryIds { public const string SharedKeyboard = "logitech-keyboard"; }`
  - `static class HidppBattery` (namespace `InputBridge.Windows`, like the rest of the app):
    - `const ushort FeatureUnifiedBattery = 0x1004, FeatureBatteryStatus = 0x1000, FeatureBatteryVoltage = 0x1001;`
    - `BatteryComponent? ParseUnifiedStatus(ReadOnlySpan<byte> p, bool stateOfChargeSupported)` — `p` = get_status (fn 1) reply/event params `[soc, levelFlags, chargingStatus, externalPower]`
    - `bool ParseUnifiedCapabilities(ReadOnlySpan<byte> p)` — returns "state of charge supported" (`p[1] & 0x02`)
    - `BatteryComponent? ParseBatteryStatus(ReadOnlySpan<byte> p)` — `[level, nextLevel, status]`
    - `BatteryComponent? ParseVoltage(ReadOnlySpan<byte> p)` — `[mV hi, mV lo, flags]`
    - `int VoltageToPercent(int millivolts)`
    - `DeviceKind KindFromHidppType(byte deviceType)` — DEVICE_NAME (0x0005) fn 2 type: 0→Keyboard, 3→Mouse, 4→Trackpad, 8→Headset, else Other

- [ ] **Step 1: Write the failing tests** (`HidppBatteryTests`)

```csharp
[Fact] public void Unified_ReadsSocAndCharging() =>
    Assert.Equal(new BatteryComponent(ComponentRole.Main, 82, true), HidppBattery.ParseUnifiedStatus([0x52, 0x08, 0x01, 0x01], true));
[Fact] public void Unified_NotCharging() =>
    Assert.Equal(new BatteryComponent(ComponentRole.Main, 15, false), HidppBattery.ParseUnifiedStatus([0x0F, 0x02, 0x00, 0x00], true));
[Fact] public void Unified_ChargeCompleteIsFullNotCharging() =>
    Assert.Equal(new BatteryComponent(ComponentRole.Main, 100, false), HidppBattery.ParseUnifiedStatus([0x64, 0x08, 0x03, 0x01], true));
[Theory, InlineData(0x08, 100), InlineData(0x04, 60), InlineData(0x02, 20), InlineData(0x01, 5)]
public void Unified_LevelFlagsWhenNoSoc(byte flags, int pct) =>
    Assert.Equal(pct, HidppBattery.ParseUnifiedStatus([0x00, flags, 0x00, 0x00], false)!.Percent);
[Fact] public void Status_Discharging() =>
    Assert.Equal(new BatteryComponent(ComponentRole.Main, 50, false), HidppBattery.ParseBatteryStatus([0x32, 0x1E, 0x00]));
[Theory, InlineData(1), InlineData(2), InlineData(4)]
public void Status_ChargingCodes(byte s) => Assert.True(HidppBattery.ParseBatteryStatus([0x32, 0x1E, s])!.Charging);
[Fact] public void Status_FullIs100() => Assert.Equal(100, HidppBattery.ParseBatteryStatus([0x5A, 0x00, 0x03])!.Percent);
[Fact] public void Status_InvalidBatteryIsNull() => Assert.Null(HidppBattery.ParseBatteryStatus([0x32, 0x1E, 0x05]));
[Fact] public void Voltage_4000mVCharging() =>
    Assert.Equal(new BatteryComponent(ComponentRole.Main, 80, true), HidppBattery.ParseVoltage([0x0F, 0xA0, 0x80]));
[Fact] public void Voltage_3700mV() =>
    Assert.Equal(new BatteryComponent(ComponentRole.Main, 30, false), HidppBattery.ParseVoltage([0x0E, 0x74, 0x00]));
[Theory, InlineData(4300, 100), InlineData(4200, 100), InlineData(3725, 35), InlineData(3400, 0), InlineData(3000, 0)]
public void VoltageCurve(int mv, int pct) => Assert.Equal(pct, HidppBattery.VoltageToPercent(mv));
[Fact] public void ShortPayloadIsNull() => Assert.Null(HidppBattery.ParseVoltage([0x0F]));
```

- [ ] **Step 2: Run to verify they fail**

Run: `dotnet test windows/tests/InputBridge.Windows.Tests`
Expected: build error, `HidppBattery` not defined.

- [ ] **Step 3: Implement `BatteryModels.cs` and `HidppBattery.cs`**

Voltage curve (piecewise linear between points, clamped; generic 1-cell Li-ion, not taken from any project):

| mV | 4200 | 4100 | 4000 | 3900 | 3800 | 3750 | 3700 | 3650 | 3600 | 3500 | 3400 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| % | 100 | 90 | 80 | 65 | 50 | 40 | 30 | 20 | 10 | 5 | 0 |

Unified `chargingStatus`: 1 or 2 → charging; 3 → percent 100, not charging; 4 (error) → null. BatteryStatus `status`: 0 discharging, 1/2/4 charging, 3 → 100 not charging, ≥5 → null. Voltage flags: bit 7 → charging.

- [ ] **Step 4: Write `shared/fixtures/battery-readings.json`** — the exact camelCase JSON for one reading: `deviceId "logitech-keyboard"`, `name "G915 TKL"`, `kind "keyboard"`, one component `{ "role": "main", "percent": 82, "charging": false }`, `readAt "2026-11-19T10:00:00Z"`, wrapped as `{ "readings": [ ... ] }`. Enums serialize as lowercase strings. `remote` is not part of the wire format.

- [ ] **Step 5: Run tests** — `dotnet test windows/tests/InputBridge.Windows.Tests` → all PASS. Also `dotnet build windows/src/InputBridge.Windows -c Release` → 0 errors.

- [ ] **Step 6: Commit** — `git add windows/tests windows/src/InputBridge.Windows/Core/Battery shared/fixtures .github/workflows/ci.yml` · message `Add battery model and HID++ battery parsers`

---

### Task 2: Share the HID++ channel between the keyboard switch and battery reading

**Files:**
- Create: `windows/src/InputBridge.Windows/Core/Hidpp/HidppChannel.cs` (moved out of `LogitechKeyboard.cs`)
- Create: `windows/src/InputBridge.Windows/Core/Hidpp/HidNative.cs` (the `Native` class, now `internal static`)
- Create: `windows/src/InputBridge.Windows/Core/Hidpp/HidppGate.cs`
- Modify: `windows/src/InputBridge.Windows/Core/LogitechKeyboard.cs` (use the moved types; hold `HidppGate` for the whole locate+switch)
- Test: `windows/tests/InputBridge.Windows.Tests/HidppChannelMatchingTests.cs`

**Interfaces:**
- Produces:
  - `internal sealed class HidppChannel : IDisposable`
    - `static HidppChannel? TryOpen(string path, byte softwareId)`
    - `string Path { get; }`, `int ReportLength { get; }`
    - `event Action<byte[]>? ReportReceived` — every input report, any report id (short `0x10` on the short collection, long `0x11` on the long one)
    - `Task SendAsync(byte index, byte feature, byte function, byte[] parameters, CancellationToken token)` (long reports, as today)
    - `Task SendRawAsync(byte[] report, CancellationToken token)` (for short-report register access)
    - `Task<byte[]?> RequestAsync(byte index, byte feature, byte function, byte[] parameters, CancellationToken token)` (as today; matches only its own software id)
    - `Task<List<byte>> FindOnlineDevicesAsync(ushort feature, CancellationToken token)` (as today)
  - `internal static class HidppMatch { public static bool IsReplyTo(ReadOnlySpan<byte> report, byte index, byte feature, byte functionByte); public static bool IsErrorFor(...same...); }` — extracted from the matcher lambda so it is testable.
  - `internal static class HidppGate { public static SemaphoreSlim Instance { get; } }` (count 1)
  - `internal static class HidppReceivers { List<string> FindPaths(ushort usage); }` — `usage` `0x0001` short, `0x0002` long, page `0xFF00`, vendor `0x046D`.

- [ ] **Step 1: Failing tests** — `HidppMatch.IsReplyTo` true for `[0x11,0x01,0x05,0x1C,…]` with index 1, feature 5, functionByte `0x1C`; false when the software id differs (`0x1B`); `IsErrorFor` true for `[0x11,0x01,0xFF,0x05,0x1C,0x02]`; both false for a 4-byte report.
- [ ] **Step 2: Run** `dotnet test windows/tests/InputBridge.Windows.Tests` → FAIL (types missing).
- [ ] **Step 3: Move the code**, add `softwareId` and `ReportReceived`, keep `LogitechKeyboard` behaviour identical (still software id `0x0B`, still opens channels per call). Wrap `LocateAsync`+`SendAsync` in `HidppGate.Instance`.
- [ ] **Step 4: Run** tests → PASS; `dotnet build` → 0 errors.
- [ ] **Step 5: Manual check on this PC** — `./windows/scripts/run-dev.ps1`, Keyboard page → *Detect keyboard* shows `G915 TKL`. Applying the Mac profile still switches the keyboard (ask the user before switching, since it moves their keyboard).
- [ ] **Step 6: Commit** — `Extract HID++ channel for reuse by battery reading`

---

### Task 3: Windows Logitech battery source (event-driven)

**Files:**
- Create: `windows/src/InputBridge.Windows/Core/Battery/IBatterySource.cs`
- Create: `windows/src/InputBridge.Windows/Core/Battery/HidppReceiverNotifications.cs` (pure helpers)
- Create: `windows/src/InputBridge.Windows/Core/Battery/LogitechDeviceTracker.cs` (pure state machine)
- Create: `windows/src/InputBridge.Windows/Core/Battery/LogitechBatterySource.cs` (I/O)
- Modify: `windows/src/InputBridge.Windows/App.xaml.cs` (`--battery-dump` switch)
- Test: `windows/tests/InputBridge.Windows.Tests/LogitechTrackerTests.cs`

**Interfaces:**
- Consumes: `HidppChannel`, `HidppGate`, `HidppReceivers` (Task 2); `HidppBattery`, `BatteryReading` (Task 1).
- Produces:
  - `public interface IBatterySource : IAsyncDisposable { string Name { get; } IReadOnlyList<BatteryReading> Current { get; } event Action? Changed; Task StartAsync(CancellationToken token); }`
  - `static class HidppReceiverNotifications`
    - `(byte Index, bool Linked)? ParseConnection(ReadOnlySpan<byte> shortReport)` — `[0x10, index, 0x41, protocol, flags, wpidLo, wpidHi]`; `Linked = (flags & 0x40) == 0`
    - `byte[] ReadNotificationFlagsRequest()` → `[0x10,0xFF,0x81,0x00,0x00,0x00,0x00]`
    - `byte[] WriteNotificationFlagsRequest(ReadOnlySpan<byte> current)` → `[0x10,0xFF,0x80,0x00,current[0], (byte)(current[1] | 0x01), current[2]]`
    - `bool IsBatteryEvent(ReadOnlySpan<byte> longReport, byte batteryFeatureIndex)` — `report[2] == index && (report[3] & 0x0F) == 0`
  - `sealed class LogitechDeviceTracker` (one per receiver; no I/O)
    - `IReadOnlyList<byte> OnLinked(byte index)` → indexes that need a full read now
    - `void OnLinkLost(byte index)`
    - `void OnDeviceInfo(byte index, string name, DeviceKind kind, ushort batteryFeature, byte batteryFeatureIndex, bool socSupported)`
    - `void OnBattery(byte index, BatteryComponent component, DateTimeOffset at)`
    - `IReadOnlyList<byte> DueForRefresh(DateTimeOffset now)` — online devices last read ≥ 30 min ago
    - `IReadOnlyList<BatteryReading> Readings(Regex sharedKeyboardPattern)` — only linked devices with a reading; `DeviceId` = `BatteryIds.SharedKeyboard` when the name matches the pattern, else `"logitech:" + name`
  - `sealed class LogitechBatterySource : IBatterySource` — ctor `(Func<Regex> sharedKeyboardPattern)`

Behaviour of `LogitechBatterySource.StartAsync`: for each receiver open the short collection and the long collection with software id `0x0C`; read+write notification flags (wireless bit only); one startup `FindOnlineDevicesAsync(0x0005)` per long channel and treat each answer as `OnLinked`; for each index to read: under `HidppGate`, discover `0x0005` (name via fn 0/1, type via fn 2) then the first of `0x1004`/`0x1000`/`0x1001` the device supports, then read it (`0x1004`: fn 0 capabilities, fn 1 status; `0x1000`/`0x1001`: fn 0). Subscribe `ReportReceived`: `0x41` → tracker; battery events → `OnBattery`. A 1-minute timer calls `DueForRefresh`. Receiver unplug (`IOException`) drops that receiver's devices; device arrival is picked up by re-enumerating receivers on `WM_DEVICECHANGE` or every 5 minutes (builder's choice) — enumerating receivers never pings devices.

- [ ] **Step 1: Failing tests**

```csharp
[Fact] public void Connection_Linked() => Assert.Equal(((byte)1, true), HidppReceiverNotifications.ParseConnection([0x10,0x01,0x41,0x04,0x01,0x45,0x40]));
[Fact] public void Connection_LinkLost() => Assert.Equal(((byte)1, false), HidppReceiverNotifications.ParseConnection([0x10,0x01,0x41,0x04,0x41,0x45,0x40]));
[Fact] public void Connection_OtherSubIdIsNull() => Assert.Null(HidppReceiverNotifications.ParseConnection([0x10,0x01,0x40,0x04,0x01,0x45,0x40]));
[Fact] public void EnableWirelessNotifications_PreservesExistingFlags() =>
    Assert.Equal(new byte[]{0x10,0xFF,0x80,0x00,0x10,0x09,0x00}, HidppReceiverNotifications.WriteNotificationFlagsRequest([0x10,0x08,0x00]));
[Fact] public void BatteryEvent_SoftwareIdZero() { Assert.True(HidppReceiverNotifications.IsBatteryEvent([0x11,0x01,0x06,0x00,0x52], 6)); Assert.False(HidppReceiverNotifications.IsBatteryEvent([0x11,0x01,0x06,0x1C,0x52], 6)); }
[Fact] public void Tracker_LinkLostHidesAndLinkEstablishedRequestsRead()
{
    var t = new LogitechDeviceTracker(); var now = DateTimeOffset.UtcNow; var kb = new Regex("G915");
    Assert.Equal([(byte)1], t.OnLinked(1));
    t.OnDeviceInfo(1, "G915 TKL", DeviceKind.Keyboard, 0x1001, 6, false);
    t.OnBattery(1, new(ComponentRole.Main, 80, false), now);
    Assert.Equal(BatteryIds.SharedKeyboard, Assert.Single(t.Readings(kb)).DeviceId);
    t.OnLinkLost(1);
    Assert.Empty(t.Readings(kb));
    Assert.Equal([(byte)1], t.OnLinked(1));      // fresh read on wake
    Assert.Empty(t.Readings(kb));                 // nothing shown until the new value arrives
}
[Fact] public void Tracker_RefreshOnlyOnlineAfter30Min()
{
    var t = new LogitechDeviceTracker(); var t0 = DateTimeOffset.UtcNow;
    t.OnLinked(1); t.OnDeviceInfo(1, "G502 X", DeviceKind.Mouse, 0x1004, 7, true); t.OnBattery(1, new(ComponentRole.Main, 70, false), t0);
    Assert.Empty(t.DueForRefresh(t0.AddMinutes(29)));
    Assert.Equal([(byte)1], t.DueForRefresh(t0.AddMinutes(30)));
    t.OnLinkLost(1);
    Assert.Empty(t.DueForRefresh(t0.AddHours(2)));
}
```

- [ ] **Step 2: Run** → FAIL (types missing).
- [ ] **Step 3: Implement** the three files.
- [ ] **Step 4: Run** tests → PASS.
- [ ] **Step 5: Add `--battery-dump`** in `App.OnStartup`: when present, start a `LogitechBatterySource`, wait 5 s, write `Current` as indented JSON to `%TEMP%\InputBridge-battery.json`, then shut down without showing UI or starting the server.
- [ ] **Step 6: Hardware check on this PC** — `dotnet run --project windows/src/InputBridge.Windows -- --battery-dump`, then read the file: expect `G915 TKL` (`deviceId` `logitech-keyboard`, a plausible percent) and the device on the `C54D` receiver. Compare the G915 value with G HUB if it is installed. Then leave the keyboard idle until it sleeps, confirm with a fresh run that nothing wakes it (keyboard lights stay off), and note the result in the task report.
- [ ] **Step 7: Commit** — `Read Logitech receiver device batteries from HID++ notifications`

---

### Task 4: Battery aggregation, remote keyboard merge and the API

**Files:**
- Create: `windows/src/InputBridge.Windows/Core/Battery/BatteryService.cs`
- Create: `windows/src/InputBridge.Windows/Core/Battery/BatteryWire.cs` (DTOs + JSON options)
- Modify: `windows/src/InputBridge.Windows/Core/Models.cs` (`AppSettings.BatteryIndicatorsEnabled { get; set; } = true`)
- Modify: `windows/src/InputBridge.Windows/Core/AppRuntime.cs` (own and start/stop `BatteryService`; expose `Battery`; `SaveBatterySettings(bool enabled)`)
- Modify: `windows/src/InputBridge.Windows/Core/ControllerServer.cs` (two endpoints)
- Modify: `shared/PROTOCOL.md` (document the endpoints)
- Test: `windows/tests/InputBridge.Windows.Tests/BatteryServiceTests.cs`, `BatteryWireTests.cs`

**Interfaces:**
- Consumes: `IBatterySource`, `BatteryReading`, `BatteryIds` (Tasks 1, 3).
- Produces:
  - `sealed class BatteryService : IAsyncDisposable`
    - ctor `(IEnumerable<IBatterySource> sources, Func<bool> enabled, TimeProvider clock)`
    - `IReadOnlyList<BatteryReading> Visible { get; }` — empty when disabled; local readings first, ordered Keyboard, Mouse, Headset, Trackpad, Other, then by name
    - `event Action? Changed`
    - `void SetRemote(IReadOnlyList<BatteryReading> readings)` — keeps only `DeviceId == BatteryIds.SharedKeyboard`, marks `Remote = true`, replaces the previous remote set (an empty list clears it)
    - `IReadOnlyList<BatteryReading> LocalShared()` — local readings with the shared id (what the Mac fetches)
    - `Task StartAsync(CancellationToken)`; `void Refresh()` (re-raise after settings change)
  - Remote rules: a remote reading is shown only if no local reading has the same id, and only while younger than 11 minutes (`clock`).
  - `static class BatteryWire { JsonSerializerOptions Options; string Serialize(IReadOnlyList<BatteryReading>); IReadOnlyList<BatteryReading> Deserialize(string json); }` — shape exactly as `shared/fixtures/battery-readings.json`.
  - `GET /api/battery` → `BatteryWire` body of `LocalShared()`; `POST /api/battery` → `SetRemote(body)`, returns `{ ok = true }`. Both: private-network check + `TryAuthorize`, like `/api/keyboard/claim`. Body limit 16 KB; malformed JSON → 400.

- [ ] **Step 1: Failing tests**
  - `Wire_RoundTripsFixture`: `Deserialize(File.ReadAllText(<repo>/shared/fixtures/battery-readings.json))` gives one reading `("logitech-keyboard","G915 TKL",Keyboard,[Main 82 false])`, and `Serialize` of it parsed as `JsonDocument` equals the fixture parsed (semantic equality).
  - `Remote_HiddenWhenLocalPresent`: fake source returns local shared keyboard 70%; `SetRemote([shared 40%])` → `Visible` has one reading, 70, `Remote == false`.
  - `Remote_ShownWhenNoLocal_AndMarkedRemote`.
  - `Remote_ExpiresAfter11Minutes` (use `FakeTimeProvider` from `Microsoft.Extensions.TimeProvider.Testing`).
  - `Remote_IgnoresNonSharedIds`: `SetRemote([("apple:AirPods", …)])` → nothing visible.
  - `Disabled_ShowsNothing`.
  - `Order_KeyboardMouseHeadset`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement**, wire into `AppRuntime.StartAsync`/`StopAsync`, map endpoints.
- [ ] **Step 4: Run** tests → PASS; `dotnet build` → 0 errors.
- [ ] **Step 5: Smoke test the endpoint** on this PC: run the app; `curl -i http://127.0.0.1:41715/api/battery` → `401` without a token (proves the route exists and is protected).
- [ ] **Step 6: Commit** — `Aggregate battery readings and share the keyboard reading over the API`

---

### Task 5: Windows tray icons and settings

**Files:**
- Create: `windows/src/InputBridge.Windows/Battery/BatteryIconVisual.cs` (pure: label, colours, GUID)
- Create: `windows/src/InputBridge.Windows/Battery/BatteryIconRenderer.cs` (GDI+ drawing → `Icon`)
- Create: `windows/src/InputBridge.Windows/Battery/TrayBatteryIcons.cs` (`Shell_NotifyIcon` wrapper + message-only window)
- Modify: `windows/src/InputBridge.Windows/App.xaml.cs` (create `TrayBatteryIcons`, feed `Runtime.Battery.Changed`, right-click shows the existing tray `ContextMenuStrip`, dispose on exit)
- Modify: `windows/src/InputBridge.Windows/MainWindow.xaml(.cs)` (new sidebar page **Battery** inserted before *Updates* — update `UpdatesPage` const — with toggle "Show battery levels in the taskbar" and a list of visible devices `Name — 82%`; saves via `AppRuntime.SaveBatterySettings`)
- Modify: `README.md`, `README_TR.md`, `CHANGELOG.md` (new `## Unreleased` entry; Windows 11 hint: pin icons via *Settings → Personalization → Taskbar → Other system tray icons*)
- Test: `windows/tests/InputBridge.Windows.Tests/BatteryIconVisualTests.cs`

**Interfaces:**
- Consumes: `BatteryService.Visible/Changed` (Task 4).
- Produces:
  - `static class BatteryIconVisual`
    - `string Label(int percent)` → `"82"`, `"5"`, `"100"` (renderer uses a condensed font for 3 chars)
    - `IconTone Tone(BatteryReading r)` → `enum IconTone { Normal, Low, Charging, Remote }`; precedence: Remote > Low (`<= 15`, not charging) > Charging > Normal
    - `string Tooltip(BatteryReading r)` → `"G915 TKL — 82%"`, `"G915 TKL — 82% (charging)"`, `"G915 TKL — 82% (on Mac)"`; max 127 chars
    - `Guid IconGuid(string exePath, string deviceId)` — SHA-1 of `exePath.ToLowerInvariant() + "|" + deviceId`, first 16 bytes, RFC 4122 version 5 bits set. The exe path is part of the key because Windows binds a tray GUID to one executable path.
  - `sealed class TrayBatteryIcons : IDisposable` — `void Update(IReadOnlyList<BatteryReading> visible, bool darkTaskbar)`; adds/modifies by GUID (`NIF_GUID`, `NOTIFYICON_VERSION_4`), hides (`NIS_HIDDEN`) icons whose device is no longer visible, deletes all on `Dispose`; re-adds everything on the registered `TaskbarCreated` message; `event Action<System.Drawing.Point>? ContextMenuRequested`.
  - Dark taskbar = `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\SystemUsesLightTheme == 0`; re-render on `SystemEvents.UserPreferenceChanged`. Icon size from `GetSystemMetricsForDpi(SM_CXSMICON)`.
  - Colours: Normal = white on dark / black on light; Low = `#E81123`; Charging = number in normal colour plus a small bolt in the top-right corner; Remote = normal colour at ~45% opacity.

- [ ] **Step 1: Failing tests** — `Label(100) == "100"`; `Tone` for 15% not charging → `Low`, 15% charging → `Charging`, 16% → `Normal`, remote 10% → `Remote`; `Tooltip` three cases above; `IconGuid` stable for the same inputs, differs by deviceId, differs by exe path, case-insensitive on path, and `guid.ToString()[14] == '5'`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** the three files and wiring.
- [ ] **Step 4: Run** tests → PASS; `dotnet build` → 0 errors.
- [ ] **Step 5: Manual check on this PC** — run the app: one icon per device with the right number and tooltip; pin them once; turn the setting off/on (icons hide/return); restart the app (pins kept); `Stop-Process -Name explorer` then let it restart (icons return); let the keyboard sleep (its icon hides, comes back on keypress); switch the light/dark theme (icons recolour).
- [ ] **Step 6: Commit** — `Show device batteries as Windows tray icons`

---

### Task 6: PRO X 2 headset battery (time-boxed spike)

**Files:**
- Create (only if it works): `windows/src/InputBridge.Windows/Core/Battery/ProX2BatterySource.cs` + parser test
- Modify (either way): `docs/superpowers/specs/2026-11-19-battery-indicators-design.md` → *Riskler* with what was found

**Interfaces:**
- Produces (if it works): `sealed class ProX2BatterySource : IBatterySource`, `deviceId` `"logitech:PRO X 2"`, `Kind = Headset`.

The dongle `046D:0AF7` exposes vendor collections `FF13:0001` and `FFA0:0001` (no `FF00`). Read-only investigation, time box ~2 hours:

- [ ] **Step 1:** Open both collections read-only and log input reports for 2 minutes while the headset is on, idle, then plugged into USB power; look for a byte that tracks battery/charging.
- [ ] **Step 2:** Try HID++ 2.0 framing on each collection (ROOT getFeature `0x1004`, `0x1F20`, `0x1000`) at device indexes `0xFF` and `0x01`, with short timeouts. Send nothing else (no writes beyond these reads).
- [ ] **Step 3: Decide.** If a reading matches the headset's real level twice (via the headset's voice prompt or G HUB), write the parser test from the captured bytes, implement the source and register it in `AppRuntime`. Otherwise stop: record the findings in the spec and report that the headset ships later.
- [ ] **Step 4: Commit** — `Add PRO X 2 headset battery` or `Document PRO X 2 battery findings`

---

### Task 7: macOS test target, model and parsers

**Files:**
- Modify: `macos/project.yml` — new target `InputBridgeMacTests` (`bundle.unit-test`, macOS, no host app, sources: `Tests/InputBridgeMacTests` + `Sources/InputBridgeMac/Battery/BatteryModels.swift` + `Sources/InputBridgeMac/Battery/BatteryParsing.swift` + `shared/fixtures/battery-readings.json` as a resource); add it to the scheme's `testTargets`
- Create: `macos/Sources/InputBridgeMac/Battery/BatteryModels.swift`
- Create: `macos/Sources/InputBridgeMac/Battery/BatteryParsing.swift`
- Create: `macos/Tests/InputBridgeMacTests/BatteryParsingTests.swift`
- Modify: `.github/workflows/ci.yml` — `macos-14` job: `brew install xcodegen`, `cd macos && xcodegen generate`, `xcodebuild test -scheme InputBridgeMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

**Interfaces:**
- Produces (Swift mirrors of Task 1; wire format = the shared fixture):
  - `enum DeviceKind: String, Codable { case keyboard, mouse, headset, trackpad, other }`
  - ``enum ComponentRole: String, Codable { case main, left, right, `case` }``
  - `struct BatteryComponent: Codable, Equatable { let role: ComponentRole; let percent: Int; let charging: Bool }`
  - `struct BatteryReading: Codable, Equatable { let deviceId: String; let name: String; let kind: DeviceKind; let components: [BatteryComponent]; let readAt: Date; var remote: Bool = false }` — `remote` excluded from `CodingKeys`; dates ISO-8601
  - `struct BatteryEnvelope: Codable { let readings: [BatteryReading] }`
  - `enum BatteryIds { static let sharedKeyboard = "logitech-keyboard" }`
  - `enum HIDPPBattery` — same functions and semantics as C# `HidppBattery`: `parseUnifiedStatus(_:stateOfChargeSupported:)`, `parseUnifiedCapabilities(_:)`, `parseBatteryStatus(_:)`, `parseVoltage(_:)`, `voltageToPercent(_:)`
  - `struct ProfilerDevice: Equatable { let name: String; let left: Int?; let right: Int?; let caseLevel: Int? }`
  - `enum SystemProfilerParser { static func connectedEarbuds(_ output: String) -> [ProfilerDevice] }` — only devices under `Connected:` that have at least one of `Left Battery Level` / `Right Battery Level`; values parsed from `NN%`
  - `enum AppleHIDParser { static func reading(product: String, batteryPercent: Int?, charging: Bool) -> BatteryReading? }` — kind from product (`Trackpad` → trackpad, `Mouse` → mouse, `Keyboard` → keyboard), `deviceId` `"apple:" + product`; nil when no percent

- [ ] **Step 1: Failing tests** — port every Task 1 parser test 1:1 to XCTest (same bytes, same expected values); plus:
  - `testFixtureDecodes`: decode the bundled `battery-readings.json` → one reading `logitech-keyboard`, 82%, `remote == false`; re-encode and decode equals.
  - `testProfilerReadsAirPods` with this fixture string:

```
Bluetooth:

      Bluetooth Controller:
          State: On
      Connected:
          Ardanuc's AirPods Pro:
              Address: 11:22:33:44:55:66
              Case Battery Level: 60%
              Left Battery Level: 90%
              Right Battery Level: 85%
              Minor Type: Headphones
          G915 TKL:
              Address: AA:BB:CC:DD:EE:01
              Minor Type: Keyboard
      Not Connected:
          Old AirPods:
              Left Battery Level: 10%
```

    expects `[ProfilerDevice(name: "Ardanuc's AirPods Pro", left: 90, right: 85, caseLevel: 60)]`.
  - `Profiler_IgnoresNotConnectedAndMissingCase`: same text without the `Case Battery Level` line → `caseLevel == nil`; text with only a `Not Connected:` section → `[]`; empty string → `[]`.
  - `testAppleHIDTrackpad`: `("Magic Trackpad", 64, false)` → kind trackpad, `apple:Magic Trackpad`, `[main 64]`; percent nil → nil.
- [ ] **Step 2: Run on CI** — push the branch (ask the user first) or run `xcodebuild test` on their Mac → FAIL (types missing).
- [ ] **Step 3: Implement** `BatteryModels.swift` and `BatteryParsing.swift`.
- [ ] **Step 4: Run** → PASS (CI `macos-14` job green, Windows job still green).
- [ ] **Step 5: Commit** — `Add macOS battery model, parsers and test target`

---

### Task 8: macOS battery sources

**Files:**
- Create: `macos/Sources/InputBridgeMac/HIDPPSession.swift` (moved out of `LogitechBluetoothKeyboard.swift`, now `final class` with internal access; error type stays `LogitechBluetoothKeyboard.KeyboardError`)
- Modify: `macos/Sources/InputBridgeMac/LogitechBluetoothKeyboard.swift` (use the moved session; add `static func batteryReading(namePattern:) throws -> BatteryReading?`)
- Create: `macos/Sources/InputBridgeMac/Battery/BatterySource.swift`
- Create: `macos/Sources/InputBridgeMac/Battery/AppleBatterySource.swift`

**Interfaces:**
- Consumes: Task 7 types.
- Produces:
  - `protocol BatterySource { var name: String { get }; func read() -> [BatteryReading] }` — blocking, called off the main thread
  - `struct LogitechBluetoothBatterySource: BatterySource` — init `(pattern: () -> NSRegularExpression)`; calls `LogitechBluetoothKeyboard.batteryReading`; returns `[]` on `inputMonitoringRequired` **without** calling `IOHIDRequestAccess` (add an `requestAccessIfDenied: Bool` parameter to `HIDPPSession.init`, default `true` so the keyboard switch keeps its prompt; battery passes `false`); `deviceId` `BatteryIds.sharedKeyboard`; same feature order `0x1004` → `0x1000` → `0x1001` and the `HIDPPBattery` parsers
  - `struct AppleBatterySource: BatterySource` — init `(excluding: () -> NSRegularExpression)` (the keyboard pattern, so the G915 is never listed twice):
    - trackpad/mouse/keyboard: `IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"))`, properties `Product` and `BatteryPercent`; charging from `BatteryStatusFlags` only if the builder can confirm the bit on a real device, else `false`; → `AppleHIDParser.reading`
    - AirPods: run `/usr/sbin/system_profiler SPBluetoothDataType` with `LC_ALL=C` (same pattern as `G915Monitor`), 10 s timeout → `SystemProfilerParser.connectedEarbuds` → one `BatteryReading` per device, `kind .headset`, `deviceId "apple:" + name`, components left/right/case for the values present

- [ ] **Step 1: Implement** (I/O only; the logic is covered by Task 7 tests).
- [ ] **Step 2: Build on CI** → green; existing keyboard switch path compiles unchanged.
- [ ] **Step 3: Manual check on the user's Mac** — temporarily log `read()` of both sources from `AppModel` init (remove before commit): G915 percent appears when on Bluetooth, AirPods L/R/case when in ears, trackpad percent; with Input Monitoring revoked there is no prompt and the G915 is simply missing.
- [ ] **Step 4: Commit** — `Read G915, AirPods and trackpad batteries on macOS`

---

### Task 9: macOS menu-bar strip, sharing with Windows, settings

**Files:**
- Create: `macos/Sources/InputBridgeMac/Battery/BatteryMonitor.swift`
- Create: `macos/Sources/InputBridgeMac/Battery/BatteryStrip.swift` (pure formatter, added to the test target)
- Create: `macos/Sources/InputBridgeMac/Battery/BatteryStatusItem.swift`
- Modify: `macos/Sources/InputBridgeMac/ControllerClient.swift` (`fetchBattery`, `postBattery`)
- Modify: `macos/Sources/InputBridgeMac/AppModel.swift` (own `BatteryMonitor`; `@Published var batteryIndicatorsEnabled`; trigger refresh after `apply`/`detected`)
- Modify: `macos/Sources/InputBridgeMac/InputBridgeMacApp.swift` (toggle "Show battery levels" in `MenuBarPanel` and `DevicesPane`; capture `openWindow` for the status item)
- Modify: `macos/project.yml` (add `BatteryStrip.swift` to the test target sources)
- Modify: `README.md`, `README_TR.md`, `CHANGELOG.md`
- Test: `macos/Tests/InputBridgeMacTests/BatteryStripTests.swift`, `BatteryMergeTests.swift`

**Interfaces:**
- Consumes: Tasks 7–8; Windows `GET/POST /api/battery` (Task 4).
- Produces:
  - `ControllerClient.fetchBattery(offer:) async throws -> [BatteryReading]` (404 → `[]`, 5 s timeout) and `postBattery(_ readings: [BatteryReading], offer:) async throws` (404 ignored)
  - `enum BatteryMerge { static func visible(local: [BatteryReading], remote: [BatteryReading]) -> [BatteryReading] }` — remote kept only for `BatteryIds.sharedKeyboard` and only if no local reading has that id; marked `remote = true`; ordering keyboard, mouse, headset, trackpad, other, then name
  - `struct StripSegment: Equatable { let symbol: String; let text: String; let tone: Tone }` with `enum Tone { case normal, low, charging, remote }`
  - `enum BatteryStrip { static func segments(_ readings: [BatteryReading]) -> [StripSegment] }`:
    - single component: one segment, text `"82%"`
    - AirPods: three segments in order left, right, case with texts `"L90"`, `"R85"`, and `"60"` for the case segment, which uses a case symbol; missing components omitted
    - tone precedence as Windows: remote > low (`<= 15`, not charging) > charging > normal
    - symbols (builder may adjust if unavailable on macOS 13; fallbacks in parentheses): keyboard `keyboard`, mouse `computermouse`, headset `airpods` (`headphones`), case `airpodspro.chargingcase.wireless` (`case`), trackpad `rectangle.and.hand.point.up.left` (`hand.point.up.left`)
  - `final class BatteryMonitor: ObservableObject` — `@Published private(set) var visible: [BatteryReading]`; reads both sources every 5 minutes on a background queue, plus on wake (`NSWorkspace.didWakeNotification`), on Bluetooth connect (`IOBluetoothDevice.register(forConnectNotifications:selector:)`), and via `refresh()`; after each local read: `postBattery(local shared)` (empty list when the keyboard is absent) and `fetchBattery` when a controller is paired; a failed or skipped fetch means `remote = []` (the faded keyboard disappears when the link is down); merges with `BatteryMerge.visible`; empty when the setting is off
  - `final class BatteryStatusItem` — owns an `NSStatusItem` (variable length) to the left of the InputBridge icon; renders `BatteryStrip.segments` as an attributed title (SF Symbol attachments + monospaced-digit text; low = `systemRed`, remote = `secondaryLabelColor`, charging = `bolt.fill` after the text); removes itself (`isVisible = false`) when there is nothing to show; click → opens the `setup` window via the `openWindow` action captured from the `MenuBarExtra` label's `onAppear` and `NSApp.activate(ignoringOtherApps: true)`. If that capture proves unreliable, the click does nothing (note it in the report); no popover.

- [ ] **Step 1: Failing tests**
  - `BatteryStripTests`: G915 82% → `[("keyboard","82%",.normal)]`; AirPods L90 R85 C60 → three segments `L90`, `R85`, `60` in that order; AirPods without case → two segments; 15% not charging → `.low`; 15% charging → `.charging`; remote 10% → `.remote`; `[]` → `[]`.
  - `BatteryMergeTests`: `RemoteMerge_IgnoresMissingController` (`remote: []` → local unchanged); local shared keyboard wins over remote; remote shared keyboard shown with `remote == true` when not local; remote `apple:*` ignored; ordering keyboard before headset before trackpad.
- [ ] **Step 2: Run on CI** → FAIL.
- [ ] **Step 3: Implement** and wire; persist the toggle under `battery-indicators-enabled` (default `true`).
- [ ] **Step 4: Run on CI** → PASS.
- [ ] **Step 5: End-to-end check on both machines** — Mac strip shows G915, AirPods L/R/case and trackpad; removing AirPods hides them immediately on the next read; apply the Windows profile → the Mac shows the G915 faded (from Windows) and the Windows tray shows it normal; apply the Mac profile → the reverse within one Mac refresh; turning the toggle off removes the strip; clicking the strip opens the InputBridge window.
- [ ] **Step 6: Commit** — `Show device batteries in the macOS menu bar and share the keyboard reading`
