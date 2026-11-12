import SwiftUI
import LucidSQLBridge

public struct TableDataContainerView: View {
    @Bindable public var viewModel: TableDataViewModel
    public let config: ConnectionConfig

    public init(viewModel: TableDataViewModel, config: ConnectionConfig) {
        self.viewModel = viewModel
        self.config = config
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

                    Text(viewModel.currentSchema)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())

                    if viewModel.hasPrimaryKey {
                        HStack(spacing: 3) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                            Text("PK")
                                .font(.system(size: 9, weight: .bold))
                        }
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
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .help("This table does not have a primary key. In-grid editing requires a primary key for safe row identity.")
                    }

                    if viewModel.isReadOnly {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 8))
                            Text("Read-Only")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }

                Spacer()

                // Staged Changes Actions
                if !viewModel.stagedEdits.isEmpty {
                    HStack(spacing: 6) {
                        SecondaryActionButton(
                            title: "Discard (\(viewModel.stagedEdits.count))",
                            icon: "arrow.uturn.backward",
                            size: .small
                        ) {
                            viewModel.discardChanges()
                        }
                        .help("Discard all staged edits for this table")

                        PrimaryActionButton(
                            title: "Apply (\(viewModel.stagedEdits.count))",
                            icon: "checkmark",
                            size: .small
                        ) {
                            viewModel.showingReviewSheet = true
                        }
                        .help("Review and atomically apply staged edits")
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
            if viewModel.rows.isEmpty && !viewModel.isLoading {
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
                Text("\(viewModel.rows.count) rows fetched in \(viewModel.executionDurationMs) ms (\(viewModel.columns.count) columns)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.isEditable {
                    Text("Double-click or Enter to edit • ⎋ to cancel • ⌥⌘N for NULL")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if !viewModel.stagedEdits.isEmpty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("\(viewModel.stagedEdits.count) staged changes")
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
            Text("You have \(viewModel.stagedEdits.count) unsaved edit\(viewModel.stagedEdits.count == 1 ? "" : "s") in \(viewModel.currentTable). Discard changes to proceed, or cancel to stay on this view?")
        }
    }

    private var rowCountText: String {
        if viewModel.rows.isEmpty {
            return "0 rows"
        }
        return "\(viewModel.offset + 1)–\(viewModel.offset + UInt64(viewModel.rows.count))"
    }
}
