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

/// One connected device from `system_profiler SPBluetoothDataType`, with the battery levels it lists.
struct ProfilerDevice: Equatable {
    let name: String
    var left: Int? = nil
    var right: Int? = nil
    var caseLevel: Int? = nil
    /// `Battery Level`: a device with one battery, e.g. a Bluetooth LE keyboard reporting the GATT battery service.
    var main: Int? = nil
    /// `Vendor ID`, e.g. `0x046D`.
    var vendorID: String? = nil
    /// `Minor Type`, e.g. `Keyboard`, `Mouse`, `Headphones`.
    var minorType: String? = nil

    var hasEarbuds: Bool { left != nil || right != nil }
}

/// Reads battery levels from `system_profiler SPBluetoothDataType` output. The percent sign can come first or last
/// (`%80` in Turkish, `80%` in English): system_profiler formats numbers with the user's region even with `LC_ALL=C`.
enum SystemProfilerParser {
    static let appleVendorID = "0x004C"

    /// Devices under `Connected:` that report a left or right earbud level; `Not Connected:` is ignored.
    static func connectedEarbuds(_ output: String) -> [ProfilerDevice] {
        connectedDevices(output).filter(\.hasEarbuds)
    }

    /// Devices under `Connected:` that report any battery level, in output order; `Not Connected:` is ignored.
    static func connectedDevices(_ output: String) -> [ProfilerDevice] {
        var devices: [ProfilerDevice] = []
        var connectedIndent: Int?
        var deviceIndent: Int?
        var device: ProfilerDevice?

        func finishDevice() {
            if let device, device.hasEarbuds || device.main != nil {
                devices.append(device)
            }
            device = nil
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
                        device = ProfilerDevice(name: String(text.dropLast()))
                    } else if device != nil, let separator = text.range(of: ": ") {
                        let key = String(text[..<separator.lowerBound])
                        let value = String(text[separator.upperBound...])
                        switch key {
                        case "Left Battery Level": device?.left = percent(value)
                        case "Right Battery Level": device?.right = percent(value)
                        case "Case Battery Level": device?.caseLevel = percent(value)
                        case "Battery Level": device?.main = percent(value)
                        case "Vendor ID": device?.vendorID = value
                        case "Minor Type": device?.minorType = value
                        default: break
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

    /// Readings for the connected devices:
    /// - earbuds (left/right, and the case when listed) as one headset reading;
    /// - a single `Battery Level` of a non-Apple device, e.g. the G915 on Bluetooth LE. Apple mice, keyboards and
    ///   trackpads are left to the IORegistry, which names them by product. A device matching `keyboardPattern`
    ///   gets the shared keyboard id, so the HID++ reading of the same keyboard (which knows when it charges) can
    ///   replace it.
    static func readings(_ output: String, keyboardPattern: NSRegularExpression, readAt: Date) -> [BatteryReading] {
        connectedDevices(output).compactMap { device -> BatteryReading? in
            if device.hasEarbuds {
                var components: [BatteryComponent] = []
                if let left = device.left { components.append(component(.left, left)) }
                if let right = device.right { components.append(component(.right, right)) }
                if let caseLevel = device.caseLevel { components.append(component(.`case`, caseLevel)) }
                return BatteryReading(
                    deviceId: "apple:" + device.name, name: device.name, kind: .headset,
                    components: components, readAt: readAt)
            }
            guard let main = device.main, device.vendorID?.uppercased() != appleVendorID.uppercased() else { return nil }
            let range = NSRange(device.name.startIndex..<device.name.endIndex, in: device.name)
            let isKeyboard = keyboardPattern.firstMatch(in: device.name, options: [], range: range) != nil
            return BatteryReading(
                deviceId: isKeyboard ? BatteryIds.sharedKeyboard : "bluetooth:" + device.name,
                name: device.name,
                kind: isKeyboard ? .keyboard : kind(minorType: device.minorType),
                components: [component(.main, main)],
                readAt: readAt)
        }
    }

    static func kind(minorType: String?) -> DeviceKind {
        guard let type = minorType?.lowercased() else { return .other }
        if type.contains("keyboard") { return .keyboard }
        if type.contains("mouse") { return .mouse }
        if type.contains("trackpad") { return .trackpad }
        if type.contains("head") || type.contains("earbud") { return .headset }
        return .other
    }

    /// `80%`, `%80`, `80 %` or `% 80`.
    private static func percent(_ value: String) -> Int? {
        let digits = value.trimmingCharacters(in: CharacterSet(charactersIn: "% \u{00A0}"))
        guard value.contains("%"), let number = Int(digits) else { return nil }
        return number
    }

    private static func component(_ role: ComponentRole, _ percent: Int) -> BatteryComponent {
        BatteryComponent(role: role, percent: min(max(percent, 0), 100), charging: false)
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
