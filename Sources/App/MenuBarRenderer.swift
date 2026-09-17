import AppKit

/// Colour for a usage severity.
///
/// Blue rather than green at the low end: green reads as "good" when the honest
/// meaning is "nothing to think about yet", and it makes the amber step look
/// like a failure rather than a heads-up.
extension UsageSeverity {
    var barColor: NSColor {
        switch self {
        case .normal:   return NSColor(srgbRed: 0.24, green: 0.55, blue: 0.95, alpha: 1)
        case .warning:  return NSColor(srgbRed: 0.95, green: 0.75, blue: 0.20, alpha: 1)
        case .high:     return NSColor(srgbRed: 0.97, green: 0.52, blue: 0.20, alpha: 1)
        case .critical: return NSColor(srgbRed: 0.93, green: 0.28, blue: 0.33, alpha: 1)
        }
    }
}

/// Draws the menu bar's contents into an image.
///
/// A drawn image rather than Unicode blocks: it gives exact widths, real
/// colours, two stacked bars inside 22 points, and it looks the same on every
/// Mac regardless of which fonts are installed. `NSImage(size:flipped:drawingHandler:)`
/// runs its handler at draw time inside the current appearance, so dynamic
/// colours resolve correctly in both light and dark menu bars — and it is
/// available far below macOS 12.
enum MenuBarRenderer {

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let tagFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    private static let barHeight: CGFloat = 4
    private static let rowSpacing: CGFloat = 3
    private static let cellSpacing: CGFloat = 12
    private static let labelGap: CGFloat = 6
    private static let tagGap: CGFloat = 3
    private static let valueGap: CGFloat = 4

    /// Width reserved for a percentage. Monospaced digits, so "100%" is the
    /// worst case and everything lines up.
    private static let valueWidth: CGFloat = 30

    private static func size(_ s: String, _ font: NSFont) -> CGSize {
        (s as NSString).size(withAttributes: [.font: font])
    }

    /// Total width one cell needs.
    private static func cellWidth(_ cell: MenuBarCell, barLength: MiniBarLength,
                                  showPercentages: Bool) -> CGFloat {
        var width = size(cell.label, labelFont).width
        guard !cell.rows.isEmpty else { return width }
        width += labelGap

        let tagWidth = cell.rows.map { size($0.role.shortTag, tagFont).width }.max() ?? 0
        var rowWidth = CGFloat(barLength.width)
        if tagWidth > 0 { rowWidth += tagWidth + tagGap }
        if showPercentages { rowWidth += valueGap + valueWidth }
        return width + rowWidth
    }

    /// Render the cells, or nil when there is nothing to draw.
    static func image(cells: [MenuBarCell],
                      barLength: MiniBarLength,
                      showPercentages: Bool,
                      height: CGFloat = NSStatusBar.system.thickness) -> NSImage? {
        guard !cells.isEmpty else { return nil }

        let widths = cells.map { cellWidth($0, barLength: barLength, showPercentages: showPercentages) }
        let totalWidth = widths.reduce(0, +) + cellSpacing * CGFloat(max(0, cells.count - 1))
        guard totalWidth > 0 else { return nil }

        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: height),
                            flipped: false) { _ in
            var x: CGFloat = 0
            for (index, cell) in cells.enumerated() {
                draw(cell, at: x, height: height, barLength: barLength,
                     showPercentages: showPercentages)
                x += widths[index] + cellSpacing
            }
            return true
        }
        // Not a template: the whole point is the colours.
        image.isTemplate = false
        return image
    }

    private static func draw(_ cell: MenuBarCell, at originX: CGFloat, height: CGFloat,
                             barLength: MiniBarLength, showPercentages: Bool) {
        let labelSize = size(cell.label, labelFont)
        (cell.label as NSString).draw(
            at: NSPoint(x: originX, y: (height - labelSize.height) / 2),
            withAttributes: [.font: labelFont, .foregroundColor: NSColor.labelColor])

        guard !cell.rows.isEmpty else { return }
        let rowsX = originX + labelSize.width + labelGap
        let tagWidth = cell.rows.map { size($0.role.shortTag, tagFont).width }.max() ?? 0

        // Stack the rows about the vertical centre.
        let rowHeight = max(barHeight, size("0", valueFont).height)
        let blockHeight = rowHeight * CGFloat(cell.rows.count)
            + rowSpacing * CGFloat(max(0, cell.rows.count - 1))
        var y = (height + blockHeight) / 2 - rowHeight

        for row in cell.rows {
            var x = rowsX
            if tagWidth > 0, !row.role.shortTag.isEmpty {
                let tag = row.role.shortTag as NSString
                let tagSize = tag.size(withAttributes: [.font: tagFont])
                tag.draw(at: NSPoint(x: x, y: y + (rowHeight - tagSize.height) / 2),
                         withAttributes: [.font: tagFont,
                                          .foregroundColor: NSColor.secondaryLabelColor])
            }
            if tagWidth > 0 { x += tagWidth + tagGap }

            drawBar(row, x: x, y: y + (rowHeight - barHeight) / 2,
                    width: CGFloat(barLength.width))
            x += CGFloat(barLength.width)

            if showPercentages {
                x += valueGap
                let text = row.valueText as NSString
                let color: NSColor = row.hasError ? .systemOrange
                    : (row.isStale ? .secondaryLabelColor : .labelColor)
                let textSize = text.size(withAttributes: [.font: valueFont])
                text.draw(at: NSPoint(x: x, y: y + (rowHeight - textSize.height) / 2),
                          withAttributes: [.font: valueFont, .foregroundColor: color])
            }
            y -= rowHeight + rowSpacing
        }
    }

    private static func drawBar(_ row: MenuBarWindowRow, x: CGFloat, y: CGFloat, width: CGFloat) {
        let track = NSRect(x: x, y: y, width: width, height: barHeight)
        let radius = barHeight / 2
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        guard !row.hasError else {
            // An unavailable window draws an empty track plus a marker, so the
            // row keeps its shape instead of collapsing.
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barHeight, height: barHeight),
                         xRadius: radius, yRadius: radius).fill()
            return
        }
        guard let severity = row.severity, row.fill > 0 else { return }

        let fillWidth = max(barHeight, width * CGFloat(row.fill))
        let fillRect = NSRect(x: x, y: y, width: fillWidth, height: barHeight)
        let color = row.isStale ? severity.barColor.withAlphaComponent(0.45) : severity.barColor
        color.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}
