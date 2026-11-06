import CoreMediaIO
import Foundation

/// Talks to the InputBridge Camera device through CoreMediaIO:
/// - reports whether any app (Zoom, Meet, FaceTime…) is streaming from it, for the settings window;
/// - hands the camera extension the Windows controller address and pairing token (`CameraStreamConfig`).
///   The extension connects to Windows itself, and only while an app uses the camera.
///
/// Reads `kCMIODevicePropertyDeviceIsRunningSomewhere`, the same flag the system uses for its camera
/// indicator. Reading or setting device properties does not open the camera or need camera permission.
final class VirtualCameraUsageMonitor {
    private let queue = DispatchQueue(label: "com.inputbridge.camera.usage", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastValue: Bool?
    private let onChange: (Bool) -> Void

    private var config = CameraStreamConfig.disabled
    private var sentConfig: CameraStreamConfig?
    private var sentToDevice: CMIOObjectID?
    private var sentAt = Date.distantPast
    /// The extension keeps the config only in memory; resend now and then in case it was restarted.
    private static let resendInterval: TimeInterval = 15

    /// `onChange` is called on the main queue, once with the initial value and then on every change.
    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in self?.lastValue = nil }
    }

    /// Sets where the extension should pull frames from; delivered on the next poll (within a second).
    func setConfig(_ newConfig: CameraStreamConfig) {
        queue.async { [weak self] in self?.config = newConfig }
    }

    private func poll() {
        let device = Self.findDevice()
        if let device {
            let due = config != sentConfig || device != sentToDevice
                || Date().timeIntervalSince(sentAt) > Self.resendInterval
            if due, Self.setStringProperty(device, InputBridgeCameraDevice.configSelector, config.encoded()) {
                sentConfig = config
                sentToDevice = device
                sentAt = Date()
            }
        } else {
            sentToDevice = nil
        }

        let inUse = device.map(Self.isRunningSomewhere) ?? false
        guard inUse != lastValue else { return }
        lastValue = inUse
        DispatchQueue.main.async { [onChange] in onChange(inUse) }
    }

    // MARK: - CoreMediaIO

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        address(CMIOObjectPropertySelector(selector))
    }

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    static func findDevice() -> CMIOObjectID? {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var addr = address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == noErr else { return nil }

        let uid = InputBridgeCameraDevice.deviceID.uuidString
        return devices.first { stringProperty($0, kCMIODevicePropertyDeviceUID)?.caseInsensitiveCompare(uid) == .orderedSame }
            ?? devices.first { stringProperty($0, kCMIOObjectPropertyName) == InputBridgeCameraDevice.name }
    }

    static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var addr = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
        return status == noErr && running != 0
    }

    static func stringProperty(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    @discardableResult
    static func setStringProperty(_ object: CMIOObjectID, _ selector: UInt32, _ string: String) -> Bool {
        var addr = address(CMIOObjectPropertySelector(selector))
        var value: CFString = string as CFString
        let status = withUnsafePointer(to: &value) { pointer in
            CMIOObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<CFString>.size), pointer)
        }
        return status == noErr
    }
}
