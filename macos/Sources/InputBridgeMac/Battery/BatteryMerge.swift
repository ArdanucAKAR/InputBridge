import Foundation

/// Combines this Mac's readings with the ones the Windows controller shared.
enum BatteryMerge {
    /// Local readings plus the shared keyboard from Windows (marked remote) when this Mac has no reading of its own,
    /// ordered keyboard, mouse, headset, trackpad, other, then by name. Any other remote reading is ignored.
    static func visible(local: [BatteryReading], remote: [BatteryReading]) -> [BatteryReading] {
        var shown = local
        if needsRemoteKeyboard(local: local),
           var keyboard = remote.last(where: { $0.deviceId == BatteryIds.sharedKeyboard }) {
            keyboard.remote = true
            shown.append(keyboard)
        }
        return shown.sorted(by: precedes)
    }

    /// True while this Mac has no shared keyboard reading of its own, so the one Windows has is worth fetching
    /// between full reads.
    static func needsRemoteKeyboard(local: [BatteryReading]) -> Bool {
        !local.contains { $0.deviceId == BatteryIds.sharedKeyboard }
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
