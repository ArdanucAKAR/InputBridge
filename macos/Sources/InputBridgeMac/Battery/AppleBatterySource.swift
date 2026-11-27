import Foundation
import IOKit

/// Bluetooth peripherals as macOS itself reports them: Apple trackpads, mice and keyboards from the IORegistry;
/// AirPods-style earbuds and other devices with one battery level (such as the G915 on Bluetooth LE) from
/// `system_profiler`. Needs no permission. The keyboard matching `keyboardPattern` gets the shared keyboard id,
/// so `BatteryOrder.deduplicated` drops it when the Logitech HID++ source, read first, already has it.
struct AppleBatterySource: BatterySource {
    private static let profilerTimeout: TimeInterval = 10

    private let keyboardPattern: @Sendable () -> NSRegularExpression

    init(keyboardPattern: @escaping @Sendable () -> NSRegularExpression) {
        self.keyboardPattern = keyboardPattern
    }

    var name: String { "Bluetooth devices" }

    func read() -> [BatteryReading] {
        // A peripheral can expose several HID services; BatteryOrder.deduplicated keeps one reading per device.
        let profiler = Self.runSystemProfiler().map {
            SystemProfilerParser.readings($0, keyboardPattern: keyboardPattern(), readAt: Date())
        } ?? []
        return Self.hidReadings() + profiler
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
            // readToEnd() throws where readDataToEndOfFile() would raise an Objective-C exception and crash.
            if let data = try? pipe.fileHandleForReading.readToEnd() { output.append(data) }
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
