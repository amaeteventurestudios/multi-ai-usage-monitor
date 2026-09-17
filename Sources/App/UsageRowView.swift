// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Umanah. See NOTICE.

import AppKit

/// Colour for a usage severity, resolved against the current appearance so the
/// bars read correctly in both light and dark mode.
extension UsageSeverity {
    var gradient: (NSColor, NSColor) {
        switch self {
        case .normal:
            return (NSColor(srgbRed: 0.22, green: 0.85, blue: 0.54, alpha: 1),
                    NSColor(srgbRed: 0.18, green: 0.77, blue: 0.71, alpha: 1))
        case .warning:
            return (NSColor(srgbRed: 1.00, green: 0.82, blue: 0.40, alpha: 1),
                    NSColor(srgbRed: 0.96, green: 0.74, blue: 0.35, alpha: 1))
        case .high:
            return (NSColor(srgbRed: 1.00, green: 0.70, blue: 0.35, alpha: 1),
                    NSColor(srgbRed: 0.98, green: 0.52, blue: 0.25, alpha: 1))
        case .critical:
            return (NSColor(srgbRed: 1.00, green: 0.48, blue: 0.42, alpha: 1),
                    NSColor(srgbRed: 1.00, green: 0.30, blue: 0.43, alpha: 1))
        }
    }

    var textColor: NSColor {
        switch self {
        case .normal:   return NSColor(srgbRed: 0.15, green: 0.66, blue: 0.44, alpha: 1)
        case .warning:  return NSColor(srgbRed: 0.86, green: 0.62, blue: 0.15, alpha: 1)
        case .high:     return NSColor(srgbRed: 0.90, green: 0.47, blue: 0.15, alpha: 1)
        case .critical: return NSColor(srgbRed: 0.95, green: 0.33, blue: 0.40, alpha: 1)
        }
    }
}

/// One metric in the dropdown.
///
/// Every `MetricState` draws something: a value with a bar, a greyed row with a
/// reason, or a stale value with its age. There is no blank row, and the
/// percentage always carries the word "used" so it can never be misread as
/// "remaining".
final class UsageRowView: NSView {
    private let metric: UsageMetric
    private let showCountdown: Bool

    static let rowWidth: CGFloat = 300

    init(metric: UsageMetric, showCountdown: Bool) {
        self.metric = metric
        self.showCountdown = showCountdown
        super.init(frame: NSRect(x: 0, y: 0, width: UsageRowView.rowWidth,
                                 height: UsageRowView.height(for: metric)))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    static func height(for metric: UsageMetric) -> CGFloat {
        switch metric.state {
        case .available, .stale:
            // label + bar + (count line) + reset line
            var h: CGFloat = 46
            if metric.usedCount != nil { h += 15 }
            if metric.resetsAt != nil || metric.detail != nil { h += 15 }
            return h
        default:
            return metric.detail == nil ? 32 : 46
        }
    }

    private func draw(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight,
                      color: NSColor, mono: Bool = false) {
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawRightAligned(_ s: String, rightEdge: CGFloat, y: CGFloat, size: CGFloat,
                                  weight: NSFont.Weight, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let str = s as NSString
        str.draw(at: NSPoint(x: rightEdge - str.size(withAttributes: attrs).width, y: y),
                 withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        let padL: CGFloat = 16, padR: CGFloat = 16
        let w = bounds.width
        var y: CGFloat = 6

        draw(metric.name, at: NSPoint(x: padL, y: y), size: 13, weight: .semibold, color: .labelColor)

        switch metric.state {
        case .available, .stale:
            let used = metric.effectiveUsedPercent ?? 0
            let severity = UsageSeverity.forUsedPercent(used)
            let valueColor = metric.state == .stale ? NSColor.secondaryLabelColor : severity.textColor
            drawRightAligned(Fmt.usedPercent(used), rightEdge: w - padR, y: y,
                             size: 13, weight: .bold, color: valueColor)
            y += 20

            // Bar
            let barH: CGFloat = 6
            let track = NSRect(x: padL, y: y, width: w - padL - padR, height: barH)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()
            let fillW = track.width * CGFloat(min(100, max(0, used))) / 100.0
            if fillW > 0.5 {
                let fillRect = NSRect(x: track.minX, y: track.minY,
                                      width: max(fillW, barH), height: barH)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: fillRect, xRadius: barH / 2, yRadius: barH / 2).addClip()
                let (a, b) = severity.gradient
                let alpha: CGFloat = metric.state == .stale ? 0.45 : 1.0
                NSGradient(starting: a.withAlphaComponent(alpha),
                           ending: b.withAlphaComponent(alpha))?.draw(in: fillRect, angle: 0)
                NSGraphicsContext.restoreGraphicsState()
            }
            y += barH + 6

            if let counts = Fmt.countLine(used: metric.usedCount, limit: metric.limitCount) {
                draw(counts, at: NSPoint(x: padL, y: y), size: 11, weight: .regular,
                     color: .secondaryLabelColor)
                y += 15
            }

            var lines: [String] = []
            if metric.resetsAt != nil || showCountdown {
                lines.append(Fmt.resetLine(metric.resetsAt, fromProvider: metric.resetFromProvider))
            }
            if metric.state == .stale {
                lines.append("Stale · \(Fmt.updatedLine(metric.lastUpdated))")
            } else if let d = metric.detail {
                lines.append(d)
            }
            if !lines.isEmpty {
                draw(lines.joined(separator: " · "), at: NSPoint(x: padL, y: y),
                     size: 11, weight: .regular, color: .secondaryLabelColor)
            }

        case .loading:
            drawRightAligned("checking…", rightEdge: w - padR, y: y, size: 12,
                             weight: .regular, color: .tertiaryLabelColor)

        case .unsupported:
            drawRightAligned("Unavailable", rightEdge: w - padR, y: y, size: 12,
                             weight: .regular, color: .tertiaryLabelColor)
            if let d = metric.detail {
                draw(d, at: NSPoint(x: padL, y: y + 19), size: 11, weight: .regular,
                     color: .tertiaryLabelColor)
            }

        case .authenticationRequired:
            drawRightAligned("Reconnect required", rightEdge: w - padR, y: y, size: 12,
                             weight: .regular, color: .systemOrange)
            if let d = metric.detail {
                draw(d, at: NSPoint(x: padL, y: y + 19), size: 11, weight: .regular,
                     color: .secondaryLabelColor)
            }

        case .rateLimited:
            drawRightAligned("Rate-limited", rightEdge: w - padR, y: y, size: 12,
                             weight: .regular, color: .systemOrange)
            if let d = metric.detail {
                draw(d, at: NSPoint(x: padL, y: y + 19), size: 11, weight: .regular,
                     color: .secondaryLabelColor)
            }

        case .error:
            drawRightAligned("Error", rightEdge: w - padR, y: y, size: 12,
                             weight: .regular, color: .systemRed)
            if let d = metric.detail {
                draw(d, at: NSPoint(x: padL, y: y + 19), size: 11, weight: .regular,
                     color: .secondaryLabelColor)
            }
        }
    }
}

/// The account heading inside a provider section: name on the left, credential
/// and status on the right, so "which account is this and where is it reading
/// from" is answered without opening Settings.
final class AccountHeaderView: NSView {
    private let name: String
    private let subtitle: String
    private let accent: NSColor

    init(name: String, subtitle: String, accent: NSColor) {
        self.name = name
        self.subtitle = subtitle
        self.accent = accent
        super.init(frame: NSRect(x: 0, y: 0, width: UsageRowView.rowWidth, height: 38))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let padL: CGFloat = 16
        accent.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: padL - 6, y: 6, width: 3, height: 22),
                     xRadius: 1.5, yRadius: 1.5).fill()
        (name as NSString).draw(at: NSPoint(x: padL, y: 4), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ])
        (subtitle as NSString).draw(at: NSPoint(x: padL, y: 21), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }
}
