import SwiftUI

public struct PrimaryGlassButtonStyle: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
        } else {
            content
                .buttonStyle(.borderedProminent)
        }
        #else
        content
            .buttonStyle(.borderedProminent)
        #endif
    }
}

public extension View {
    func primaryGlassStyle() -> some View {
        self.modifier(PrimaryGlassButtonStyle())
    }
}
