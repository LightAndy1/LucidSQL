import SwiftUI
import LucidSQLBridge

public struct StagedChangesReviewSheet: View {
    public let viewModel: TableDataViewModel
    public let config: ConnectionConfig
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: TableDataViewModel, config: ConnectionConfig) {
        self.viewModel = viewModel
        self.config = config
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Pending Table Edits")
                        .font(.system(size: 16, weight: .bold))

                    Text("Target: \(viewModel.currentSchema).\(viewModel.currentTable) • \(viewModel.stagedEdits.count) change\(viewModel.stagedEdits.count == 1 ? "" : "s") across \(viewModel.stagedRowsCount) row\(viewModel.stagedRowsCount == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.isApplying {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            // Diffs Table
            let diffs = viewModel.stagedDiffs
            if diffs.isEmpty {
                Text("No changes staged.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: 180)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        // Header row
                        HStack(spacing: 12) {
                            Text("Row (Primary Key)")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 140, alignment: .leading)
                            Text("Column")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 110, alignment: .leading)
                            Text("Original Value")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Staged New Value")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                        ForEach(diffs) { diff in
                            HStack(spacing: 12) {
                                Text(diff.primaryKeyDescription)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 140, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Text(diff.columnName)
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 110, alignment: .leading)
                                    .lineLimit(1)

                                HStack(spacing: 4) {
                                    if diff.originalValue.isNull {
                                        Text("NULL")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(diff.originalValue.displayString)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .strikethrough(color: .secondary.opacity(0.6))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                HStack(spacing: 4) {
                                    if diff.newValue.isNull {
                                        Text("NULL")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.orange.opacity(0.12), in: Capsule())
                                    } else if case .text(let s) = diff.newValue, s.isEmpty {
                                        Text("\"\" (empty)")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.blue)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.1), in: Capsule())
                                    } else {
                                        Text(diff.newValue.displayString)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 140, maxHeight: 280)
            }

            // Safety notice
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Atomic Transaction: updates include an `xmin` optimistic concurrency check. If another session altered or deleted any row, the batch will abort with zero writes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            Divider()

            // Footer Actions
            HStack(spacing: 12) {
                Button("Discard All", role: .destructive) {
                    viewModel.discardChanges()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(viewModel.isApplying)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)
                .disabled(viewModel.isApplying)

                PrimaryActionButton(
                    title: viewModel.isApplying ? "Applying..." : "Apply Changes",
                    icon: "checkmark",
                    size: .regular
                ) {
                    Task {
                        await viewModel.applyStagedEdits(config: config)
                        if viewModel.errorMessage == nil {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isApplying || viewModel.stagedEdits.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 580, idealWidth: 640, maxWidth: 720)
    }
}
