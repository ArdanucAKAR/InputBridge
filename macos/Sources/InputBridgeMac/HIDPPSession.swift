import Foundation
import IOKit.hid

/// HID++ 2.0 over a Logitech keyboard's Bluetooth vendor collection (device index 0xFF, long reports 0x11).
/// Blocking: requests pump the current thread's run loop, so use a session off the main thread.
final class HIDPPSession {
    private static let longReportID: UInt8 = 0x11
    private static let deviceIndex: UInt8 = 0xFF
    private static let reportLength = 20
    private static let notPermitted = IOReturn(bitPattern: 0xE000_02E2)
    /// kIOReturnExclusiveAccess: another process seized the device (Karabiner-Elements does this to keyboards it modifies).
    private static let exclusiveAccess = IOReturn(bitPattern: 0xE000_02C5)

    private let device: IOHIDDevice
    private let softwareID: UInt8
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 64
    private let runLoop: CFRunLoop
    private var reports: [[UInt8]] = []

    /// - Parameters:
    ///   - softwareID: low nibble of the function byte; distinct callers use distinct ids so replies never cross
    ///     (the keyboard switch uses 0x0B, the battery reader 0x0C).
    ///   - requestAccessIfDenied: when the device cannot be opened for lack of Input Monitoring, ask macOS to show
    ///     its permission prompt. The battery reader passes false so it never prompts.
    init(device: IOHIDDevice, softwareID: UInt8 = 0x0B, requestAccessIfDenied: Bool = true) throws {
        self.device = device
        self.softwareID = softwareID & 0x0F
        buffer = .allocate(capacity: 64)
        runLoop = CFRunLoopGetCurrent()

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            buffer.deallocate()
            if result == Self.notPermitted {
                if requestAccessIfDenied {
                    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                }
                throw LogitechBluetoothKeyboard.KeyboardError.inputMonitoringRequired
            }
            if result == Self.exclusiveAccess {
                throw LogitechBluetoothKeyboard.KeyboardError.inUseByAnotherApp
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
        report[3] = (function << 4) | softwareID
        for (offset, value) in parameters.prefix(Self.reportLength - 4).enumerated() {
            report[4 + offset] = value
        }
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.longReportID), report, report.count)
        guard result == kIOReturnSuccess else { throw LogitechBluetoothKeyboard.KeyboardError.writeFailed(result) }
    }

    /// Sends a request and returns the reply parameters.
    func request(feature: UInt8, function: UInt8, parameters: [UInt8], timeout: TimeInterval = 2) throws -> [UInt8] {
        let functionByte = (function << 4) | softwareID
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
