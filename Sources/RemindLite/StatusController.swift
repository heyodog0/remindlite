// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import AppKit
import SwiftUI
import Combine

/// Owns the menu-bar status item (a checklist glyph + count badge) and the
/// glass panel. The panel's window is a clear canvas kept at least as tall as
/// the SwiftUI glass (plus a shadow margin); all visible resizing is SwiftUI's.
@MainActor
final class StatusController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let state = AppState()
    private let panel: GlassPanel
    private var cancellables: Set<AnyCancellable> = []

    private let width: CGFloat = panelWidth
    private let minHeight: CGFloat = 130
    private let maxHeight: CGFloat = 700   // room for the inline month calendar
    private let fallbackHeight: CGFloat = 250   // before the content first measures
    private var originX: CGFloat = 0
    private var pinnedTopY: CGFloat = 0
    // Until the panel has finished opening, shrink the window immediately; after
    // that, wait for the glass to finish collapsing first (see syncWindowSize).
    private var panelSettled = false
    /// Bumped on every open/close so a finished close fade can tell it's stale.
    private var transition = 0

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
        state.$tasks.combineLatest(state.$optimistic, state.$now)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateBadge() }
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

        // Scriptable toggle, for screenshotting the panel without a click:
        // Scripts/toggle-panel.swift posts this.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.heyodog0.remindlite.togglePanel"),
            object: nil, queue: .main
        ) { [weak self] n in
            MainActor.assumeIsolated {
                // An optional screen: reminders, calendar, event, new-event.
                if let screen = n.object as? String, let state = self?.state {
                    state.tab = screen == "reminders" ? .reminders : .calendar
                    if screen == "event" { state.selectedEventID = (state.events.first { !$0.attendees.isEmpty } ?? state.events.first)?.id }
                    if screen == "new-event" { state.beginNewEvent() }
                }
                self?.togglePanel()
            }
        }
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
        let info = Bundle.main.infoDictionary ?? [:]
        let stamp = NSMenuItem(
            title: "\(info["CFBundleShortVersionString"] ?? "") · \(info["CFBundleVersion"] ?? "") · \(info["BuildDate"] ?? "")",
            action: nil, keyEquivalent: "")
        stamp.isEnabled = false
        menu.addItem(stamp)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let google = NSMenuItem(
            title: state.googleConnected ? "Disconnect Google Calendar" : "Connect Google Calendar…",
            action: #selector(toggleGoogle), keyEquivalent: "")
        google.target = self
        google.toolTip = "Shows the colors you give individual events in Google Calendar"
        menu.addItem(google)
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

    @objc private func refreshNow() {
        state.refresh()
        state.refreshEvents(syncing: true)
    }
    @objc private func toggleGoogle() {
        state.googleConnected ? state.disconnectGoogle() : state.connectGoogle()
    }
    @objc private func toggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - panel show / hide

    private func open() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        // Refetch on open so the list is current the moment it appears.
        if state.access == .granted { state.refresh() }
        else if state.access == .unknown { state.requestAccess() }
        if state.calendarAccess == .granted { state.refreshEvents(syncing: true) }
        else if state.calendarAccess == .unknown && state.tab == .calendar { state.requestCalendarAccess() }

        let buttonFrame = buttonWindow.frame
        let screen = buttonWindow.screen ?? NSScreen.main
        let h = panelHeight()
        var x = buttonFrame.midX - width / 2   // glass left edge
        if let vis = screen?.visibleFrame {
            x = min(max(x, vis.minX + 6), vis.maxX - width - 6)
        }
        originX = x - shadowMargin
        pinnedTopY = buttonFrame.minY

        setWindow(h)

        // Start transparent: the window's alpha fades the glass in (its backdrop
        // blur fades cleanly that way), while SwiftUI settles the content inside.
        transition += 1
        panelSettled = false
        state.panelVisible = false
        panel.alphaValue = 0
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
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.openDuration * 0.75
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().alphaValue = 1
            }
            withAnimation(Motion.open) { self.state.panelVisible = true }
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
        let current = panel.frame.height - shadowMargin
        guard abs(target - current) > 0.5 else { return }
        if !panelSettled || target > current {
            // Grow immediately (the new space is clear, giving the SwiftUI glass
            // room to animate into it).
            setWindow(target)
        } else {
            // Shrink only after the glass has finished collapsing.
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration + 0.04) { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.setWindow(self.panelHeight())
            }
        }
    }

    private func setWindow(_ h: CGFloat) {
        let h = h + shadowMargin
        panel.setFrame(NSRect(x: originX, y: pinnedTopY - h,
                              width: width + 2 * shadowMargin, height: h),
                       display: true)
    }

    private func close() {
        statusItem.button?.highlight(false)
        // Drop the text-field focus so its cursor doesn't keep blinking and the
        // draft starts clean next time.
        panel.makeFirstResponder(nil)
        state.draft = ""
        panelSettled = false

        // Fade the window (and so the glass) out while the content lifts away;
        // when the fade completes, order the window out. The token drops a stale
        // completion if the panel was reopened meanwhile.
        transition += 1
        let token = transition
        withAnimation(Motion.close) { state.panelVisible = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.closeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transition == token else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
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
