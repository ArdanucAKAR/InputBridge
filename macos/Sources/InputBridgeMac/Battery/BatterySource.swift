import Foundation
import os

/// Something on this Mac that can report device batteries.
protocol BatterySource: Sendable {
    var name: String { get }
    /// Blocking; call it off the main thread. Returns the readings available now (empty when there are none).
    func read() -> [BatteryReading]
}

/// The battery reader's log. On the Mac:
/// `log show --info --last 1h --predicate 'subsystem == "com.inputbridge.mac" AND category == "battery"'`.
enum BatteryLog {
    static let logger = Logger(subsystem: "com.inputbridge.mac", category: "battery")
}
