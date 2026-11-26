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
            [ProfilerDevice(name: "Ardanuc's AirPods Pro", left: 90, right: 85, caseLevel: 60)])
    }

    func testProfilerIgnoresNotConnectedAndMissingCase() {
        let withoutCase = airPodsProfile
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("Case Battery Level") }
            .joined(separator: "\n")
        XCTAssertEqual(
            SystemProfilerParser.connectedEarbuds(withoutCase),
            [ProfilerDevice(name: "Ardanuc's AirPods Pro", left: 90, right: 85, caseLevel: nil)])
        XCTAssertEqual(SystemProfilerParser.connectedEarbuds(notConnectedOnlyProfile), [])
        XCTAssertEqual(SystemProfilerParser.connectedEarbuds(""), [])
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
