import AppKit
import SwiftUI

/// Borderless panel whose background is an AppKit Liquid Glass view
/// (NSGlassEffectView). The glass resizes natively with the window, which
/// SwiftUI's glassEffect can't do without recursing when its area resizes.
///
/// The panel is *activating* (no `.nonactivatingPanel`) so the "Add a reminder"
/// text field gets a real, well-behaved insertion point — non-activating panels
/// give text fields a flaky cursor.
final class GlassPanel: NSPanel {
    static let cornerRadius: CGFloat = 26

    private let host: NSHostingView<AnyView>

    init<Content: View>(content: Content) {
        // A normal hosting view that FILLS the window. The SwiftUI content is
        // top-anchored, so if it ever exceeds the window it clips at the bottom
        // (tabs/header stay put) rather than centering and clipping both ends.
        host = NSHostingView(rootView: AnyView(content))

        // Borderless but NOT `.nonactivatingPanel`: the panel activates and
        // becomes key, which is what a text field needs for a stable cursor.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
                   styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // A layer-masked container clips the glass's rectangular backing to the
        // rounded shape — otherwise the glass's opaque corner pixels show as
        // black squares behind the rounded corners.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let glass = NSGlassEffectView()
        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = Self.cornerRadius

        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        host.layer?.backgroundColor = .clear
        glass.contentView = host

        container.addSubview(glass)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
