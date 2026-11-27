import Foundation
import XCTest

private let airPodsProfile = """
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
"""

private let notConnectedOnlyProfile = """
Bluetooth:

      Not Connected:
          Old AirPods:
              Left Battery Level: 10%
"""

/// This Mac's real output: Turkish number format puts the percent sign first, even with `LC_ALL=C`.
private let turkishProfile = """
Bluetooth:

      Connected:
          Ardanuc’s Magic Trackpad:
              Address: 3C:50:02:BF:32:A8
              Vendor ID: 0x004C
              Product ID: 0x0324
              Minor Type: Magic Trackpad
          G915 TKL:
              Address: E8:16:AB:7C:CE:A2
              Vendor ID: 0x046D
              Product ID: 0xB35F
              Battery Level: %100
              Minor Type: Keyboard
          AirPods Pro:
              Address: 11:22:33:44:55:66
              Vendor ID: 0x004C
              Case Battery Level: %100
              Left Battery Level: %80
              Right Battery Level: % 79
              Minor Type: Headphones
          Logi Z407:
              Vendor ID: 0x03E0
              Minor Type: Headset
      Not Connected:
          Old Mouse:
              Battery Level: %10
"""

private let keyboardPattern = try! NSRegularExpression(pattern: "G915|G913", options: [.caseInsensitive])

final class BatteryParsingTests: XCTestCase {
    // MARK: HID++ (1:1 port of windows/tests/InputBridge.Windows.Tests/HidppBatteryTests.cs)

    func testUnifiedReadsSocAndCharging() {
        XCTAssertEqual(
            HIDPPBattery.parseUnifiedStatus([0x52, 0x08, 0x01, 0x01], stateOfChargeSupported: true),
            BatteryComponent(role: .main, percent: 82, charging: true))
    }

    func testUnifiedNotCharging() {
        XCTAssertEqual(
            HIDPPBattery.parseUnifiedStatus([0x0F, 0x02, 0x00, 0x00], stateOfChargeSupported: true),
            BatteryComponent(role: .main, percent: 15, charging: false))
    }

    func testUnifiedChargeCompleteIsFullNotCharging() {
        XCTAssertEqual(
            HIDPPBattery.parseUnifiedStatus([0x64, 0x08, 0x03, 0x01], stateOfChargeSupported: true),
            BatteryComponent(role: .main, percent: 100, charging: false))
    }

    func testUnifiedLevelFlagsWhenNoSoc() {
        let cases: [(flags: UInt8, percent: Int)] = [(0x08, 100), (0x04, 60), (0x02, 20), (0x01, 5)]
        for item in cases {
            XCTAssertEqual(
                HIDPPBattery.parseUnifiedStatus([0x00, item.flags, 0x00, 0x00], stateOfChargeSupported: false)?.percent,
                item.percent,
                "flags \(item.flags)")
        }
    }

    func testUnifiedErrorStatusIsNull() {
        XCTAssertNil(HIDPPBattery.parseUnifiedStatus([0x52, 0x08, 0x04, 0x00], stateOfChargeSupported: true))
    }

    func testUnifiedCapabilitiesSocBit() {
        XCTAssertTrue(HIDPPBattery.parseUnifiedCapabilities([0x0F, 0x02]))
        XCTAssertFalse(HIDPPBattery.parseUnifiedCapabilities([0x0F, 0x01]))
    }

    func testStatusDischarging() {
        XCTAssertEqual(
            HIDPPBattery.parseBatteryStatus([0x32, 0x1E, 0x00]),
            BatteryComponent(role: .main, percent: 50, charging: false))
    }

    func testStatusChargingCodes() {
        let codes: [UInt8] = [1, 2, 4]
        for status in codes {
            XCTAssertEqual(HIDPPBattery.parseBatteryStatus([0x32, 0x1E, status])?.charging, true, "status \(status)")
        }
    }

    func testStatusFullIs100() {
        XCTAssertEqual(HIDPPBattery.parseBatteryStatus([0x5A, 0x00, 0x03])?.percent, 100)
    }

    func testStatusInvalidBatteryIsNull() {
        XCTAssertNil(HIDPPBattery.parseBatteryStatus([0x32, 0x1E, 0x05]))
    }

    func testVoltage4000mVCharging() {
        XCTAssertEqual(
            HIDPPBattery.parseVoltage([0x0F, 0xA0, 0x80]),
            BatteryComponent(role: .main, percent: 80, charging: true))
    }

    func testVoltage3700mV() {
        XCTAssertEqual(
            HIDPPBattery.parseVoltage([0x0E, 0x74, 0x00]),
            BatteryComponent(role: .main, percent: 30, charging: false))
    }

    func testVoltageCurve() {
        let cases: [(millivolts: Int, percent: Int)] = [(4300, 100), (4200, 100), (3725, 35), (3400, 0), (3000, 0)]
        for item in cases {
            XCTAssertEqual(HIDPPBattery.voltageToPercent(item.millivolts), item.percent, "\(item.millivolts) mV")
        }
    }

    func testShortPayloadIsNull() {
        XCTAssertNil(HIDPPBattery.parseVoltage([0x0F]))
    }

    func testKindFromType() {
        let cases: [(type: UInt8, kind: DeviceKind)] = [
            (0, .keyboard), (3, .mouse), (4, .trackpad), (8, .headset), (7, .other),
        ]
        for item in cases {
            XCTAssertEqual(HIDPPBattery.kindFromHidppType(item.type), item.kind, "type \(item.type)")
        }
    }

    // MARK: system_profiler SPBluetoothDataType

    func testProfilerReadsAirPods() {
        XCTAssertEqual(
            SystemProfilerParser.connectedEarbuds(airPodsProfile),
            [ProfilerDevice(name: "Ardanuc's AirPods Pro", left: 90, right: 85, caseLevel: 60, minorType: "Headphones")])
    }

    func testProfilerIgnoresNotConnectedAndMissingCase() {
        let withoutCase = airPodsProfile
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("Case Battery Level") }
            .joined(separator: "\n")
        XCTAssertEqual(
            SystemProfilerParser.connectedEarbuds(withoutCase),
            [ProfilerDevice(name: "Ardanuc's AirPods Pro", left: 90, right: 85, caseLevel: nil, minorType: "Headphones")])
        XCTAssertEqual(SystemProfilerParser.connectedEarbuds(notConnectedOnlyProfile), [])
        XCTAssertEqual(SystemProfilerParser.connectedEarbuds(""), [])
    }

    func testProfilerReadsPercentSignFirst() {
        XCTAssertEqual(
            SystemProfilerParser.connectedEarbuds(turkishProfile),
            [ProfilerDevice(name: "AirPods Pro", left: 80, right: 79, caseLevel: 100, vendorID: "0x004C", minorType: "Headphones")])
    }

    func testProfilerReadsSingleBatteryLevelOfConnectedDevices() {
        let devices = SystemProfilerParser.connectedDevices(turkishProfile)
        XCTAssertEqual(devices.map(\.name), ["G915 TKL", "AirPods Pro"])
        XCTAssertEqual(devices.first, ProfilerDevice(name: "G915 TKL", main: 100, vendorID: "0x046D", minorType: "Keyboard"))
    }

    func testProfilerReadingsKeyboardTakesTheSharedKeyboardId() {
        let now = Date(timeIntervalSince1970: 0)
        let readings = SystemProfilerParser.readings(turkishProfile, keyboardPattern: keyboardPattern, readAt: now)
        XCTAssertEqual(readings, [
            BatteryReading(
                deviceId: BatteryIds.sharedKeyboard, name: "G915 TKL", kind: .keyboard,
                components: [BatteryComponent(role: .main, percent: 100, charging: false)], readAt: now),
            BatteryReading(
                deviceId: "apple:AirPods Pro", name: "AirPods Pro", kind: .headset,
                components: [
                    BatteryComponent(role: .left, percent: 80, charging: false),
                    BatteryComponent(role: .right, percent: 79, charging: false),
                    BatteryComponent(role: .case, percent: 100, charging: false),
                ],
                readAt: now),
        ])
    }

    func testProfilerReadingsLeaveApplePeripheralsToTheIORegistry() {
        // The IORegistry reads Apple mice, keyboards and trackpads (with their product name); the profiler would
        // list them again under their Bluetooth name.
        let profile = """
              Connected:
                  Magic Mouse:
                      Vendor ID: 0x004C
                      Battery Level: 40%
                      Minor Type: Mouse
                  MX Master 3:
                      Vendor ID: 0x046D
                      Battery Level: 55%
                      Minor Type: Mouse
            """
        let readings = SystemProfilerParser.readings(profile, keyboardPattern: keyboardPattern, readAt: Date())
        XCTAssertEqual(readings.map(\.name), ["MX Master 3"])
        XCTAssertEqual(readings.first?.deviceId, "bluetooth:MX Master 3")
        XCTAssertEqual(readings.first?.kind, .mouse)
    }

    func testProfilerKindFromMinorType() {
        XCTAssertEqual(SystemProfilerParser.kind(minorType: "Keyboard"), .keyboard)
        XCTAssertEqual(SystemProfilerParser.kind(minorType: "Mouse"), .mouse)
        XCTAssertEqual(SystemProfilerParser.kind(minorType: "Magic Trackpad"), .trackpad)
        XCTAssertEqual(SystemProfilerParser.kind(minorType: "Headphones"), .headset)
        XCTAssertEqual(SystemProfilerParser.kind(minorType: "Headset"), .headset)
        XCTAssertEqual(SystemProfilerParser.kind(minorType: nil), .other)
    }

    // MARK: Apple HID (AppleDeviceManagementHIDEventService)

    func testAppleHIDTrackpad() throws {
        let reading = try XCTUnwrap(AppleHIDParser.reading(product: "Magic Trackpad", batteryPercent: 64, charging: false))
        XCTAssertEqual(reading.kind, .trackpad)
        XCTAssertEqual(reading.deviceId, "apple:Magic Trackpad")
        XCTAssertEqual(reading.name, "Magic Trackpad")
        XCTAssertEqual(reading.components, [BatteryComponent(role: .main, percent: 64, charging: false)])

        XCTAssertNil(AppleHIDParser.reading(product: "Magic Trackpad", batteryPercent: nil, charging: false))
    }

    func testAppleHIDKindFromProduct() {
        XCTAssertEqual(AppleHIDParser.reading(product: "Magic Mouse", batteryPercent: 50, charging: false)?.kind, .mouse)
        XCTAssertEqual(AppleHIDParser.reading(product: "Magic Keyboard with Touch ID", batteryPercent: 50, charging: true)?.kind, .keyboard)
        XCTAssertEqual(AppleHIDParser.reading(product: "Pencil", batteryPercent: 50, charging: false)?.kind, .other)
    }
}
