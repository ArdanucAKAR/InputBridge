import Foundation
import IOKit.hid

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
    static func batteryReading(namePattern: NSRegularExpression) throws -> BatteryReading? {
        // Checked before opening anything, so no IOHID call can make macOS ask for the permission.
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw KeyboardError.inputMonitoringRequired
        }
        return try withMatchingKeyboard(namePattern: namePattern) { (device, name) -> BatteryReading? in
            let session = try HIDPPSession(device: device, softwareID: batterySoftwareID, requestAccessIfDenied: false)
            defer { session.close() }

            for feature in batteryFeatures {
                let index = try session.request(
                    feature: 0x00, function: 0,
                    parameters: [UInt8(feature >> 8), UInt8(feature & 0xFF)]
                )[0]
                guard index != 0 else { continue }

                let parsed: BatteryComponent?
                if feature == HIDPPBattery.featureUnifiedBattery {
                    // get_capabilities (fn 0), then get_status (fn 1).
                    let capabilities = try? session.request(feature: index, function: 0, parameters: [])
                    let stateOfCharge = capabilities.map(HIDPPBattery.parseUnifiedCapabilities) ?? false
                    let status = try session.request(feature: index, function: 1, parameters: [])
                    parsed = HIDPPBattery.parseUnifiedStatus(status, stateOfChargeSupported: stateOfCharge)
                } else if feature == HIDPPBattery.featureBatteryStatus {
                    parsed = try HIDPPBattery.parseBatteryStatus(session.request(feature: index, function: 0, parameters: []))
                } else {
                    parsed = try HIDPPBattery.parseVoltage(session.request(feature: index, function: 0, parameters: []))
                }
                guard let component = parsed else { return nil }
                return BatteryReading(
                    deviceId: BatteryIds.sharedKeyboard, name: name, kind: .keyboard,
                    components: [component], readAt: Date())
            }
            return nil
        }
    }

    /// Runs `body` with the first connected HID++ collection whose product name matches; nil when there is none.
    private static func withMatchingKeyboard<T>(
        namePattern: NSRegularExpression,
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

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        for device in devices {
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard namePattern.firstMatch(in: name, options: [], range: range) != nil else { continue }
            return try body(device, name)
        }
        return nil
    }
}
