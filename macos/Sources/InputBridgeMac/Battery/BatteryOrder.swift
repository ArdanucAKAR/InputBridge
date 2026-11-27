import Foundation

/// Which sources a read cycle asks, and the order the menu bar shows this Mac's readings in.
enum BatteryOrder {
    /// Keyboard, mouse, headset, trackpad, other, then by name (case-insensitive), then by device id.
    static func sorted(_ readings: [BatteryReading]) -> [BatteryReading] {
        readings.sorted(by: precedes)
    }

    /// The first reading of each device, in the order given. Sources are read in priority order, so a keyboard read
    /// over HID++ (with its charging state) wins over the same keyboard listed by system_profiler.
    static func deduplicated(_ readings: [BatteryReading]) -> [BatteryReading] {
        var seen = Set<String>()
        return readings.filter { seen.insert($0.deviceId).inserted }
    }

    /// Every source while "Show battery levels" is on; none while it is off, so a disabled monitor reads nothing.
    static func sourcesToRead(all: [BatterySource], enabled: Bool) -> [BatterySource] {
        enabled ? all : []
    }

    private static func precedes(_ a: BatteryReading, _ b: BatteryReading) -> Bool {
        if rank(a.kind) != rank(b.kind) { return rank(a.kind) < rank(b.kind) }
        let byName = a.name.caseInsensitiveCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.deviceId < b.deviceId
    }

    private static func rank(_ kind: DeviceKind) -> Int {
        switch kind {
        case .keyboard: return 0
        case .mouse: return 1
        case .headset: return 2
        case .trackpad: return 3
        case .other: return 4
        }
    }
}
