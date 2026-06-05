import SwiftUI

let panelWidth: CGFloat = 300

/// Outer SwiftUI content for the glass panel. Transparent — the Liquid Glass
/// and resize live in AppKit (NSGlassEffectView); SwiftUI only fades/scales in
/// on open so the panel reads as "blurred → focus" like Control Center.
struct RootView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        MenuContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
            .tint(.blue)
            // The whole panel (glass + content) fades together via the window's
            // alpha; this just gates the content so it never flashes pre-sized.
            .opacity(state.panelVisible ? 1 : 0)
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
                shape.fill(LinearGradient(colors: [.blue, .blue.opacity(0.82)],
                                          startPoint: .top, endPoint: .bottom))
            } else {
                shape.fill(.white.opacity(0.08))
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(active ? 0.30 : 0.12), lineWidth: 0.8))
        .animation(.easeOut(duration: 0.2), value: active)
    }
}
