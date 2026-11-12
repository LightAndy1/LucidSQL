import SwiftUI

public struct KeyboardBadge: View {
    public let keys: [String]
    public let label: String

    public init(keys: [String], label: String) {
        self.keys = keys
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
