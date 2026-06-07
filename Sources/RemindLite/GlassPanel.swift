import AppKit
import SwiftUI

/// A transparent, borderless host panel. The visible "glass" panel, its rounded
/// shape, shadow, and *all* height animation now live in SwiftUI (see RootView /
/// GlassBackground). The window is just a clear canvas pinned under the menu bar;
/// resizing it is invisible (its margins are transparent), so the panel can grow
/// and shrink entirely within SwiftUI — one layout system, nothing for AppKit to
/// animate and drag.
///
/// Activating (no `.nonactivatingPanel`) so the "Add a reminder" text field gets a
/// real, stable insertion point — non-activating panels give text fields a flaky
/// cursor.
final class GlassPanel: NSPanel {
    private let host: NSHostingView<AnyView>

    init<Content: View>(content: Content) {
        host = NSHostingView(rootView: AnyView(content))

        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                   styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false           // the SwiftUI glass draws its own shadow
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        host.autoresizingMask = [.width, .height]
        // Don't let the hosting view drive the window size; we size the window
        // ourselves to hug the SwiftUI glass (StatusController).
        host.sizingOptions = []
        host.layer?.backgroundColor = .clear
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
