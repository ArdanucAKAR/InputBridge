import Foundation

/// One menu bar column: a small SF Symbol on top, the percentage below.
struct MenuBarColumn: Equatable {
    enum Tone: Equatable { case normal, low, charging }

    let symbol: String   // SF Symbol name
    let text: String     // always "<percent>%"
    let tone: Tone
}

/// How AirPods are shown: left, right and case as separate columns, or one column with the lower earbud.
enum AirPodsLayout { case separate, combined }

/// Turns battery readings into menu bar columns. Pure, so it is unit tested.
enum MenuBarColumns {
    static let lowPercent = 15
    static let caseSymbol = "airpodspro.chargingcase.wireless"

    /// Symbol to draw when the first one is missing on this macOS version.
    static let fallbackSymbols: [String: String] = [
        "airpods": "headphones",
        "airpod.left": "headphones",
        "airpod.right": "headphones",
        caseSymbol: "case",
        "rectangle.and.hand.point.up.left": "hand.point.up.left",
    ]

    /// Readings arrive already sorted; the columns keep that order.
    static func columns(_ readings: [BatteryReading], airPods: AirPodsLayout) -> [MenuBarColumn] {
        readings.flatMap { columns(of: $0, airPods: airPods) }
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
    static func tone(_ component: BatteryComponent) -> MenuBarColumn.Tone {
        if component.percent <= lowPercent && !component.charging { return .low }
        return component.charging ? .charging : .normal
    }

    /// One line per device, e.g. `AirPods Pro: L 90%, R 85%, case 60%` or `G915 TKL: 82% charging`.
    static func tooltip(_ readings: [BatteryReading]) -> String {
        readings.map { reading in
            let levels = reading.components.sorted(by: { order($0.role) < order($1.role) }).map { component -> String in
                let level = "\(clamped(component.percent))%" + (component.charging ? " charging" : "")
                switch component.role {
                case .main: return level
                case .left: return "L " + level
                case .right: return "R " + level
                case .`case`: return "case " + level
                }
            }
            return "\(reading.name): " + levels.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    private static func columns(of reading: BatteryReading, airPods: AirPodsLayout) -> [MenuBarColumn] {
        let components = reading.components.sorted(by: { order($0.role) < order($1.role) })
        let earbuds = components.filter { $0.role == .left || $0.role == .right }
        if airPods == .combined {
            // The lower earbud; on a tie the charging one, so the charging tone is not lost.
            let lower = earbuds.min { a, b in
                a.percent != b.percent ? a.percent < b.percent : (a.charging && !b.charging)
            }
            if let lower { return [column(symbol(for: reading.kind), lower)] }
            // No earbud reading: the case is hidden in combined mode, anything else is kept.
            return components.filter { $0.role == .main }.map { column(symbol(for: reading.kind), $0) }
        }
        return components.map { component in
            switch component.role {
            case .main: return column(symbol(for: reading.kind), component)
            case .left: return column("airpod.left", component)
            case .right: return column("airpod.right", component)
            case .`case`: return column(caseSymbol, component)
            }
        }
    }

    private static func column(_ symbol: String, _ component: BatteryComponent) -> MenuBarColumn {
        MenuBarColumn(symbol: symbol, text: "\(clamped(component.percent))%", tone: tone(component))
    }

    private static func clamped(_ percent: Int) -> Int { min(max(percent, 0), 100) }

    private static func order(_ role: ComponentRole) -> Int {
        switch role {
        case .main: return 0
        case .left: return 1
        case .right: return 2
        case .`case`: return 3
        }
    }
}
