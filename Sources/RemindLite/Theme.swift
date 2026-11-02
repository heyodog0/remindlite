// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI
import AppKit

// MARK: layout — shared so the measured panel height and the views agree.

let panelWidth: CGFloat = 300
let panelCornerRadius: CGFloat = 26
let panelShape = RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
/// Padding inside the glass, on every side.
let panelPadding: CGFloat = 12
/// Clear margin around the glass (sides + bottom) inside the window, so the
/// SwiftUI shadow can fade out instead of being cut off at the window edge.
let shadowMargin: CGFloat = 44

/// The selected-segment fill shared by the tab switch, active ActionButton and
/// Join pill.
func pillFill(_ tint: Color = .blue) -> LinearGradient {
    LinearGradient(colors: [tint, tint.opacity(0.82)], startPoint: .top, endPoint: .bottom)
}

/// Shared motion, so every screen change moves with the same feel.
enum Motion {
    /// Screen changes: list ↔ editor ↔ filters, tab switches, panel height.
    static let duration: Double = 0.34
    static let screen = Animation.spring(duration: duration, bounce: 0.08)
    /// Small in-place changes: the tab pill, the group toggle, notes, chevrons.
    static let quick = Animation.snappy(duration: 0.22)
    /// Outgoing screen fades fast so it never overlaps the incoming one.
    static let fadeOut = Animation.easeOut(duration: 0.1)
    /// Panel open/close. The glass fades via the window's alpha (the backdrop
    /// blur fades cleanly that way); only the content inside it moves.
    static let openDuration: Double = 0.24
    static let closeDuration: Double = 0.14
    static let open = Animation.spring(duration: openDuration, bounce: 0.1)
    static let close = Animation.easeIn(duration: closeDuration)
}

/// Real AppKit Liquid Glass (NSGlassEffectView) exposed to SwiftUI so SwiftUI can
/// size and animate it. The window itself is transparent; this is what you see.
/// NSGlassEffectView resizes natively, so when SwiftUI animates its frame the
/// glass follows smoothly — no recursion like SwiftUI's own `.glassEffect`.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = panelCornerRadius
    func makeNSView(context: Context) -> NSGlassEffectView {
        let v = NSGlassEffectView()
        v.cornerRadius = cornerRadius
        return v
    }
    func updateNSView(_ v: NSGlassEffectView, context: Context) {
        v.cornerRadius = cornerRadius
    }
}

/// Outer SwiftUI content. The window is a transparent canvas; this draws the
/// glass panel (hugging its content, top-pinned) over a clear backdrop. Tapping
/// the backdrop dismisses, like clicking outside a popover.
struct RootView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack(alignment: .top) {
            // Transparent dismiss area (covers any margin below the panel while it
            // animates shorter). Clicks elsewhere already dismiss via resignKey.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { state.closePanel?() }

            MenuContent()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .tint(.blue)
    }
}

/// Full-width action button; tints blue when active. Plain control on the glass
/// (not itself glass — glass-on-glass recurses).
struct ActionButton: View {
    let title: String
    let systemImage: String
    var active: Bool = false
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 9).padding(.horizontal, 12)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .white : .primary)
        .background {
            if active {
                shape.fill(pillFill())
            } else {
                shape.fill(.white.opacity(0.08))
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(active ? 0.30 : 0.12), lineWidth: 0.8))
        .animation(Motion.quick, value: active)
    }
}

extension View {
    /// Tidy edges for the panel's scrolling lists: rows fade out at an edge only
    /// while there's more content past it (no fade at rest at the top). The
    /// fades are the scroll cue, so the scroll bar is hidden — with "Show scroll
    /// bars: Always" it would otherwise sit on top of the rows' right edge.
    func scrollEdges() -> some View { modifier(ScrollEdges()) }
}

private struct ScrollEdges: ViewModifier {
    @State private var moreAbove = false
    @State private var moreBelow = false
    private let fade: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: [Bool].self, of: { g in
                let top = g.contentOffset.y + g.contentInsets.top
                return [top > 1,
                        top + g.containerSize.height < g.contentSize.height - 1]
            }, action: { _, edges in
                moreAbove = edges[0]; moreBelow = edges[1]
            })
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: moreAbove ? fade : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: moreBelow ? fade : 0)
                }
                .animation(Motion.quick, value: moreAbove)
                .animation(Motion.quick, value: moreBelow)
            }
    }
}
