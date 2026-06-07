import AppKit
import SwiftUI
import Combine

/// Owns the menu-bar status item (a checklist glyph + count badge) and the
/// glass panel. We size the window ourselves so the NSGlassEffectView resizes
/// natively between the access-prompt and full-list layouts.
@MainActor
final class StatusController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let state = AppState()
    private let panel: GlassPanel
    private var cancellables: Set<AnyCancellable> = []

    private let width: CGFloat = 300
    private let minHeight: CGFloat = 130
    private let maxHeight: CGFloat = 600
    private let fallbackHeight: CGFloat = 250   // before the content first measures
    private var originX: CGFloat = 0
    private var pinnedTopY: CGFloat = 0
    // Resize instantly until the panel has finished opening, then animate height
    // changes (list ↔ editor, tab switches) so the panel grows/shrinks smoothly.
    private var panelSettled = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = GlassPanel(content: RootView().environmentObject(state))
        super.init()
        panel.delegate = self

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateBadge()

        // Enable launch-at-login once; the right-click menu lets the user turn
        // it off later without it re-enabling each launch.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "loginItemConfigured") {
            LoginItem.forceEnable()
            defaults.set(true, forKey: "loginItemConfigured")
        }

        // Live-update the menu-bar badge as tasks / completions change.
        state.$tasks.combineLatest(state.$optimistic)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateBadge() }
            .store(in: &cancellables)

        // The SwiftUI glass publishes its full height; keep the transparent window
        // at least that tall so it never clips the glass. Resizing is invisible
        // (the window's margins are clear), so there's no frame animation to drag
        // the content — all motion is the SwiftUI glass animating its own height.
        state.$panelContentHeight
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncWindowSize() }
            .store(in: &cancellables)

        // Let SwiftUI (tap outside the glass) dismiss the panel.
        state.closePanel = { [weak self] in self?.close() }
    }

    private func panelHeight() -> CGFloat {
        let h = state.panelContentHeight
        guard h > 0 else { return fallbackHeight }
        return min(max(h, minHeight), maxHeight)
    }

    // MARK: - clicks

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        isRight ? showMenu() : togglePanel()
    }

    private func togglePanel() { panel.isVisible ? close() : open() }

    private func showMenu() {
        if panel.isVisible { close() }
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit RemindLite",
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        if let button = statusItem.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
        }
    }

    @objc private func refreshNow() { state.refresh() }
    @objc private func toggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - panel show / hide

    private func open() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        // Refetch on open so the list is current the moment it appears.
        if state.access == .granted { state.refresh() }
        else if state.access == .unknown { state.requestAccess() }
        if state.calendarAccess == .granted { state.refreshEvents() }
        else if state.calendarAccess == .unknown && state.tab == .calendar { state.requestCalendarAccess() }

        let buttonFrame = buttonWindow.frame
        let screen = buttonWindow.screen ?? NSScreen.main
        let h = panelHeight()
        var x = buttonFrame.midX - width / 2
        if let vis = screen?.visibleFrame {
            x = min(max(x, vis.minX + 6), vis.maxX - width - 6)
        }
        originX = x
        pinnedTopY = buttonFrame.minY

        setWindow(h)

        // The window is clear; the SwiftUI glass fades + scales up from the top
        // (Control-Center "blurred → focus"). Start hidden.
        state.autoCloseSuppressed = false
        panelSettled = false
        state.panelVisible = false
        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Don't let the key window auto-focus the "Add a reminder" text
            // field — the cursor should only appear when the user clicks it.
            self.panel.makeFirstResponder(nil)
            // Content has laid out — cover its true height before it animates in.
            self.syncWindowSize()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.74)) {
                self.state.panelVisible = true
            }
            self.panelSettled = true
        }
    }

    /// Keep the transparent window tall enough to contain the SwiftUI glass, top
    /// edge pinned. Growing is applied immediately (the new space is clear, so
    /// it's invisible, and gives the glass room to animate into). Shrinking waits
    /// for the glass to finish collapsing, then tightens — also invisible. The
    /// window is only ever set instantly; the *glass* is what animates, in SwiftUI.
    private func syncWindowSize() {
        guard panel.isVisible else { return }
        let target = panelHeight()
        let current = panel.frame.height
        guard abs(target - current) > 0.5 else { return }
        if !panelSettled || target > current {
            setWindow(target)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.setWindow(self.panelHeight())
            }
        }
    }

    private func setWindow(_ h: CGFloat) {
        panel.setFrame(NSRect(x: originX, y: pinnedTopY - h, width: width, height: h),
                       display: true)
    }

    private func close() {
        statusItem.button?.highlight(false)
        // Drop the text-field focus so its cursor doesn't keep blinking and the
        // draft starts clean next time.
        panel.makeFirstResponder(nil)
        state.draft = ""
        panelSettled = false

        // The SwiftUI glass fades + scales down toward the menu bar; once it's
        // gone, order the (clear) window out.
        withAnimation(.easeIn(duration: 0.16)) { state.panelVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Don't dismiss when a child popover (the date calendar) takes focus.
        if state.autoCloseSuppressed { return }
        if panel.isVisible { close() }
    }

    // MARK: - menu-bar glyph + badge

    private func updateBadge() {
        statusItem.button?.image = Self.badgeImage(count: state.badgeCount,
                                                   overdue: state.hasOverdue)
    }

    /// The menu-bar icon: a checklist glyph plus the count drawn beside it as a
    /// single image. In the normal case it's a **template** image, so macOS
    /// tints the whole thing to match the bar — black over a light wallpaper,
    /// white over a dark one, exactly like the native clock. When something's
    /// overdue it's drawn as a real **red** icon so the alert reads on any
    /// background.
    private static func badgeImage(count: Int, overdue: Bool) -> NSImage {
        let base = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let iconCfg = overdue
            ? base.applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            : base
        let icon = (NSImage(systemSymbolName: "checklist", accessibilityDescription: "Reminders")?
            .withSymbolConfiguration(iconCfg)) ?? NSImage()

        guard count > 0 else {
            icon.isTemplate = !overdue
            return icon
        }

        let text = "\(count)" as NSString
        let textColor: NSColor = overdue ? .systemRed : .black   // black → template-tinted
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: textColor,
        ]
        let textSize = text.size(withAttributes: attrs)
        let gap: CGFloat = 3
        let iconSize = icon.size
        let h = max(iconSize.height, textSize.height)
        let w = iconSize.width + gap + textSize.width

        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: (h - iconSize.height) / 2,
                                 width: iconSize.width, height: iconSize.height))
            text.draw(at: NSPoint(x: iconSize.width + gap, y: (h - textSize.height) / 2),
                      withAttributes: attrs)
            return true
        }
        img.isTemplate = !overdue   // template ⇒ macOS colors the count (black on a light bar)
        return img
    }
}
