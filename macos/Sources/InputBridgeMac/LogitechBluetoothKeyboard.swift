import AppKit
import Foundation
import IOKit.hid
import os

/// Switches a two-host Logitech keyboard (G915/G913) from this Mac's Bluetooth link to its other
/// host (the LIGHTSPEED receiver on the Windows PC) using HID++ 2.0 CHANGE_HOST (0x1814).
/// The keyboard is only reachable here while it is connected to this Mac over Bluetooth.
enum LogitechBluetoothKeyboard {
    enum KeyboardError: LocalizedError {
        case inputMonitoringRequired
        /// Another process has the keyboard to itself, typically Karabiner-Elements while it modifies the keyboard.
        case inUseByAnotherApp
        case openFailed(IOReturn)
        case writeFailed(IOReturn)
        case noReply
        case hidppError(UInt8)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .inputMonitoringRequired:
                return "allow InputBridge in System Settings → Privacy & Security → Input Monitoring, then try again."
            case .inUseByAnotherApp:
                return "another app has the keyboard to itself. In Karabiner-Elements, turn off Modify events for it under Devices."
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
    /// Every step goes to `BatteryLog`. Outcomes (match or no match, percent, no battery feature) are notice and
    /// failures are error, so a plain `log show` tells the story; reply bytes are info and the feature index debug.
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
            log.notice("No HID++ collection matches \(pattern, privacy: .public); collections seen: \(names, privacy: .public)")
        }
        return try withMatchingKeyboard(namePattern: namePattern, noMatch: noMatch) { (device, name) -> BatteryReading? in
            log.notice("Matched HID++ collection \"\(name, privacy: .public)\"")
            let session = try step("Opening \"\(name)\"") {
                try HIDPPSession(device: device, softwareID: batterySoftwareID, requestAccessIfDenied: false)
            }
            defer { session.close() }

            // One HID++ request. Logs its reply bytes; a failure carries the step name to the one error line that
            // LogitechBluetoothBatterySource.read() writes.
            func ask(_ label: String, feature: UInt8, function: UInt8, parameters: [UInt8] = []) throws -> [UInt8] {
                let reply = try step(label) {
                    try session.request(feature: feature, function: function, parameters: parameters)
                }
                let bytes = hex(reply)
                log.info("\(label, privacy: .public) replied \(bytes, privacy: .public)")
                return reply
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
                    var stateOfCharge = false
                    do {
                        let capabilities = try ask("Feature \(id) get_capabilities", feature: index, function: 0)
                        stateOfCharge = HIDPPBattery.parseUnifiedCapabilities(capabilities)
                    } catch {
                        // Not fatal: the status still gives a level from its flags.
                        let description = describe(error)
                        log.info("\(description, privacy: .public); reading the status without capabilities")
                    }
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
                log.notice("\(name, privacy: .public) battery \(component.percent, privacy: .public)%, \(charging, privacy: .public)")
                return BatteryReading(
                    deviceId: BatteryIds.sharedKeyboard, name: name, kind: .keyboard,
                    components: [component], readAt: Date())
            }
            log.notice("\(name, privacy: .public) supports none of the battery features")
            return nil
        }
    }

    /// Reply bytes as `52 08 01 01`.
    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// A battery read step that failed, e.g. `Feature lookup 0x1004`, with the error it threw.
    struct StepFailed: Error {
        let step: String
        let underlying: Error
    }

    /// Runs `body`, wrapping what it throws in `StepFailed` so the one logged error names the step.
    private static func step<T>(_ step: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw StepFailed(step: step, underlying: error)
        }
    }

    /// The readable description followed by the case, e.g. `the keyboard did not answer. [noReply]`; a failed step
    /// is prefixed with its name: `Feature lookup 0x1004 failed: the keyboard did not answer. [noReply]`.
    static func describe(_ error: Error) -> String {
        if let failed = error as? StepFailed {
            return "\(failed.step) failed: \(describe(failed.underlying))"
        }
        return "\(error.localizedDescription) [\(String(describing: error))]"
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
        } catch LogitechBluetoothKeyboard.KeyboardError.inputMonitoringRequired {
            // Already logged where the access check failed.
            return []
        } catch {
            // A failed step (the keyboard did not answer, …): no reading this time. The only error line for it.
            let description = LogitechBluetoothKeyboard.describe(error)
            BatteryLog.logger.error("Keyboard battery read failed: \(description, privacy: .public)")
            return []
        }
    }
}

/// The Input Monitoring permission (TCC ListenEvent), which opening the keyboard's HID++ collection needs.
enum InputMonitoring {
    enum Access { case granted, denied, notDetermined }

    static var access: Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt when the user has not decided yet; adds InputBridge, switched off, to the list otherwise.
    static func request() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
