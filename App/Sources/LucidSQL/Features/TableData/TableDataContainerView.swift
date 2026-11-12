import SwiftUI
import LucidSQLBridge

public struct TableDataContainerView: View {
    @Bindable public var viewModel: TableDataViewModel
    public let config: ConnectionConfig
    public let onToggleReadOnly: (() -> Void)?

    public init(
        viewModel: TableDataViewModel,
        config: ConnectionConfig,
        onToggleReadOnly: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.config = config
        self.onToggleReadOnly = onToggleReadOnly
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 10) {
                // Table Identity
                HStack(spacing: 6) {
                    Image(systemName: "tablecells.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)

                    Text(viewModel.currentTable)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Text(viewModel.currentSchema)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())

                    if viewModel.isSystemSchema {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                            Text("System (Read-Only)")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .help("PostgreSQL system catalogs and schemas are read-only and cannot be edited.")
                    } else if viewModel.hasPrimaryKey {
                        HStack(spacing: 3) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                            Text("PK")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    } else if !viewModel.columns.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                            Text("No PK (Read-Only)")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .help("This table does not have a primary key. In-grid editing requires a primary key for safe row identity.")
                    }

                    if let onToggleReadOnly {
                        Button {
                            onToggleReadOnly()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: viewModel.isReadOnly ? "lock.fill" : "lock.open")
                                    .font(.system(size: 9))
                                Text(viewModel.isReadOnly ? "Read-Only" : "Read-Write")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(viewModel.isReadOnly ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.1), in: Capsule())
                            .foregroundStyle(viewModel.isReadOnly ? Color.orange : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.isReadOnly
                            ? "Read-only guardrail is active. Click to switch to Read-Write."
                            : "Click to enable read-only guardrail (disables table mutations)")
                    } else if viewModel.isReadOnly {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 8))
                            Text("Read-Only")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }

                Spacer()

                // Row Add / Delete Controls
                if viewModel.isEditable && !viewModel.columns.isEmpty {
                    HStack(spacing: 5) {
                        Button {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            viewModel.addDraftRow()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Add Row")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isLoading || viewModel.isApplying)
                        .help("Add a new local draft row (not written until Apply)")

                        let selectedIsPendingDelete = viewModel.selectedRowIndex.map { viewModel.isRowStagedForDeletion($0) } ?? false
                        let canDeleteSelected = viewModel.selectedRowIndex.map { viewModel.canDeleteRow($0) } ?? false

                        Button {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            viewModel.toggleDeleteSelectedRow()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: selectedIsPendingDelete ? "arrow.uturn.backward" : "trash")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(selectedIsPendingDelete ? "Undo Delete" : "Delete")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canDeleteSelected || viewModel.isLoading || viewModel.isApplying)
                        .help(selectedIsPendingDelete
                            ? "Un-stage deletion for the selected row"
                            : "Stage selected persisted row for deletion, or remove selected draft row")
                    }
                }

                // Staged Changes Actions
                if viewModel.hasPendingChanges {
                    HStack(spacing: 6) {
                        SecondaryActionButton(
                            title: "Discard (\(viewModel.totalStagedOperationsCount))",
                            icon: "arrow.uturn.backward",
                            size: .small
                        ) {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            viewModel.discardChanges()
                        }
                        .help("Discard all staged inserts, edits, and deletions for this table")

                        PrimaryActionButton(
                            title: "Apply (\(viewModel.totalStagedOperationsCount))",
                            icon: "checkmark",
                            size: .small
                        ) {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            viewModel.showingReviewSheet = true
                        }
                        .disabled(viewModel.isReadOnly || viewModel.isSystemSchema || viewModel.isApplying)
                        .help("Review and atomically apply staged changes")
                    }
                    .padding(.trailing, 4)
                }

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }

                // Compact Pagination Controls
                HStack(spacing: 5) {
                    Button {
                        viewModel.previousPage(config: config)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.offset == 0 || viewModel.isLoading)
                    .help("Previous Page")

                    Text(rowCountText)
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    Button {
                        viewModel.nextPage(config: config)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!viewModel.hasMore || viewModel.isLoading)
                    .help("Next Page")

                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, 2)

                    Button {
                        viewModel.reloadTable(config: config)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isLoading)
                    .help("Reload Table")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            // Success Status Banner if present
            if let status = viewModel.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                    Button {
                        viewModel.statusMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.08))
                Divider()
            }

            // Error Banner if present
            if let error = viewModel.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        viewModel.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                Divider()
            }

            // Grid View or Empty State - stable readable surface
            if viewModel.rows.isEmpty && viewModel.stagedInserts.isEmpty && !viewModel.isLoading {
                VStack(spacing: 12) {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                            .frame(width: 54, height: 54)
                        Image(systemName: "tablecells")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                    }
                    Text("No records found in \(viewModel.currentTable)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    if viewModel.isEditable && !viewModel.columns.isEmpty {
                        Button {
                            viewModel.addDraftRow()
                        } label: {
                            Label("Add Row", systemImage: "plus")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
            } else {
                DataTableView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
            }

            Divider()

            // Footer Status Bar
            HStack {
                let draftNote = viewModel.stagedInserts.isEmpty ? "" : " + \(viewModel.stagedInserts.count) draft"
                Text("\(viewModel.rows.count) rows fetched\(draftNote) in \(viewModel.executionDurationMs) ms (\(viewModel.columns.count) columns)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.isEditable {
                    Text("Double-click or Enter to edit • Tab to advance • ⎋ to cancel • ⌥⌘N for NULL • Right-click for row menu")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let reason = viewModel.nonEditableReason {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                if viewModel.hasPendingChanges {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text(viewModel.stagedSummaryText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
        }
        .sheet(isPresented: $viewModel.showingReviewSheet) {
            StagedChangesReviewSheet(viewModel: viewModel, config: config)
        }
        .alert("Unsaved Changes", isPresented: $viewModel.showingUnsavedChangesAlert) {
            Button("Discard Changes", role: .destructive) {
                viewModel.confirmDiscardAndNavigate()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelNavigation()
            }
        } message: {
            Text("You have \(viewModel.totalStagedOperationsCount) unsaved change\(viewModel.totalStagedOperationsCount == 1 ? "" : "s") (\(viewModel.stagedSummaryText)) in \(viewModel.currentTable). Discard changes to proceed, or cancel to stay on this view?")
        }
    }

    private var rowCountText: String {
        if viewModel.rows.isEmpty {
            return "0 rows"
        }
        return "\(viewModel.offset + 1)–\(viewModel.offset + UInt64(viewModel.rows.count))"
    }
}
