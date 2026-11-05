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

    /// Blocking; call it off the main thread.
    /// Returns the keyboard name when it was switched, or nil when no matching keyboard is connected over Bluetooth.
    static func switchAwayFromBluetooth(namePattern: NSRegularExpression) throws -> String? {
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
        return nil
    }
}

/// HID++ 2.0 over the keyboard's Bluetooth vendor collection (device index 0xFF, long reports 0x11).
private final class HIDPPSession {
    private static let longReportID: UInt8 = 0x11
    private static let deviceIndex: UInt8 = 0xFF
    private static let softwareID: UInt8 = 0x0B
    private static let reportLength = 20
    private static let notPermitted = IOReturn(bitPattern: 0xE000_02E2)

    private let device: IOHIDDevice
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 64
    private let runLoop: CFRunLoop
    private var reports: [[UInt8]] = []

    init(device: IOHIDDevice) throws {
        self.device = device
        buffer = .allocate(capacity: 64)
        runLoop = CFRunLoopGetCurrent()

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            buffer.deallocate()
            if result == Self.notPermitted {
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                throw LogitechBluetoothKeyboard.KeyboardError.inputMonitoringRequired
            }
            throw LogitechBluetoothKeyboard.KeyboardError.openFailed(result)
        }

        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { context, _, _, _, _, report, length in
            guard let context else { return }
            let session = Unmanaged<HIDPPSession>.fromOpaque(context).takeUnretainedValue()
            session.reports.append(Array(UnsafeBufferPointer(start: report, count: length)))
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func send(feature: UInt8, function: UInt8, parameters: [UInt8]) throws {
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        report[0] = Self.longReportID
        report[1] = Self.deviceIndex
        report[2] = feature
        report[3] = (function << 4) | Self.softwareID
        for (offset, value) in parameters.prefix(Self.reportLength - 4).enumerated() {
            report[4 + offset] = value
        }
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.longReportID), report, report.count)
        guard result == kIOReturnSuccess else { throw LogitechBluetoothKeyboard.KeyboardError.writeFailed(result) }
    }

    /// Sends a request and returns the reply parameters.
    func request(feature: UInt8, function: UInt8, parameters: [UInt8], timeout: TimeInterval = 2) throws -> [UInt8] {
        let functionByte = (function << 4) | Self.softwareID
        reports.removeAll()
        try send(feature: feature, function: function, parameters: parameters)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, true)
            for raw in reports {
                // Normalise: some paths deliver the report without its ID byte.
                let report = raw.first == Self.longReportID ? raw : [Self.longReportID] + raw
                guard report.count >= 5, report[1] == Self.deviceIndex else { continue }
                if report[2] == feature && report[3] == functionByte {
                    return Array(report[4...])
                }
                if report[2] == 0xFF && report[3] == feature && report[4] == functionByte {
                    throw LogitechBluetoothKeyboard.KeyboardError.hidppError(report.count > 5 ? report[5] : 0)
                }
            }
        }
        throw LogitechBluetoothKeyboard.KeyboardError.noReply
    }

    func close() {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }
}
