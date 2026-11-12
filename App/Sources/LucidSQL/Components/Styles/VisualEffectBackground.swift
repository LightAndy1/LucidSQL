import AppKit
import SwiftUI

/// Behind-window visual effect background providing native macOS translucency.
/// Respects accessibility Reduce Transparency and system Dark/Light appearance.
public struct VisualEffectBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .underWindowBackground,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public var body: some View {
        if reduceTransparency {
            fallbackColor
                .ignoresSafeArea()
        } else {
            VisualEffectRepresentable(material: material, blendingMode: blendingMode)
                .ignoresSafeArea()
        }
    }

    private var fallbackColor: Color {
        if material == .sidebar {
            return Color(NSColor.windowBackgroundColor)
        } else {
            return Color(NSColor.controlBackgroundColor)
        }
    }
}

private struct VisualEffectRepresentable: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}
