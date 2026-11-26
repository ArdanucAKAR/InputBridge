import AppKit

/// The content of the InputBridge menu bar item: the colour app icon at the far left, then the battery columns,
/// each a small SF Symbol above its percentage.
///
/// Colours are `.labelColor` (or `.systemRed` when low), resolved against the view's effective appearance. Inside
/// the status bar button that follows the menu bar itself, so the columns stay readable on a light menu bar over a
/// dark wallpaper and the other way round.
final class StatusItemView: NSView {
    var icon = NSImage() {
        didSet { contentChanged() }
    }

    var columns: [MenuBarColumn] = [] {
        didSet { contentChanged() }
    }

    private enum Metrics {
        static let iconSize: CGFloat = 18
        /// Before every column: after the icon, or after the previous column.
        static let columnSpacing: CGFloat = 6
        static let symbolPointSize: CGFloat = 9
        static let boltPointSize: CGFloat = 7
        /// Between the device symbol and the charging bolt.
        static let boltSpacing: CGFloat = 1
        /// The top row is this tall in every column, so all percentages share one baseline.
        static let topRowHeight: CGFloat = 10
        /// Between the top row and the cap height of the percentage.
        static let rowSpacing: CGFloat = 1.5
        static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold) }
    }

    /// One column, measured and ready to draw.
    private struct ColumnLayout {
        let symbol: NSImage?
        let bolt: NSImage?
        let text: NSAttributedString

        var topRowWidth: CGFloat {
            let symbolWidth = symbol?.size.width ?? 0
            guard let bolt else { return symbolWidth }
            return symbolWidth + (symbol == nil ? 0 : Metrics.boltSpacing) + bolt.size.width
        }

        var textWidth: CGFloat { text.size().width }

        /// As wide as the wider of the two rows.
        var width: CGFloat { ceil(max(topRowWidth, textWidth)) }
    }

    override var intrinsicContentSize: NSSize {
        let widths = columns.map { measure($0, color: .labelColor).width }
        let width = Metrics.iconSize + widths.reduce(0) { $0 + Metrics.columnSpacing + $1 }
        return NSSize(width: width, height: NSView.noIntrinsicMetric)
    }

    /// Clicks go to the status bar button underneath, which opens the panel.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let iconRect = NSRect(
            x: 0, y: aligned((bounds.height - Metrics.iconSize) / 2),
            width: Metrics.iconSize, height: Metrics.iconSize)
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

        guard !columns.isEmpty else { return }
        // Resolve the dynamic colours against the menu bar's appearance, not the app's.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawColumns()
        }
    }

    // MARK: Drawing

    private func drawColumns() {
        let font = Metrics.font
        let contentHeight = Metrics.topRowHeight + Metrics.rowSpacing + font.capHeight
        let baseline = aligned((bounds.height - contentHeight) / 2)
        let topRowMidY = baseline + font.capHeight + Metrics.rowSpacing + Metrics.topRowHeight / 2

        var x = Metrics.iconSize
        for column in columns {
            x += Metrics.columnSpacing
            let layout = measure(column, color: Self.resolved(Self.color(for: column.tone)))
            let width = layout.width

            var symbolX = x + (width - layout.topRowWidth) / 2
            if let symbol = layout.symbol {
                drawImage(symbol, x: symbolX, midY: topRowMidY)
                symbolX += symbol.size.width + Metrics.boltSpacing
            }
            if let bolt = layout.bolt {
                drawImage(bolt, x: symbolX, midY: topRowMidY)
            }

            let textX = aligned(x + (width - layout.textWidth) / 2)
            // Without `.usesLineFragmentOrigin` the rectangle's origin is the baseline of the single line.
            layout.text.draw(
                with: NSRect(x: textX, y: baseline, width: ceil(layout.textWidth), height: font.capHeight),
                options: [])

            x += width
        }
    }

    private func drawImage(_ image: NSImage, x: CGFloat, midY: CGFloat) {
        let rect = NSRect(
            x: aligned(x), y: aligned(midY - image.size.height / 2),
            width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func measure(_ column: MenuBarColumn, color: NSColor) -> ColumnLayout {
        let bolt = column.tone == .charging ? Self.symbol("bolt.fill", pointSize: Metrics.boltPointSize, color: color) : nil
        let text = NSAttributedString(string: column.text, attributes: [.font: Metrics.font, .foregroundColor: color])
        return ColumnLayout(
            symbol: Self.symbol(column.symbol, pointSize: Metrics.symbolPointSize, color: color),
            bolt: bolt,
            text: text)
    }

    private func contentChanged() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Rounds to the nearest device pixel so the glyphs stay sharp.
    private func aligned(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    private static func color(for tone: MenuBarColumn.Tone) -> NSColor {
        switch tone {
        case .normal, .charging: return .labelColor
        case .low: return .systemRed
        }
    }

    /// The colour as the current drawing appearance shows it, so symbol images get a fixed palette colour.
    private static func resolved(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    private static func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        guard !name.isEmpty else { return nil }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? MenuBarColumns.fallbackSymbols[name].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return image?.withSymbolConfiguration(configuration)
    }
}
