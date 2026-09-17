import AppKit

/// One place that decides how solid this app's windows are drawn.
///
/// Every window the app owns — the settings window and the account editor sheet
/// — goes through here, so the user's choice applies uniformly and a new window
/// cannot quietly opt out of it.
///
/// The tint is `NSColor.windowBackgroundColor`, which is a dynamic system
/// colour: it resolves light in Light Mode and dark in Dark Mode, so turning the
/// window down makes it *more transparent* rather than washing it out to grey in
/// one appearance and to black in the other. Dark Mode keeps its contrast.
///
/// Plain AppKit window properties, available since long before macOS 12 — no
/// `NSVisualEffectView` material juggling, no third-party anything.
enum WindowBackground {

    /// Apply the configured opacity to a window. Safe to call repeatedly, and
    /// cheap enough to call on every slider tick.
    static func apply(opacity: Double, to window: NSWindow?) {
        guard let window = window else { return }
        let alpha = CGFloat(AppSettings.clampBackgroundOpacity(opacity))

        if alpha >= 0.999 {
            // Fully solid: keep the ordinary opaque path so AppKit can take its
            // fast drawing route and the window edges stay crisp.
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        } else {
            window.isOpaque = false
            window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(alpha)
        }

        // A window whose opacity changed needs its shadow recomputed, otherwise
        // the old silhouette lingers behind the new translucency.
        window.invalidateShadow()
        window.contentView?.needsDisplay = true
    }

    /// Stop a container view from painting its own opaque backdrop over the
    /// window's. Without this an `NSTabView`'s bezel would sit on top of the
    /// translucency and the setting would appear to do nothing.
    static func makeTransparent(_ tabView: NSTabView) {
        tabView.drawsBackground = false
    }
}
