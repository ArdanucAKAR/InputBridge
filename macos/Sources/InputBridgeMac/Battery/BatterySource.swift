import Foundation
import os

/// Something on this Mac that can report device batteries.
protocol BatterySource: Sendable {
    var name: String { get }
    /// Blocking; call it off the main thread. Returns the readings available now (empty when there are none).
    func read() -> [BatteryReading]
}

/// The battery reader's log. Outcomes are notice or error, which macOS stores by default, so this shows them:
/// `log show --last 30m --predicate 'subsystem == "com.inputbridge.mac" AND category == "battery"'`.
/// The per-request reply bytes are info and the feature index is debug: watch them live with
/// `log stream --level debug --predicate '…'`.
enum BatteryLog {
    static let logger = Logger(subsystem: "com.inputbridge.mac", category: "battery")
}
