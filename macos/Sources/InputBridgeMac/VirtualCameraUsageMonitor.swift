import CoreMediaIO
import Foundation

/// Watches whether any app on this Mac (Zoom, Meet, FaceTime…) is streaming from InputBridge Camera,
/// so the Windows camera is turned on only while it is actually needed.
///
/// Reads `kCMIODevicePropertyDeviceIsRunningSomewhere`, the same flag the system uses for its camera
/// indicator. Reading device properties does not open the camera or need camera permission.
final class VirtualCameraUsageMonitor {
    private let queue = DispatchQueue(label: "com.inputbridge.camera.usage", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastValue: Bool?
    private let onChange: (Bool) -> Void

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

    private func poll() {
        let inUse = Self.findDevice().map(Self.isRunningSomewhere) ?? false
        guard inUse != lastValue else { return }
        lastValue = inUse
        DispatchQueue.main.async { [onChange] in onChange(inUse) }
    }

    // MARK: - CoreMediaIO

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func findDevice() -> CMIOObjectID? {
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

    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var addr = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
        return status == noErr && running != 0
    }

    private static func stringProperty(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
