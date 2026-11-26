import Foundation
import IOKit.hid
import os

/// Switches a two-host Logitech keyboard (G915/G913) from this Mac's Bluetooth link to its other
/// host (the LIGHTSPEED receiver on the Windows PC) using HID++ 2.0 CHANGE_HOST (0x1814).
/// The keyboard is only reachable here while it is connected to this Mac over Bluetooth.
enum LogitechBluetoothKeyboard {
    enum KeyboardError: LocalizedError {
        case inputMonitoringRequired
        case openFailed(IOReturn)
        case writeFailed(IOReturn)
        case noReply
        case hidppError(UInt8)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .inputMonitoringRequired:
                return "allow InputBridge in System Settings → Privacy & Security → Input Monitoring, then try again."
            case .openFailed(let code):
                return "could not open the keyboard (IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16)))."
            case .writeFailed(let code):
                return "could not send to the keyboard (IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16)))."
            case .noReply:
                return "the keyboard did not answer."
            case .hidppError(let code):
                return "the keyboard rejected the request (HID++ error \(code))."
            case .unsupported(let name):
                return "\(name) does not support host switching."
            }
        }
    }

    private static let vendorID = 0x046D
    private static let hidppUsagePage = 0xFF43
    private static let hidppUsage = 0x0202
    private static let changeHostFeature: UInt16 = 0x1814
    /// Distinct from the keyboard switch's 0x0B so battery replies can never be taken for switch replies.
    private static let batterySoftwareID: UInt8 = 0x0C
    /// Same order as the Windows reader: the first one the keyboard supports is used.
    private static let batteryFeatures: [UInt16] = [
        HIDPPBattery.featureUnifiedBattery, HIDPPBattery.featureBatteryStatus, HIDPPBattery.featureBatteryVoltage
    ]

    /// Blocking; call it off the main thread.
    /// Returns the keyboard name when it was switched, or nil when no matching keyboard is connected over Bluetooth.
    static func switchAwayFromBluetooth(namePattern: NSRegularExpression) throws -> String? {
        try withMatchingKeyboard(namePattern: namePattern) { (device, name) -> String? in
            let session = try HIDPPSession(device: device)
            defer { session.close() }

            let feature = try session.request(
                feature: 0x00, function: 0,
                parameters: [UInt8(changeHostFeature >> 8), UInt8(changeHostFeature & 0xFF)]
            )[0]
            guard feature != 0 else { throw KeyboardError.unsupported(name) }

            let info = try session.request(feature: feature, function: 0, parameters: [])
            guard info.count >= 2, info[0] == 2 else { throw KeyboardError.unsupported(name) }

            // setCurrentHost (function 1). The keyboard leaves immediately, so no reply is expected.
            try session.send(feature: feature, function: 1, parameters: [info[1] == 0 ? 1 : 0])
            return name
        }
    }

    /// Blocking; call it off the main thread.
    /// Reads the battery of the matching keyboard while it is connected to this Mac over Bluetooth; nil when it is not
    /// connected here or exposes no battery feature. Never shows a permission prompt: throws
    /// `inputMonitoringRequired` when Input Monitoring is not granted.
    /// Every step goes to `BatteryLog`: the info lines and above tell the story, the feature index is debug.
    static func batteryReading(namePattern: NSRegularExpression) throws -> BatteryReading? {
        let log = BatteryLog.logger
        let pattern = namePattern.pattern
        // Checked before opening anything, so no IOHID call can make macOS ask for the permission.
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        guard access == kIOHIDAccessTypeGranted else {
            let code = Int(access.rawValue)
            log.error("Input Monitoring is not granted (IOHIDCheckAccess \(code, privacy: .public)); keyboard not read")
            throw KeyboardError.inputMonitoringRequired
        }
        log.info("Input Monitoring granted; looking for a HID++ collection matching \(pattern, privacy: .public)")

        let noMatch: ([String]) -> Void = { seen in
            let names = seen.isEmpty ? "none" : seen.map { "\"\($0)\"" }.joined(separator: ", ")
            log.info("No HID++ collection matches \(pattern, privacy: .public); collections seen: \(names, privacy: .public)")
        }
        return try withMatchingKeyboard(namePattern: namePattern, noMatch: noMatch) { (device, name) -> BatteryReading? in
            log.info("Matched HID++ collection \"\(name, privacy: .public)\"")
            let session = try HIDPPSession(device: device, softwareID: batterySoftwareID, requestAccessIfDenied: false)
            defer { session.close() }

            // One HID++ request, logging its reply bytes, or its error before passing it on.
            func ask(_ step: String, feature: UInt8, function: UInt8, parameters: [UInt8] = []) throws -> [UInt8] {
                do {
                    let reply = try session.request(feature: feature, function: function, parameters: parameters)
                    let bytes = hex(reply)
                    log.info("\(step, privacy: .public) replied \(bytes, privacy: .public)")
                    return reply
                } catch {
                    let description = describe(error)
                    log.info("\(step, privacy: .public) failed: \(description, privacy: .public)")
                    throw error
                }
            }

            for feature in batteryFeatures {
                let id = String(format: "0x%04X", feature)
                let index = try ask(
                    "Feature lookup \(id)", feature: 0x00, function: 0,
                    parameters: [UInt8(feature >> 8), UInt8(feature & 0xFF)])[0]
                guard index != 0 else {
                    log.info("\(name, privacy: .public) does not support battery feature \(id, privacy: .public)")
                    continue
                }
                log.debug("Battery feature \(id, privacy: .public) found at index \(Int(index), privacy: .public)")

                let reply: [UInt8]
                let parsed: BatteryComponent?
                if feature == HIDPPBattery.featureUnifiedBattery {
                    // get_capabilities (fn 0), then get_status (fn 1).
                    let capabilities = try? ask("Feature \(id) get_capabilities", feature: index, function: 0)
                    let stateOfCharge = capabilities.map(HIDPPBattery.parseUnifiedCapabilities) ?? false
                    reply = try ask("Feature \(id) get_status", feature: index, function: 1)
                    parsed = HIDPPBattery.parseUnifiedStatus(reply, stateOfChargeSupported: stateOfCharge)
                } else if feature == HIDPPBattery.featureBatteryStatus {
                    reply = try ask("Feature \(id) get_battery_level_status", feature: index, function: 0)
                    parsed = HIDPPBattery.parseBatteryStatus(reply)
                } else {
                    reply = try ask("Feature \(id) get_battery_voltage", feature: index, function: 0)
                    parsed = HIDPPBattery.parseVoltage(reply)
                }
                guard let component = parsed else {
                    let bytes = hex(reply)
                    log.error("Could not parse the feature \(id, privacy: .public) reply \(bytes, privacy: .public)")
                    return nil
                }
                let charging = component.charging ? "charging" : "not charging"
                log.info("\(name, privacy: .public) battery \(component.percent, privacy: .public)%, \(charging, privacy: .public)")
                return BatteryReading(
                    deviceId: BatteryIds.sharedKeyboard, name: name, kind: .keyboard,
                    components: [component], readAt: Date())
            }
            log.info("\(name, privacy: .public) supports none of the battery features")
            return nil
        }
    }

    /// Reply bytes as `52 08 01 01`.
    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// The readable description followed by the case, e.g. `the keyboard did not answer. [noReply]`.
    static func describe(_ error: Error) -> String {
        "\(error.localizedDescription) [\(String(describing: error))]"
    }

    /// Runs `body` with the first connected HID++ collection whose product name matches; nil when there is none.
    /// `noMatch` gets the product names of the collections seen when none matches.
    private static func withMatchingKeyboard<T>(
        namePattern: NSRegularExpression,
        noMatch: ([String]) -> Void = { _ in },
        _ body: (IOHIDDevice, String) throws -> T?
    ) rethrows -> T? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDDeviceUsagePageKey as String: hidppUsagePage,
            kIOHIDDeviceUsageKey as String: hidppUsage
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            noMatch([])
            return nil
        }
        var seen: [String] = []
        for device in devices {
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard namePattern.firstMatch(in: name, options: [], range: range) != nil else {
                seen.append(name)
                continue
            }
            return try body(device, name)
        }
        noMatch(seen)
        return nil
    }
}

/// The Logitech keyboard (G915/G913) while it is connected to this Mac over Bluetooth, read over HID++.
/// Empty when Input Monitoring is not granted: it never shows a permission prompt. Failures go to `BatteryLog`.
struct LogitechBluetoothBatterySource: BatterySource {
    private let pattern: @Sendable () -> NSRegularExpression

    init(pattern: @escaping @Sendable () -> NSRegularExpression) {
        self.pattern = pattern
    }

    var name: String { "Logitech Bluetooth keyboard" }

    func read() -> [BatteryReading] {
        do {
            return try LogitechBluetoothKeyboard.batteryReading(namePattern: pattern()).map { [$0] } ?? []
        } catch {
            // inputMonitoringRequired, or the keyboard did not answer: no reading this time.
            let description = LogitechBluetoothKeyboard.describe(error)
            BatteryLog.logger.error("Keyboard battery read failed: \(description, privacy: .public)")
            return []
        }
    }
}
