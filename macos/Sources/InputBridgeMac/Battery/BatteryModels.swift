import Foundation

// Battery model shared with the Windows controller. JSON wire format: shared/fixtures/battery-readings.json.

enum DeviceKind: String, Codable {
    case keyboard, mouse, headset, trackpad, other
}

enum ComponentRole: String, Codable {
    case main, left, right, `case`
}

struct BatteryComponent: Codable, Equatable {
    let role: ComponentRole
    let percent: Int
    let charging: Bool
}

struct BatteryReading: Codable, Equatable {
    let deviceId: String
    let name: String
    let kind: DeviceKind
    let components: [BatteryComponent]
    let readAt: Date
    /// True for the shared keyboard reading that came from the other machine. Not part of the wire format.
    var remote: Bool = false

    private enum CodingKeys: String, CodingKey {
        case deviceId, name, kind, components, readAt
    }
}

// Declared in an extension so the memberwise initializer stays available.
extension BatteryReading {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .readAt)
        guard let readAt = BatteryWireDate.date(from: text) else {
            throw DecodingError.dataCorruptedError(
                forKey: .readAt, in: container, debugDescription: "readAt is not an ISO-8601 date: \(text)")
        }
        try self.init(
            deviceId: container.decode(String.self, forKey: .deviceId),
            name: container.decode(String.self, forKey: .name),
            kind: container.decode(DeviceKind.self, forKey: .kind),
            components: container.decode([BatteryComponent].self, forKey: .components),
            readAt: readAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(components, forKey: .components)
        try container.encode(BatteryWireDate.string(from: readAt), forKey: .readAt)
    }
}

struct BatteryEnvelope: Codable {
    let readings: [BatteryReading]
}

enum BatteryIds {
    static let sharedKeyboard = "logitech-keyboard"
}

/// `readAt` on the wire: ISO-8601. Written in UTC with `Z`; read with any offset and up to 9 fractional
/// digits, because the Windows controller (System.Text.Json DateTimeOffset) writes e.g. `2026-11-19T10:00:00.1234567+00:00`.
enum BatteryWireDate {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"#)

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func date(from text: String) -> Date? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        func number(_ index: Int) -> Int { group(index).flatMap { Int($0) } ?? -1 }

        let year = number(1), month = number(2), day = number(3)
        let hour = number(4), minute = number(5), second = number(6)
        guard year > 0, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let base = calendar.date(from: components) else { return nil }

        let fraction = group(7).flatMap { Double("0." + $0) } ?? 0
        var offsetSeconds = 0
        if let zone = group(8), zone != "Z" {
            let hours = Int(zone.dropFirst().prefix(2)) ?? 0
            let minutes = Int(zone.suffix(2)) ?? 0
            offsetSeconds = (hours * 3600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
        }
        return base.addingTimeInterval(fraction - Double(offsetSeconds))
    }
}
