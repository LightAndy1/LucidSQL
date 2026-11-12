import SwiftUI
import AppKit

/// High-level container applying macOS Liquid Glass effect (`NSGlassEffectView` on macOS 26+).
/// Falls back to `.ultraThinMaterial` on older OS releases and solid surface when Reduce Transparency is enabled.
public struct GlassSurface<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public let cornerRadius: CGFloat
    public let content: Content

    public init(cornerRadius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        if reduceTransparency {
            content
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
        } else if #available(macOS 26.0, *) {
            NativeGlassContainer(cornerRadius: cornerRadius) {
                content
            }
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 0.5)
                )
        }
    }
}

@available(macOS 26.0, *)
private struct NativeGlassContainer<Content: View>: NSViewRepresentable {
    let cornerRadius: CGFloat
    let content: Content

    init(cornerRadius: CGFloat, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glassView = NSGlassEffectView()
        glassView.cornerRadius = cornerRadius
        glassView.style = .regular

        let hostingView = NSHostingView(rootView: content)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = glassView.bounds
        glassView.contentView = hostingView

        return glassView
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
        if let hosting = nsView.contentView as? NSHostingView<Content> {
            hosting.rootView = content
        }
    }
}
