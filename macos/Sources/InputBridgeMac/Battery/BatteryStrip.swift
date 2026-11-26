import Foundation

/// One piece of the menu bar battery strip: an SF Symbol name (empty for none) followed by a short text.
struct StripSegment: Equatable {
    enum Tone { case normal, low, charging }

    let symbol: String
    let text: String
    let tone: Tone
}

/// Turns battery readings into strip segments, e.g. `⌨ 82%  🎧 L90 R85 ◫60`. Pure, so it is unit tested.
enum BatteryStrip {
    static let lowPercent = 15
    static let caseSymbol = "airpodspro.chargingcase.wireless"

    /// Symbols that may be missing on older macOS versions, with the one to draw instead.
    static let fallbackSymbols: [String: String] = [
        "airpods": "headphones",
        caseSymbol: "case",
        "rectangle.and.hand.point.up.left": "hand.point.up.left",
    ]

    static func segments(_ readings: [BatteryReading]) -> [StripSegment] {
        readings.flatMap(segments(of:))
    }

    static func symbol(for kind: DeviceKind) -> String {
        switch kind {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .headset: return "airpods"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .other: return "battery.100"
        }
    }

    /// Same precedence as the Windows tray icons: low (not charging), then charging.
    static func tone(_ component: BatteryComponent) -> StripSegment.Tone {
        if component.percent <= lowPercent && !component.charging { return .low }
        return component.charging ? .charging : .normal
    }

    /// The device symbol goes on the first segment only (`🎧 L90 R85`); the case has its own symbol.
    private static func segments(of reading: BatteryReading) -> [StripSegment] {
        var deviceSymbol = symbol(for: reading.kind)
        var result: [StripSegment] = []
        for component in reading.components.sorted(by: { order($0.role) < order($1.role) }) {
            let percent = min(max(component.percent, 0), 100)
            let shade = Self.tone(component)
            switch component.role {
            case .main:
                result.append(StripSegment(symbol: deviceSymbol, text: "\(percent)%", tone: shade))
                deviceSymbol = ""
            case .left:
                result.append(StripSegment(symbol: deviceSymbol, text: "L\(percent)", tone: shade))
                deviceSymbol = ""
            case .right:
                result.append(StripSegment(symbol: deviceSymbol, text: "R\(percent)", tone: shade))
                deviceSymbol = ""
            case .`case`:
                result.append(StripSegment(symbol: caseSymbol, text: "\(percent)", tone: shade))
            }
        }
        return result
    }

    private static func order(_ role: ComponentRole) -> Int {
        switch role {
        case .main: return 0
        case .left: return 1
        case .right: return 2
        case .`case`: return 3
        }
    }
}
