import SwiftUI

extension View {
    /// Keep vertical reading gestures intact; only a deliberate left-edge drag goes back.
    func watchEdgeBack(enabled: Bool = true) -> some View {
        modifier(WatchEdgeBack(enabled: enabled))
    }
}

private struct WatchEdgeBack: ViewModifier {
    let enabled: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var leaving = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .allowsHitTesting(enabled)
                    .gesture(DragGesture(minimumDistance: 24, coordinateSpace: .local)
                    .onEnded { value in
                        guard enabled, !leaving,
                              value.startLocation.x <= 28,
                              value.translation.width >= 48,
                              abs(value.translation.height) < value.translation.width * 0.65 else { return }
                        leaving = true
                        dismiss()
                    }
                    )
                    .accessibilityHidden(true)
            }
            .onAppear { leaving = false }
    }
}
