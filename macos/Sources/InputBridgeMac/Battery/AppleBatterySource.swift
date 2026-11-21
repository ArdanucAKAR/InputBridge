import Foundation
import IOKit

/// Apple Bluetooth peripherals: trackpad, mouse and keyboard from the IORegistry, AirPods-style earbuds from
/// `system_profiler`. Devices matching `excluding` (the shared keyboard pattern) are left out, because the
/// Logitech source reports that keyboard.
struct AppleBatterySource: BatterySource {
    private static let profilerTimeout: TimeInterval = 10

    private let excluding: () -> NSRegularExpression

    init(excluding: @escaping () -> NSRegularExpression) {
        self.excluding = excluding
    }

    var name: String { "Apple devices" }

    func read() -> [BatteryReading] {
        let pattern = excluding()
        var seen = Set<String>()
        return (Self.hidReadings() + Self.earbudReadings()).filter { reading in
            let range = NSRange(reading.name.startIndex..<reading.name.endIndex, in: reading.name)
            guard pattern.firstMatch(in: reading.name, options: [], range: range) == nil else { return false }
            // A peripheral can expose several HID services; keep the first reading per device.
            return seen.insert(reading.deviceId).inserted
        }
    }

    /// `AppleDeviceManagementHIDEventService` entries that publish `Product` and `BatteryPercent`.
    private static func hidReadings() -> [BatteryReading] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var readings: [BatteryReading] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let product = property(service, "Product") as? String else { continue }
            let percent = (property(service, "BatteryPercent") as? NSNumber)?.intValue
            // Charging is not reported: the BatteryStatusFlags charging bit is not confirmed on a real device.
            if let reading = AppleHIDParser.reading(product: product, batteryPercent: percent, charging: false) {
                readings.append(reading)
            }
        }
        return readings
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// One headset reading per connected device that reports earbud levels; a component per level present.
    private static func earbudReadings() -> [BatteryReading] {
        guard let output = runSystemProfiler() else { return [] }
        return SystemProfilerParser.connectedEarbuds(output).compactMap { (device) -> BatteryReading? in
            var components: [BatteryComponent] = []
            if let left = device.left { components.append(component(.left, left)) }
            if let right = device.right { components.append(component(.right, right)) }
            if let caseLevel = device.caseLevel { components.append(component(.`case`, caseLevel)) }
            guard !components.isEmpty else { return nil }
            return BatteryReading(
                deviceId: "apple:" + device.name, name: device.name, kind: .headset,
                components: components, readAt: Date())
        }
    }

    private static func component(_ role: ComponentRole, _ percent: Int) -> BatteryComponent {
        BatteryComponent(role: role, percent: min(max(percent, 0), 100), charging: false)
    }

    /// `system_profiler SPBluetoothDataType` output, or nil when it fails or takes longer than `profilerTimeout`
    /// (the process is then terminated). Never runs on the main thread.
    private static func runSystemProfiler() -> String? {
        guard !Thread.isMainThread else {
            assertionFailure("AppleBatterySource.read() must not be called on the main thread")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType"]
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        // Drain the pipe while the process runs, so a large report cannot fill the pipe and stall it.
        let output = NSMutableData()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.append(pipe.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }

        let deadline = DispatchTime.now() + profilerTimeout
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        // The process has exited, so its end of the pipe is closed and the drain finishes promptly.
        guard process.terminationStatus == 0, drained.wait(timeout: .now() + 2) == .success else { return nil }
        return String(data: output as Data, encoding: .utf8)
    }
}
