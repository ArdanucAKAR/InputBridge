# Battery indicators, round two: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two display changes and the clean-ups that go with them.
- On the Mac, a single menu bar item: the InputBridge icon followed by a battery column per connected device.
- On Windows, tray icons that draw a device glyph above the percentage.
- Battery sharing between the machines is removed.
- Windows reads a cabled G915 once instead of six times.
- The Mac logs why the Bluetooth keyboard read fails.

**Architecture:**
- **Shared rules.** Each machine shows only the devices connected to it. The `/api/battery` sharing and every "remote/faded" path are deleted on both sides.
- **Windows tray icon.** The icon layout is a pure function (`BatteryIconLayout`) that the GDI+ renderer draws into.
- **Windows cabled devices.** A collection that does not answer the receiver register query is treated as a directly connected device. It is scanned on every open, and the tracker collapses identical devices on several slots into one.
- **Mac column content.** Columns come from a pure function (`MenuBarColumns.columns`).
- **Mac menu bar item.** An AppKit `NSStatusItem` hosts a custom-drawn `StatusItemView`, and an `NSPopover` holds the existing SwiftUI panel. The settings window becomes an AppKit `NSWindow`, so SwiftUI's `MenuBarExtra`, `Window` scene and `openWindow` go away.

**Tech Stack:**
- Windows: .NET 8 WPF/WinForms, GDI+, xUnit.
- Mac: Swift 5, AppKit + SwiftUI (macOS 13 floor), XCTest. The test target is hostless and built by XcodeGen.
- CI: GitHub Actions `ci.yml`.

**Spec:** `docs/superpowers/specs/2026-11-26-battery-menubar-redesign-design.md`

## Global Constraints

**Thresholds and defaults**
- Low battery means 15 % or less while not charging; draw it red.
- While charging, draw a bolt.
- There is no faded/remote tone anywhere.
- "Show battery levels" (Mac) and "Show battery levels in the taskbar" (Windows) stay, and both default to **on**.
- New Mac setting "AirPods separate", default **on** (separate). It is stored under UserDefaults key `battery-airpods-separate`.
- In combined mode, the AirPods column shows the lower of the left and right earbuds, and the case is hidden.

**Display rules**
- A disconnected device disappears at once. Nothing is shown for devices on the other machine.
- The Windows keyboard device id stays `logitech-keyboard`, so the tray icon GUID, and with it the user's pin, survives.

**Mac platform**
- Minimum version is macOS 13.0.
- The app stays `LSUIElement` (menu bar only).
- Mac log subsystem is `com.inputbridge.mac`, category `battery`. Use `privacy: .public` for device names, feature ids and errors.

**Scope**
- Out of scope: reading the PRO X 2 headset, and showing the other machine's devices.

**Verifying the Mac tasks**
- Mac code cannot be built on the Windows dev machine.
- Verify each Mac task by pushing `feature/battery-indicators` and reading the `macos` job of `ci.yml`. The scheme builds the app and runs the tests.
- Run: `gh run watch <id> --exit-status`, then `gh run view <id> --log | grep "Executed"`.

## Review Focus

1. **A real receiver that misses the register query once.** Scenario: a LIGHTSPEED receiver times out on the connected-devices query. Expected: it must still show every paired device. Treating it as a direct device may only cost an extra scan on reopen, never a hidden device. Test: Task 1, `Tracker_DifferentDevicesOnSeveralSlots_AllShown`.
2. **Cabled keyboard replugged.** Expected: after the USB cable is pulled and plugged back, the keyboard is read again without restarting the app. The scan on every open does this. Test: Task 1, `DirectDevice_ScansOnEveryOpen`.
3. **AirPods reporting only one earbud.** This happens when one earbud is in the case or out of range. Expected: combined mode shows that earbud; separate mode shows only the columns that exist. Test: Task 5, `testAirPodsCombinedWithOneEarbud`.
4. **The battery switch turned off.** Expected:
   - Mac: only the InputBridge icon remains, and the item width shrinks back.
   - Windows: all battery tray icons are removed.

   Test: Task 4 `testDisabledReadsNothing` (monitor logic) and Task 3 the existing `TrayBatteryIcons` path. Check it on the device too (see Task 6 step).
5. **Percent outside 0–100 from a misbehaving device.** Expected: clamped to the range, never a crash or a 4-digit label. Tests: Task 3 `Layout` + existing `Label` clamp test, and Task 5 `testPercentIsClamped`.

---

### Task 1: Windows reads a cabled HID++ device once

**Files:**
- Create: `windows/src/InputBridge.Windows/Core/Battery/HidppCollectionPlan.cs`
- Modify: `windows/src/InputBridge.Windows/Core/Battery/LogitechBatterySource.cs` (`InitialiseAsync`, lines ~190–225)
- Modify: `windows/src/InputBridge.Windows/Core/Battery/LogitechDeviceTracker.cs` (`Readings`, line ~65)
- Test: `windows/tests/InputBridge.Windows.Tests/HidppCollectionPlanTests.cs`, `windows/tests/InputBridge.Windows.Tests/LogitechTrackerTests.cs`

**Interfaces:**
- Produces: `internal static class HidppCollectionPlan { public static bool ShouldScan(bool isReceiver, bool firstOpenThisSession); }`.
  - A receiver is scanned only on its first open in the session.
  - A direct device (one that did not confirm the connected-devices register query) is scanned on every open.
- Produces: `LogitechDeviceTracker.Readings(Regex)` returns one reading per distinct (`Name`, `Kind`), taken from the lowest slot.

- [ ] **Step 1: Write the failing tests**

```csharp
// HidppCollectionPlanTests.cs
[Fact] public void Receiver_ScansOnlyOnFirstOpen()
{
    Assert.True(HidppCollectionPlan.ShouldScan(isReceiver: true, firstOpenThisSession: true));
    Assert.False(HidppCollectionPlan.ShouldScan(isReceiver: true, firstOpenThisSession: false));
}
[Fact] public void DirectDevice_ScansOnEveryOpen() =>
    Assert.True(HidppCollectionPlan.ShouldScan(isReceiver: false, firstOpenThisSession: false));

// LogitechTrackerTests.cs: a cabled G915 answers on slots 1-6 with the same name
[Fact] public void Tracker_SameDeviceOnSeveralSlots_ShownOnce()
{
    // OnLinked + OnDeviceInfo("G915 TKL LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard", Keyboard, 0x1001, 6, false)
    // + OnBattery(98, charging) on slots 3, 1, 2. Then:
    var reading = Assert.Single(t.Readings(new Regex("G915|G913", RegexOptions.IgnoreCase)));
    Assert.Equal(BatteryIds.SharedKeyboard, reading.DeviceId);
}
[Fact] public void Tracker_DifferentDevicesOnSeveralSlots_AllShown()
{
    // slot 1 "G915 TKL" Keyboard, slot 2 "PRO X 2" Mouse, slot 3 "PRO X 2" Keyboard (same name, other kind)
    Assert.Equal(3, t.Readings(new Regex("G915|G913", RegexOptions.IgnoreCase)).Count);
}
```

- [ ] **Step 2: Run them and confirm they fail.** Run `dotnet test windows/tests/InputBridge.Windows.Tests --filter "HidppCollectionPlan|Tracker_"`. Expected: compile error (`HidppCollectionPlan` missing) and `Tracker_SameDeviceOnSeveralSlots_ShownOnce` failing with 3 readings.

- [ ] **Step 3: Implement**
  - `HidppCollectionPlan.ShouldScan` returns `!isReceiver || firstOpenThisSession`.
  - In `Readings`, group the slot readings by (`Name`, `Kind`) and keep the one with the lowest slot index.
  - In `InitialiseAsync`:
    - Compute `isReceiver = reported is not null`.
    - Replace `if (!scan) return;` with `if (!HidppCollectionPlan.ShouldScan(isReceiver, scan)) return;`.
    - Log `"{key}: direct device"` when `!isReceiver`.

- [ ] **Step 4: Run the whole Windows suite.** Run `dotnet test windows/tests/InputBridge.Windows.Tests`. Expected: all pass.

- [ ] **Step 5: Check on the hardware.** Do this only while the G915 is connected to the PC by USB cable. Run:
  - `dotnet build windows/src/InputBridge.Windows -c Debug`
  - then `windows/src/InputBridge.Windows/bin/Debug/net8.0-windows10.0.19041.0/InputBridge.exe --battery-dump`

  Expected:
  - `%TEMP%\InputBridge-battery.json` holds exactly one `logitech-keyboard` entry.
  - `InputBridge-battery.log` has a `direct device` line for the `pid_c343` collection.

  If the cable is not connected, say so in the report and skip this step.

- [ ] **Step 6: Commit.** Message: `Read a cabled Logitech keyboard once instead of on every slot`.

---

### Task 2: Windows drops battery sharing

**Files:**
- Delete: `windows/src/InputBridge.Windows/Core/Battery/BatteryWire.cs`, `windows/tests/InputBridge.Windows.Tests/BatteryWireTests.cs`
- Modify:
  - `windows/src/InputBridge.Windows/Core/Battery/BatteryService.cs`
  - `windows/src/InputBridge.Windows/Core/Battery/BatteryModels.cs`
  - `windows/src/InputBridge.Windows/Core/ControllerServer.cs` (the two `/api/battery` maps, lines ~83–115)
  - `windows/src/InputBridge.Windows/Core/AppRuntime.cs` (BatteryService construction, line ~36)
  - `windows/src/InputBridge.Windows/Battery/BatteryIconVisual.cs`, `windows/src/InputBridge.Windows/Battery/BatteryIconRenderer.cs`
  - `windows/src/InputBridge.Windows/MainWindow.xaml` (Battery page subtitle, line ~277)
  - `shared/PROTOCOL.md` (delete the `## Battery sharing` section)
- Test: `windows/tests/InputBridge.Windows.Tests/BatteryServiceTests.cs`, `windows/tests/InputBridge.Windows.Tests/BatteryIconVisualTests.cs`

**Interfaces:**
- Produces: `public BatteryService(IEnumerable<IBatterySource> sources, Func<bool> enabled)`. The `TimeProvider` parameter is gone. `Visible` returns the local readings when enabled, otherwise `[]`. `SetRemote` and `LocalShared` are gone.
- Produces: `BatteryReading(string DeviceId, string Name, DeviceKind Kind, IReadOnlyList<BatteryComponent> Components, DateTimeOffset ReadAt)`. There is no `Remote`.
- Produces: `public enum IconTone { Normal, Low, Charging }`.

- [ ] **Step 1: Update the tests first.**
  - Delete every `Remote_*` test, `LocalShared_ReturnsOnlySharedLocalReadings` and the `Remote` tone test.
  - `Changed_FiresOnSourceChangeSetRemoteAndRefresh_AndSurvivesThrowingListener` becomes `Changed_FiresOnSourceChangeAndRefresh_AndSurvivesThrowingListener`, without the `SetRemote` call.
  - Add:

```csharp
[Fact] public void Visible_IsEmptyWhenDisabled()
{
    var service = new BatteryService([Source(SharedKeyboard(40))], enabled: () => false);
    Assert.Empty(service.Visible);
}
[Fact] public void Tooltip_ChargingNote()  // expected: DisplayName(reading.Name) + " — 40% (charging)", no "(on Mac)" form exists
    => Assert.EndsWith(" — 40% (charging)", BatteryIconVisual.Tooltip(Reading(40, charging: true)));
```

  Adjust the existing helpers (`Reading`, `Source`, `SharedKeyboard`) to the new record and constructor.

- [ ] **Step 2: Run and confirm the failure.** Run `dotnet test windows/tests/InputBridge.Windows.Tests`. Expected: compile errors on the new constructor and on the removed `remote:` argument.

- [ ] **Step 3: Implement the removals.**
  - Delete `BatteryWire.cs`, the `/api/battery` GET and POST maps, the remote fields and the expiry timer.
  - Remove `Remote` from `BatteryReading` and `IconTone`, the `" (on Mac)"` tooltip note and `RemoteAlpha`.
  - Battery page subtitle becomes: `Each wireless device with a battery reading gets its own icon in the taskbar notification area, showing what it is and its charge in percent.`
  - Remove `## Battery sharing` from `shared/PROTOCOL.md`.

- [ ] **Step 4: Run the suite and check for leftovers.**
  - Run `dotnet test windows/tests/InputBridge.Windows.Tests`. Expected: all pass.
  - Run `dotnet build windows/src/InputBridge.Windows -c Release -warnaserror`. Expected: 0 warnings.
  - Run `git grep -n "api/battery\|SetRemote\|LocalShared\|IconTone.Remote" -- windows shared`. Expected: no output.

- [ ] **Step 5: Commit.** Message: `Stop sharing battery readings between the machines on Windows`.

---

### Task 3: Windows tray icon shows the device glyph above the percentage

**Files:**
- Create: `windows/src/InputBridge.Windows/Battery/BatteryIconLayout.cs`
- Modify:
  - `windows/src/InputBridge.Windows/Battery/BatteryIconRenderer.cs`
  - `windows/src/InputBridge.Windows/Battery/TrayBatteryIcons.cs` (cache key, line ~105)
- Test: `windows/tests/InputBridge.Windows.Tests/BatteryIconLayoutTests.cs`, `windows/tests/InputBridge.Windows.Tests/BatteryIconRendererTests.cs`

**Interfaces:**
- Consumes: `IconTone { Normal, Low, Charging }` (Task 2).
- Produces:
  - `public readonly record struct IconBoxes(RectangleF Glyph, RectangleF Digits, RectangleF? Bolt);`
  - `public static class BatteryIconLayout { public static IconBoxes Compute(int size, bool charging); }`
- Produces: `public static Bitmap Draw(string label, IconTone tone, DeviceKind kind, bool darkTaskbar, int size)`.
  - `Render(BatteryReading, bool, int)` passes `reading.Kind`.
  - Glyphs:
    - Keyboard: rounded outline with a key row.
    - Mouse: capsule with a centre line.
    - Headset: band arc with two cups.
    - Trackpad and Other: battery outline.

- [ ] **Step 1: Write the failing tests**

```csharp
// BatteryIconLayoutTests.cs
public static TheoryData<int, bool> Sizes => new() { {16,false},{16,true},{20,false},{24,true},{32,false},{32,true} };

[Theory, MemberData(nameof(Sizes))] public void Boxes_StayInsideIcon(int size, bool charging)
{ /* Glyph, Digits and Bolt (if any): Left>=0, Top>=0, Right<=size, Bottom<=size */ }
[Theory, MemberData(nameof(Sizes))] public void Glyph_SitsAboveDigits(int size, bool charging)
{ var b = BatteryIconLayout.Compute(size, charging); Assert.True(b.Glyph.Bottom <= b.Digits.Top); }
[Theory, MemberData(nameof(Sizes))] public void Digits_TakeAtLeastHalfTheHeight(int size, bool charging) =>
    Assert.True(BatteryIconLayout.Compute(size, charging).Digits.Height >= size * 0.5f);
[Fact] public void Bolt_OnlyWhenCharging_BesideTheGlyph()
{
    Assert.Null(BatteryIconLayout.Compute(16, false).Bolt);
    var b = BatteryIconLayout.Compute(16, true);
    Assert.NotNull(b.Bolt);
    Assert.True(b.Bolt!.Value.Left >= b.Glyph.Right && b.Bolt.Value.Bottom <= b.Digits.Top);
}

// BatteryIconRendererTests.cs
[Theory]
[InlineData(DeviceKind.Keyboard, 16)] [InlineData(DeviceKind.Mouse, 16)] [InlineData(DeviceKind.Headset, 16)]
[InlineData(DeviceKind.Other, 16)] [InlineData(DeviceKind.Keyboard, 32)]
public void Draw_PutsInkInGlyphAndDigitBoxes(DeviceKind kind, int size)
{ /* Draw("62", Normal, kind, darkTaskbar: true, size): at least one pixel with A>128 inside Glyph and inside Digits */ }
[Fact] public void Draw_LowIsRed() { /* Draw("9", Low, Mouse, true, 16): some pixel with R>200 && G<80 && A>128 */ }
[Fact] public void Draw_ChargingHasInkInBoltBox() { /* Draw("98", Charging, Keyboard, true, 16) */ }
[Fact] public void Draw_WritesPreviewPngs()
{ /* Keyboard/Mouse/Headset × Normal/Low/Charging × 16/20/24/32, dark and light, scaled ×8 with nearest
     neighbour, saved under Path.Combine(Path.GetTempPath(), "InputBridge-icon-preview"); asserts files exist */ }
```

- [ ] **Step 2: Run and confirm the failure.** Run `dotnet test windows/tests/InputBridge.Windows.Tests --filter "BatteryIconLayout|BatteryIconRenderer"`. Expected: compile error, because `BatteryIconLayout` is missing and `Draw` lacks `kind`.

- [ ] **Step 3: Implement `Compute` and the new `Draw`.**
  - Glyph box: the top ~40 % of the icon, snapped to whole pixels. Digits: the remaining bottom part, at least half the height. Keep a 1 px gap at 16 px.
  - Charging: the glyph shifts left and the bolt takes the right ~40 % of the top row. Reuse the existing `Bolt` polygon and the transparent-margin cut-out.
  - Digits: reuse `LabelPath` inside the `Digits` box. Use the condensed fonts for "100".
  - Glyph strokes: about `size / 12` wide, at least 1 px. Use the same colour as the digits, red when `Low`.
  - Add `reading.Kind` to the `TrayBatteryIcons.Show` cache key.

- [ ] **Step 4: Run the suite and look at the previews.**
  - Run `dotnet test windows/tests/InputBridge.Windows.Tests`. Expected: all pass.
  - Open a few PNGs from `%TEMP%\InputBridge-icon-preview`. At 16 px the glyph must be recognisable and the two digits readable. Adjust the proportions if not.

- [ ] **Step 5: Commit.** Message: `Draw the device type above the percentage in Windows tray icons`.

---

### Task 4: The Mac drops battery sharing and logs the keyboard read

**Files:**
- Delete:
  - `macos/Sources/InputBridgeMac/Battery/BatteryMerge.swift` → replaced by `macos/Sources/InputBridgeMac/Battery/BatteryOrder.swift`
  - `macos/Tests/InputBridgeMacTests/BatteryMergeTests.swift` → replaced by `BatteryOrderTests.swift`
  - `shared/fixtures/battery-readings.json`
- Modify:
  - `macos/Sources/InputBridgeMac/Battery/BatteryModels.swift`: remove `Codable`, `CodingKeys`, `init(from:)`, `encode(to:)`, `BatteryEnvelope`, `BatteryWireDate` and `remote`.
  - `macos/Sources/InputBridgeMac/Battery/BatteryMonitor.swift`
  - `macos/Sources/InputBridgeMac/Battery/BatterySource.swift`: keep only the protocol and add `BatteryLog`. Move `LogitechBluetoothBatterySource` into `LogitechBluetoothKeyboard.swift` and log in its `read`.
  - `macos/Sources/InputBridgeMac/LogitechBluetoothKeyboard.swift`: log in `batteryReading`.
  - `macos/Sources/InputBridgeMac/ControllerClient.swift`: remove `fetchBattery`, `postBattery` and `acceptedByController`.
  - `macos/Sources/InputBridgeMac/Battery/BatteryStrip.swift` and `macos/Sources/InputBridgeMac/Battery/BatteryStatusItem.swift`: drop the `.remote` tone and `" (on Windows)"`. Both files are deleted in Tasks 5 and 6.
  - `macos/Sources/InputBridgeMac/AppModel.swift` (monitor construction, lines ~47–52; doc comment, line ~20)
  - `macos/Sources/InputBridgeMac/InputBridgeMacApp.swift` (Battery section footer, line ~473)
  - `macos/project.yml`: test sources. Swap `BatteryMerge.swift` for `BatteryOrder.swift` and remove the fixture resource.
  - `macos/Tests/InputBridgeMacTests/BatteryParsingTests.swift`: delete the `// MARK: Wire format` section. `BatteryStripTests.swift`: delete `testRemoteWinsOverLow`.

**Interfaces:**
- Produces: `enum BatteryOrder { static func sorted(_ readings: [BatteryReading]) -> [BatteryReading] }`. Order: keyboard, mouse, headset, trackpad, other, then by name (case-insensitive), then by deviceId.
- Produces: `BatteryOrder.sourcesToRead(all: [BatterySource], enabled: Bool) -> [BatterySource]`. It returns `all` when enabled, otherwise `[]`.
- Produces: `BatteryMonitor.init(sources: [BatterySource], enabled: Bool)`. Each cycle reads `BatteryOrder.sourcesToRead(all: sources, enabled: enabled)`.
  - `visible` is `BatteryOrder.sorted(local)` when enabled, otherwise `[]`. A disabled monitor reads nothing.
  - It keeps the 5-minute loop, wake, Bluetooth connect/disconnect, `refresh()`, `refresh(after:)` and `BatteryRefreshGate`.
- Produces: `enum BatteryLog { static let logger = Logger(subsystem: "com.inputbridge.mac", category: "battery") }` in `BatterySource.swift`.

- [ ] **Step 1: Move the ordering test and pin the disabled rule.**
  - `BatteryOrderTests.testOrdersKeyboardMouseHeadsetTrackpadOtherThenName` keeps the assertions of the old `testOrdersKeyboardHeadsetTrackpadThenName`, with a mouse added.
  - Delete the remote merge tests.
  - Add `BatteryOrderTests.testDisabledReadsNothing`. It asserts that `BatteryOrder.sourcesToRead(all: [a, b], enabled: false)` is empty and that `BatteryOrder.sourcesToRead(all: [a, b], enabled: true)` has 2 entries. `a` and `b` are stub `BatterySource`s.
  - Add `Sources/InputBridgeMac/Battery/BatterySource.swift` to the test target sources in `project.yml`, so the stubs can conform to `BatterySource`. Keep that file to Foundation and `os` imports; `LogitechBluetoothBatterySource` calls `LogitechBluetoothKeyboard`, which the hostless target lacks. So move `LogitechBluetoothBatterySource` into `LogitechBluetoothKeyboard.swift` and leave only the protocol and `BatteryLog` in `BatterySource.swift`.

- [ ] **Step 2: Remove sharing and add logging.**
  - In `BatteryMonitor`, delete `controller`, `offer`, `remote`, `remoteGeneration`, `remoteLoop`, `pollRemote`, `exchange`, `sayGoodbye`, the sleep and terminate observers, and `goodbyeTimeout`/`remoteInterval`.
  - Log at these points in `batteryReading`:
    - Input Monitoring denied: `.error`.
    - No HID++ collection matching the pattern: `.info`, listing the product names seen.
    - The matched name: `.info`.
    - Each battery feature found, with its index: `.debug`.
    - A parse returning nil: `.error`.
    - Any thrown error: `.error`, from `LogitechBluetoothBatterySource.read`.
    - The final percent: `.info`.
  - New Battery footer text: `Shows the G915/G913 on Bluetooth, AirPods and Apple trackpads, mice and keyboards connected to this Mac. A device disappears as soon as it disconnects.`

- [ ] **Step 3: Check for leftovers.**
  - Run `git grep -n "fetchBattery\|postBattery\|BatteryEnvelope\|BatteryWireDate\|\.remote\b\|battery-readings" -- macos shared`. Expected: no output.
  - Push the branch and watch the CI `macos` job. Expected: `** TEST SUCCEEDED **` and `Executed N tests, with 0 failures`.

- [ ] **Step 4: Commit** before the push. Message: `Stop sharing battery readings on the Mac and log the keyboard read`.

---

### Task 5: Mac battery columns and the AirPods layout setting

**Files:**
- Delete: `macos/Sources/InputBridgeMac/Battery/BatteryStrip.swift`, `macos/Tests/InputBridgeMacTests/BatteryStripTests.swift`
- Create: `macos/Sources/InputBridgeMac/Battery/MenuBarColumns.swift`, `macos/Tests/InputBridgeMacTests/MenuBarColumnsTests.swift`
- Modify:
  - `macos/project.yml`: test sources, `BatteryStrip.swift` → `MenuBarColumns.swift`.
  - `macos/Sources/InputBridgeMac/AppModel.swift`: the `airPodsSeparate` setting.
  - `macos/Sources/InputBridgeMac/InputBridgeMacApp.swift`: Battery section toggle.
  - `macos/Sources/InputBridgeMac/Battery/BatteryStatusItem.swift`: build its one-line title from columns until Task 6 deletes it.

**Interfaces:**
- Consumes: `BatteryReading`, `BatteryComponent`, `DeviceKind` (BatteryModels.swift). Readings arrive already sorted (`BatteryOrder`, Task 4).
- Produces:

```swift
struct MenuBarColumn: Equatable {
    enum Tone: Equatable { case normal, low, charging }
    let symbol: String   // SF Symbol name
    let text: String     // always "<percent>%"
    let tone: Tone
}
enum AirPodsLayout { case separate, combined }
enum MenuBarColumns {
    static let lowPercent = 15
    static let caseSymbol = "airpodspro.chargingcase.wireless"
    /// Symbol to draw when the first one is missing on this macOS version.
    static let fallbackSymbols: [String: String]
    static func columns(_ readings: [BatteryReading], airPods: AirPodsLayout) -> [MenuBarColumn]
    static func symbol(for kind: DeviceKind) -> String
    static func tone(_ component: BatteryComponent) -> MenuBarColumn.Tone
    /// One line per device, e.g. "AirPods Pro: L 90%, R 85%, case 60%" or "G915 TKL: 82% charging".
    static func tooltip(_ readings: [BatteryReading]) -> String
}
```

- Produces (AppModel): `@Published var airPodsSeparate: Bool`, stored under `battery-airpods-separate`, default `true`.

- [ ] **Step 1: Write the failing tests** (`MenuBarColumnsTests.swift`; reuse the `reading`/`level` helpers from the deleted strip tests)

```swift
func testKeyboardIsOneColumnWithPercent()       // [G915 82] → [MenuBarColumn(symbol: "keyboard", text: "82%", tone: .normal)]
func testAirPodsSeparateShowsLeftRightCaseInOrder() // components case60, R85, L90 → airpod.left 90%, airpod.right 85%, caseSymbol 60%
func testAirPodsCombinedShowsLowerEarbudAndHidesCase() // L90 R85 case60, .combined → [("airpods", "85%", .normal)]
func testAirPodsCombinedWithOneEarbud()          // R40 + case70, .combined → [("airpods", "40%", .normal)]
func testAirPodsCombinedLowEarbudIsLow()         // L10 R80, .combined → tone .low
func testFifteenPercentNotChargingIsLow()        // tone(15, false) == .low
func testFifteenPercentChargingIsCharging()      // tone(15, true) == .charging; tone(16, false) == .normal
func testPercentIsClamped()                      // 140 → "100%", -5 → "0%"
func testSymbolsPerKind()                        // keyboard, computermouse, airpods, rectangle.and.hand.point.up.left, battery.100
func testTooltipListsEveryComponent()            // AirPods L90 R85 case60 + G915 82 charging →
                                                 // "AirPods Pro: L 90%, R 85%, case 60%\nG915 TKL: 82% charging"
```

- [ ] **Step 2: Push and confirm the failure in CI** (compile error: `MenuBarColumns` missing). Doing this together with Step 4 in one push is acceptable if CI time is the bottleneck. Say so in the report.

- [ ] **Step 3: Implement `MenuBarColumns`, the setting and the toggle.**
  - `fallbackSymbols`: `"airpods"`, `"airpod.left"` and `"airpod.right"` → `"headphones"`; `caseSymbol` → `"case"`; `"rectangle.and.hand.point.up.left"` → `"hand.point.up.left"`.
  - Toggle in the Battery section: `Toggle("Show AirPods left, right and case separately", isOn: $model.airPodsSeparate).disabled(!model.batteryIndicatorsEnabled)`.
  - `BatteryStatusItem.show` takes `[MenuBarColumn]` plus the tooltip string. AppModel passes `MenuBarColumns.columns(readings, airPods: airPodsSeparate ? .separate : .combined)`, and redraws when either value changes.

- [ ] **Step 4: Push and verify.** In CI, the `macos` job reports `Executed N tests, with 0 failures`, with the `MenuBarColumnsTests` cases among them.

- [ ] **Step 5: Commit.** Message: `Turn battery readings into menu bar columns with an AirPods layout option`.

---

### Task 6: One Mac menu bar item: icon, columns, panel on click

**Files:**
- Create:
  - `macos/Sources/InputBridgeMac/StatusBar/StatusItemView.swift`
  - `macos/Sources/InputBridgeMac/StatusBar/StatusBarController.swift`
  - `macos/Sources/InputBridgeMac/StatusBar/SetupWindowController.swift`
- Delete: `macos/Sources/InputBridgeMac/Battery/BatteryStatusItem.swift`
- Modify:
  - `macos/Sources/InputBridgeMac/InputBridgeMacApp.swift`: the app scene, `MenuBarLabel`, and `MenuBarPanel`'s `openWindow`.
  - `macos/Sources/InputBridgeMac/AppModel.swift`: remove `batteryItem`, `batteryStrip` and `setOpenSetupWindow`; publish the columns.

**Interfaces:**
- Consumes: `MenuBarColumns.columns(_:airPods:)` and `tooltip(_:)` (Task 5), `MenuBarImage.make(badged:)` (InputBridgeMacApp.swift).
- Produces (AppModel):
  - `@Published private(set) var batteryColumns: [MenuBarColumn]` and `@Published private(set) var batteryTooltip: String`.
  - Both are derived from `battery.$visible` combined with `$airPodsSeparate`. Both are empty when there are no readings or the switch is off.
- Produces:
  - `final class StatusItemView: NSView`, with `var icon: NSImage` and `var columns: [MenuBarColumn]`. Each property's `didSet` invalidates the intrinsic size and the display.
  - `@MainActor final class StatusBarController: NSObject`, with `init(model: AppModel, settings: SetupWindowController)`.
  - `@MainActor final class SetupWindowController`, with `init(model: AppModel)` and `func show()`.
  - `MenuBarPanel(model:updates:openSettings:)`, where `openSettings: () -> Void`.

- [ ] **Step 1: Implement `StatusItemView`.**
  - Draw the icon at 18×18, vertically centred, at x = 0. Each column starts 6 pt after the previous element.
  - A column is as wide as the wider of its two rows, and the rows are centred:
    - Top row: the SF Symbol, about 9 pt, with `MenuBarColumns.fallbackSymbols` applied, plus a ~7 pt `bolt.fill` when `.charging`.
    - Bottom row: `text` in `NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)`.
  - Colour: `.labelColor`, or `.systemRed` when `.low`. Symbols use the palette configuration in the same colour.
  - Redraw in `viewDidChangeEffectiveAppearance`, so the colours follow the menu bar's own appearance.
  - With no columns, the width is just the icon's.

- [ ] **Step 2: Implement `SetupWindowController`.** Follow the `CameraSetupWindowController` pattern:
  - `NSWindow`, title `InputBridge`, style `[.titled, .closable, .miniaturizable, .resizable]`, `contentMinSize` 780×540.
  - `NSHostingController(rootView: SetupView(model:updates:))`, `isReleasedWhenClosed = false`, reused on later `show()` calls.

- [ ] **Step 3: Implement `StatusBarController`.**
  - Create an `NSStatusItem(length: NSStatusItem.variableLength)` and pin `StatusItemView` into its button with Auto Layout.
  - Set `item.length` to the view's intrinsic width on every update.
  - Clicking the button toggles an `NSPopover`:
    - `behavior = .transient`.
    - `contentViewController = NSHostingController(rootView: MenuBarPanel(model:updates:openSettings:))`.
    - `openSettings` closes the popover, calls `NSApp.activate(ignoringOtherApps: true)`, then `settings.show()`.
  - Subscribe to `model.$updateAvailable` (icon = `MenuBarImage.make(badged:)`), `model.$batteryColumns` and `model.$batteryTooltip`.
    - Button `toolTip` is the tooltip.
    - Accessibility label: `"InputBridge"` (plus `", update available"`), then the tooltip lines.

- [ ] **Step 4: Rewire the app.**
  - `InputBridgeMacApp.body` becomes `Settings { EmptyView() }`, with `@NSApplicationDelegateAdaptor(AppDelegate.self)`.
  - `AppDelegate.applicationDidFinishLaunching` creates `AppModel`, `SetupWindowController(model:)` and `StatusBarController(model:settings:)`, and keeps strong references to all three.
  - Delete `MenuBarLabel`. Keep `MenuBarImage`.
  - In `MenuBarPanel`, replace `@Environment(\.openWindow)` and `.onAppear { model.setOpenSetupWindow … }` with the `openSettings` closure.
  - Delete `BatteryStatusItem.swift` and the AppModel members listed above.

- [ ] **Step 5: Check for leftovers, then push and verify.**
  - Run `git grep -n "MenuBarExtra\|openWindow\|BatteryStatusItem\|setOpenSetupWindow" -- macos/Sources`. Expected: no output.
  - Push. Expected: the CI `macos` job builds the app and runs all tests with 0 failures.

- [ ] **Step 6: Note the on-device checks for the beta checklist.** No automated test covers drawing. The user checks:
  - Light and dark menu bar, including a light-mode menu bar over a dark wallpaper.
  - The icon stays leftmost and the columns sit to its right.
  - A click opens the panel, and Settings… opens the window.
  - The update badge.
  - Turning "Show battery levels" off leaves only the icon.
  - Turning the AirPods toggle to combined shows one column.
  - Disconnecting a device removes its column at once.

- [ ] **Step 7: Commit.** Message: `Merge the battery columns into a single InputBridge menu bar item`.

---

### Task 7: Docs and final verification

**Files:**
- Modify:
  - `CHANGELOG.md`: rewrite the `## Unreleased` battery bullets.
  - `README.md` and `README_TR.md`: update the battery bullet.
  - `docs/superpowers/specs/2026-11-26-battery-menubar-redesign-design.md`: change the status to `onaylandı, uygulandı`.

- [ ] **Step 1: Update the docs.**
  - CHANGELOG `Unreleased` describes the final behaviour:
    - Windows tray icons show the device type above the percentage.
    - The Mac shows one menu bar item: the icon, then a column per device. AirPods are separate or combined, set in Devices.
    - Devices disappear when they disconnect, and each machine shows only its own devices.
    - A cabled G915 is read once.
  - Remove the old sharing and faded bullets. Keep the Windows 11 tray-pin note.
  - README/README_TR: same facts in one bullet each. Drop "The keyboard's level is shared".

- [ ] **Step 2: Run the full verification.**
  - Run `dotnet test windows/tests/InputBridge.Windows.Tests`. Expected: all pass.
  - Run `dotnet build windows/src/InputBridge.Windows -c Release -warnaserror`. Expected: 0 warnings.
  - Push. Expected: both CI jobs are green.

- [ ] **Step 3: Commit.** Message: `Describe the second round of battery indicators`.
