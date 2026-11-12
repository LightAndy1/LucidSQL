import SwiftUI

public struct PrimaryGlassButtonStyle: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
        } else {
            content
                .buttonStyle(.borderedProminent)
        }
    }
}

public extension View {
    func primaryGlassStyle() -> some View {
        self.modifier(PrimaryGlassButtonStyle())
    }
}
