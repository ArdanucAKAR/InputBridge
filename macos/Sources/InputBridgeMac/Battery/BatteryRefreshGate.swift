import Foundation

/// Decides when a battery read cycle starts. Only one cycle runs at a time. Requests that arrive while a cycle runs
/// get exactly one more cycle after it. So every request is served by a cycle that starts at or after the request,
/// and a burst of requests costs at most one extra cycle.
struct BatteryRefreshGate {
    private(set) var running = false
    private var pending = false

    /// A refresh was requested. Returns true when a cycle should start now.
    mutating func request() -> Bool {
        if running {
            pending = true
            return false
        }
        running = true
        return true
    }

    /// The running cycle finished. Returns true when another cycle should start now, for requests made meanwhile.
    mutating func finish() -> Bool {
        guard running else { return false }
        if pending {
            pending = false
            return true
        }
        running = false
        return false
    }
}
