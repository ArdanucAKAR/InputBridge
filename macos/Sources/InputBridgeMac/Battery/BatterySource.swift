import Foundation

/// Something on this Mac that can report device batteries.
protocol BatterySource: Sendable {
    var name: String { get }
    /// Blocking; call it off the main thread. Returns the readings available now (empty when there are none).
    func read() -> [BatteryReading]
}

/// The shared Logitech keyboard (G915/G913) while it is connected to this Mac over Bluetooth, read over HID++.
/// Silently empty when Input Monitoring is not granted: it never shows a permission prompt.
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
            return []
        }
    }
}
