import Foundation

/// Pure parsers for HID++ 2.0 battery feature payloads. Mirrors the Windows `HidppBattery`:
/// identical bytes give identical results on both machines.
enum HIDPPBattery {
    static let featureUnifiedBattery: UInt16 = 0x1004
    static let featureBatteryStatus: UInt16 = 0x1000
    static let featureBatteryVoltage: UInt16 = 0x1001

    // Generic 1-cell Li-ion discharge curve (mV descending, percent).
    private static let voltageCurve: [(mv: Int, pct: Int)] = [
        (4200, 100), (4100, 90), (4000, 80), (3900, 65), (3800, 50), (3750, 40),
        (3700, 30), (3650, 20), (3600, 10), (3500, 5), (3400, 0),
    ]

    /// Parses get_status (fn 1) params [soc, levelFlags, chargingStatus, externalPower].
    static func parseUnifiedStatus(_ p: [UInt8], stateOfChargeSupported: Bool) -> BatteryComponent? {
        guard p.count >= 3 else { return nil }
        let status = p[2]
        guard status < 4 else { return nil }
        let charging = status == 1 || status == 2
        let percent: Int
        if status == 3 {
            percent = 100
        } else if stateOfChargeSupported {
            percent = min(Int(p[0]), 100)
        } else {
            let flags = p[1]
            if (flags & 0x08) != 0 {
                percent = 100
            } else if (flags & 0x04) != 0 {
                percent = 60
            } else if (flags & 0x02) != 0 {
                percent = 20
            } else if (flags & 0x01) != 0 {
                percent = 5
            } else {
                percent = 0
            }
        }
        return BatteryComponent(role: .main, percent: percent, charging: charging)
    }

    /// Returns whether the device reports state of charge (capabilities bit 1).
    static func parseUnifiedCapabilities(_ p: [UInt8]) -> Bool {
        p.count >= 2 && (p[1] & 0x02) != 0
    }

    /// Parses BATTERY_STATUS params [level, nextLevel, status].
    static func parseBatteryStatus(_ p: [UInt8]) -> BatteryComponent? {
        guard p.count >= 3 else { return nil }
        let status = p[2]
        guard status < 5 else { return nil }
        let charging = status == 1 || status == 2 || status == 4
        let percent = status == 3 ? 100 : min(Int(p[0]), 100)
        return BatteryComponent(role: .main, percent: percent, charging: charging)
    }

    /// Parses BATTERY_VOLTAGE params [mV hi, mV lo, flags].
    static func parseVoltage(_ p: [UInt8]) -> BatteryComponent? {
        guard p.count >= 3 else { return nil }
        let millivolts = (Int(p[0]) << 8) | Int(p[1])
        let charging = (p[2] & 0x80) != 0
        return BatteryComponent(role: .main, percent: voltageToPercent(millivolts), charging: charging)
    }

    static func voltageToPercent(_ millivolts: Int) -> Int {
        let curve = voltageCurve
        if millivolts >= curve[0].mv { return curve[0].pct }
        if millivolts <= curve[curve.count - 1].mv { return curve[curve.count - 1].pct }
        for i in 1..<curve.count where millivolts >= curve[i].mv {
            let lo = curve[i], hi = curve[i - 1]
            let interpolated = Double(lo.pct) + Double((hi.pct - lo.pct) * (millivolts - lo.mv)) / Double(hi.mv - lo.mv)
            // .NET Math.Round rounds half to even; match it so both machines show the same number.
            return Int(interpolated.rounded(.toNearestOrEven))
        }
        return 0
    }

    /// Maps the DEVICE_NAME (0x0005) fn 2 device type to a DeviceKind.
    static func kindFromHidppType(_ deviceType: UInt8) -> DeviceKind {
        switch deviceType {
        case 0: return .keyboard
        case 3: return .mouse
        case 4: return .trackpad
        case 8: return .headset
        default: return .other
        }
    }
}

struct ProfilerDevice: Equatable {
    let name: String
    let left: Int?
    let right: Int?
    let caseLevel: Int?
}

/// Reads AirPods-style battery levels from `system_profiler SPBluetoothDataType` output (run with `LC_ALL=C`).
enum SystemProfilerParser {
    /// Devices under `Connected:` that report a left or right earbud level; `Not Connected:` is ignored.
    static func connectedEarbuds(_ output: String) -> [ProfilerDevice] {
        var devices: [ProfilerDevice] = []
        var connectedIndent: Int?
        var deviceIndent: Int?
        var deviceName: String?
        var levels: [String: Int] = [:]

        func finishDevice() {
            if let name = deviceName, levels["Left Battery Level"] != nil || levels["Right Battery Level"] != nil {
                devices.append(ProfilerDevice(
                    name: name,
                    left: levels["Left Battery Level"],
                    right: levels["Right Battery Level"],
                    caseLevel: levels["Case Battery Level"]))
            }
            deviceName = nil
            levels = [:]
        }

        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            let text = rawLine.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count

            if let sectionIndent = connectedIndent {
                if indent > sectionIndent {
                    if text.hasSuffix(":"), deviceIndent == nil || indent <= deviceIndent! {
                        finishDevice()
                        deviceIndent = indent
                        deviceName = String(text.dropLast())
                    } else if deviceName != nil, let separator = text.range(of: ": ") {
                        let key = String(text[..<separator.lowerBound])
                        let value = text[separator.upperBound...]
                        if value.hasSuffix("%"), let percent = Int(value.dropLast()) {
                            levels[key] = percent
                        }
                    }
                    continue
                }
                finishDevice()
                connectedIndent = nil
                deviceIndent = nil
            }
            if text == "Connected:" {
                connectedIndent = indent
            }
        }
        finishDevice()
        return devices
    }
}

/// Builds readings for Apple peripherals found as `AppleDeviceManagementHIDEventService` (Product, BatteryPercent).
enum AppleHIDParser {
    static func reading(product: String, batteryPercent: Int?, charging: Bool) -> BatteryReading? {
        guard let batteryPercent else { return nil }
        let kind: DeviceKind
        if product.contains("Trackpad") {
            kind = .trackpad
        } else if product.contains("Mouse") {
            kind = .mouse
        } else if product.contains("Keyboard") {
            kind = .keyboard
        } else {
            kind = .other
        }
        return BatteryReading(
            deviceId: "apple:" + product,
            name: product,
            kind: kind,
            components: [BatteryComponent(role: .main, percent: min(max(batteryPercent, 0), 100), charging: charging)],
            readAt: Date())
    }
}
