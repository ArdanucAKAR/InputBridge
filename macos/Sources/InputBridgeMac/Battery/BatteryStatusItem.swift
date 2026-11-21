import AppKit

/// The battery strip: a second menu bar item, left of the InputBridge icon, drawing every visible device as an
/// SF Symbol and its level. It is hidden while there is nothing to show. A click opens the settings window.
@MainActor
final class BatteryStatusItem: NSObject {
    /// Opens the settings window; set from SwiftUI (its `openWindow` action) once a view has appeared.
    var openSetup: (() -> Void)?

    private var item: NSStatusItem?

    func show(_ readings: [BatteryReading]) {
        let segments = BatteryStrip.segments(readings)
        guard !segments.isEmpty else {
            item?.isVisible = false
            return
        }
        // Created on first use, after the MenuBarExtra item exists, so macOS places it to the left of that icon.
        let item = self.item ?? makeItem()
        let tooltip = Self.tooltip(readings)
        item.button?.attributedTitle = Self.title(segments)
        item.button?.toolTip = tooltip
        // The title is symbols and numbers; VoiceOver reads the device names and levels instead.
        item.button?.setAccessibilityLabel(tooltip)
        item.isVisible = true
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        self.item = item
        return item
    }

    @objc private func clicked(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if let openSetup {
            openSetup()
        } else {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("setup") == true }?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Drawing

    private static func title(_ segments: [StripSegment]) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let title = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            let tint = Self.color(for: segment.tone)
            if index > 0 { title.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            if let symbol = symbolImage(segment.symbol, pointSize: font.pointSize - 1, color: tint) {
                title.append(attachment(symbol, font: font))
                title.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
            }
            title.append(NSAttributedString(string: segment.text, attributes: [.font: font, .foregroundColor: tint]))
            if segment.tone == .charging, let bolt = symbolImage("bolt.fill", pointSize: font.pointSize - 4, color: tint) {
                title.append(attachment(bolt, font: font))
            }
        }
        return title
    }

    private static func color(for tone: StripSegment.Tone) -> NSColor {
        switch tone {
        case .normal, .charging: return .labelColor
        case .low: return .systemRed
        case .remote: return .secondaryLabelColor
        }
    }

    private static func symbolImage(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        guard !name.isEmpty else { return nil }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? BatteryStrip.fallbackSymbols[name].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return image?.withSymbolConfiguration(configuration)
    }

    /// The image centred on the text's cap height.
    private static func attachment(_ image: NSImage, font: NSFont) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        let y = ((font.capHeight - image.size.height) / 2).rounded()
        attachment.bounds = CGRect(x: 0, y: y, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// One line per device, e.g. `AirPods Pro: L 90%, R 85%, case 60%` or `G915 TKL: 82% (on Windows)`.
    private static func tooltip(_ readings: [BatteryReading]) -> String {
        readings.map { reading in
            let levels = reading.components.map { component -> String in
                let level = "\(min(max(component.percent, 0), 100))%" + (component.charging ? " charging" : "")
                switch component.role {
                case .main: return level
                case .left: return "L " + level
                case .right: return "R " + level
                case .`case`: return "case " + level
                }
            }
            return "\(reading.name): " + levels.joined(separator: ", ") + (reading.remote ? " (on Windows)" : "")
        }.joined(separator: "\n")
    }
}
