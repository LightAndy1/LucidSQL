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
        let inserts = viewModel.stagedInsertItems
        let diffs = viewModel.stagedDiffs
        let deletes = viewModel.stagedDeleteItems
        let validationIssues = viewModel.draftValidationIssues

        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Pending Table Changes")
                        .font(.system(size: 16, weight: .bold))

                    Text("Target: \(viewModel.currentSchema).\(viewModel.currentTable) • \(viewModel.stagedSummaryText) across \(viewModel.stagedRowsCount) row\(viewModel.stagedRowsCount == 1 ? "" : "s")")
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

            if inserts.isEmpty && diffs.isEmpty && deletes.isEmpty {
                Text("No changes staged.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: 180)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Phase 1: Deletions
                        if !deletes.isEmpty {
                            sectionHeader(
                                title: "1. Row Deletions (\(deletes.count))",
                                badgeColor: .red
                            )

                            ForEach(deletes) { item in
                                HStack(spacing: 10) {
                                    Text("DELETE")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.red)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red.opacity(0.14), in: Capsule())

                                    Text(item.primaryKeyDescription)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .lineLimit(1)

                                    if !item.summary.isEmpty {
                                        Text(item.summary)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }

                                    Spacer()

                                    Button("Undo") {
                                        viewModel.unstageDeleteRow(row: item.row)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .disabled(viewModel.isApplying)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }

                        // Phase 2: Updates
                        if !diffs.isEmpty {
                            sectionHeader(
                                title: "2. Cell Updates (\(diffs.count))",
                                badgeColor: .orange
                            )

                            ForEach(diffs) { diff in
                                HStack(spacing: 12) {
                                    Text(diff.primaryKeyDescription)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(width: 130, alignment: .leading)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    Text(diff.columnName)
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(width: 105, alignment: .leading)
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
                                        valueBadge(for: diff.newValue)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }

                        // Phase 3: Insertions
                        if !inserts.isEmpty {
                            sectionHeader(
                                title: "3. New Row Insertions (\(inserts.count))",
                                badgeColor: .green
                            )

                            ForEach(inserts) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text("INSERT +\(item.draftIndex + 1)")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.14), in: Capsule())

                                        if !item.missingRequiredColumns.isEmpty {
                                            Text("Missing NOT NULL: \(item.missingRequiredColumns.joined(separator: ", "))")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.red)
                                        }

                                        Spacer()

                                        Button("Remove") {
                                            viewModel.stageDeleteRow(row: item.gridRow)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                        .disabled(viewModel.isApplying)
                                    }

                                    ForEach(item.columns) { col in
                                        HStack(spacing: 10) {
                                            Text(col.columnName)
                                                .font(.system(size: 11, weight: .medium))
                                                .frame(width: 140, alignment: .leading)
                                                .lineLimit(1)
                                                .truncationMode(.tail)

                                            if col.isMissingRequired {
                                                Text("REQUIRED (missing)")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(.red)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.red.opacity(0.12), in: Capsule())
                                            } else if col.isAutoGenerated {
                                                Text("AUTO (server generated)")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.secondary.opacity(0.1), in: Capsule())
                                            } else if col.isDefault {
                                                Text("DEFAULT (omitted)")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(.indigo)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.indigo.opacity(0.12), in: Capsule())
                                            } else if let value = col.value {
                                                valueBadge(for: value)
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                                .padding(10)
                                .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(
                                            item.missingRequiredColumns.isEmpty
                                                ? Color.green.opacity(0.2)
                                                : Color.red.opacity(0.35),
                                            lineWidth: 1
                                        )
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 160, maxHeight: 320)
            }

            if !validationIssues.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                        .padding(.top, 1)
                    Text(validationIssues.joined(separator: " "))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            // Safety & ordering notice
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                Text("Atomic Transaction (Order: 1. Deletes → 2. Updates → 3. Inserts): Updates and deletes verify row `xmin` to prevent lost overwrites. Any conflict or constraint error aborts and rolls back the whole batch while keeping your staged work intact. Cross-row FK references to unsaved server-generated keys must be applied in separate batches.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            if let error = viewModel.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                        .padding(.top, 1)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
                )
            }

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

                if viewModel.errorMessage != nil {
                    Button("Discard & Reload") {
                        Task {
                            await viewModel.discardAndReload(config: config)
                            dismiss()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(viewModel.isApplying)
                }

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
                .disabled(viewModel.isApplying || !viewModel.hasPendingChanges || !validationIssues.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 680, maxWidth: 760)
    }

    @ViewBuilder
    private func sectionHeader(title: String, badgeColor: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func valueBadge(for value: CellValue) -> some View {
        if value.isNull {
            Text("NULL")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.12), in: Capsule())
        } else if case .text(let s) = value, s.isEmpty {
            Text("\"\" (empty)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.blue)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.blue.opacity(0.1), in: Capsule())
        } else {
            Text(value.displayString)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}
