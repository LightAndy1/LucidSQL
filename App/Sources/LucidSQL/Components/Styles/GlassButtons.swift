import SwiftUI

/// Primary call-to-action button adhering to modern macOS (macOS 26+) Liquid Glass design language.
/// Uses a real system `Button` control with native untinted `.glass` style, native capsule border shape,
/// and system control sizing, distinguishing primary actions by size/placement rather than solid fills.
public struct PrimaryActionButton: View {
    public let title: String
    public let icon: String
    public let size: ControlSize
    public let action: () -> Void

    public init(
        title: String,
        icon: String = "",
        size: ControlSize = .regular,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.size = size
        self.action = action
    }

    public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Button(action: action) {
                buttonLabel
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(size)
        } else {
            fallbackButton
        }
        #else
        fallbackButton
        #endif
    }

    @ViewBuilder
    private var fallbackButton: some View {
        Button(action: action) {
            buttonLabel
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(size)
    }

    @ViewBuilder
    private var buttonLabel: some View {
        if !icon.isEmpty {
            Label(title, systemImage: icon)
        } else {
            Text(title)
        }
    }
}

/// Secondary action button using native untinted `.glass` on macOS 26+ with native capsule border shape,
/// matching `PrimaryActionButton` in system sizing and interaction feedback.
public struct SecondaryActionButton: View {
    public let title: String
    public let icon: String
    public let size: ControlSize
    public let action: () -> Void

    public init(
        title: String,
        icon: String = "",
        size: ControlSize = .regular,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.size = size
        self.action = action
    }

    public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Button(action: action) {
                buttonLabel
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(size)
        } else {
            fallbackButton
        }
        #else
        fallbackButton
        #endif
    }

    @ViewBuilder
    private var fallbackButton: some View {
        Button(action: action) {
            buttonLabel
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(size)
    }

    @ViewBuilder
    private var buttonLabel: some View {
        if !icon.isEmpty {
            Label(title, systemImage: icon)
        } else {
            Text(title)
        }
    }
}
