import AppKit
import SwiftUI
import LucidSQLBridge

@MainActor
private final class PaginationPopoverState: ObservableObject {
    @Published var isPresented: Bool = false
    @Published var pageJumpInput: String = ""
    @Published var pageJumpError: String? = nil
}

public struct TableDataContainerView: View {
    @Bindable public var viewModel: TableDataViewModel
    public let config: ConnectionConfig
    public let onToggleReadOnly: (() -> Void)?

    @StateObject private var popoverState = PaginationPopoverState()

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
            // Minimal Main Table Header (stable layout across idle & editing states)
            HStack(spacing: 8) {
                // Table Identity & Safety State
                HStack(spacing: 6) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(viewModel.currentTable)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                        .help("\(viewModel.currentSchema).\(viewModel.currentTable)")

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
                                .font(.system(size: 8.5, weight: .semibold))
                            Text("System")
                                .font(.system(size: 10, weight: .medium))
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
                                .font(.system(size: 8.5, weight: .semibold))
                            Text("PK")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .help("Table has primary key for safe row-level edits.")
                    } else if !viewModel.columns.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text("No PK")
                                .font(.system(size: 10, weight: .medium))
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
                            HStack(spacing: 3.5) {
                                Image(systemName: viewModel.isReadOnly ? "lock.fill" : "lock.open")
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text(viewModel.isReadOnly ? "Read-Only" : "Read-Write")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(viewModel.isReadOnly ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.1), in: Capsule())
                            .foregroundStyle(viewModel.isReadOnly ? Color.orange : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.isReadOnly
                            ? "Read-only guardrail is active. Click to switch to Read-Write."
                            : "Click to enable read-only guardrail (disables table mutations)")
                    } else if viewModel.isReadOnly {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text("Read-Only")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                // Consistent Glass Capsule Controls
                HStack(spacing: 8) {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if viewModel.isEditable && !viewModel.columns.isEmpty {
                        Button {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            viewModel.addDraftRow()
                        } label: {
                            Label("Add Row", systemImage: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .toolbarCapsuleControlStyle(size: .small)
                        .disabled(viewModel.isLoading || viewModel.isApplying)
                        .help("Add a new local draft row (not written until Apply)")
                    }

                    // Pagination & Refresh Cluster
                    HStack(spacing: 4) {
                        Button {
                            viewModel.previousPage(config: config)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .toolbarCapsuleControlStyle(size: .small)
                        .disabled(viewModel.offset == 0 || viewModel.isLoading)
                        .accessibilityLabel("Previous Page")
                        .help("Previous Page")

                        Button {
                            popoverState.pageJumpInput = "\(viewModel.currentPage)"
                            popoverState.pageJumpError = nil
                            popoverState.isPresented.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Text(rowCountText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Color.secondary.opacity(popoverState.isPresented ? 0.14 : 0.08),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.currentTable.isEmpty)
                        .accessibilityLabel("Pagination options, \(rowCountText)")
                        .help("Rows per page & go to page")
                        .popover(isPresented: $popoverState.isPresented, arrowEdge: .bottom) {
                            paginationPopoverContent
                        }

                        Button {
                            viewModel.nextPage(config: config)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .toolbarCapsuleControlStyle(size: .small)
                        .disabled(!viewModel.hasMore || viewModel.isLoading)
                        .accessibilityLabel("Next Page")
                        .help("Next Page")

                        Button {
                            viewModel.reloadTable(config: config)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .toolbarCapsuleControlStyle(size: .small)
                        .disabled(viewModel.isLoading)
                        .accessibilityLabel("Reload Table")
                        .help("Reload Table")
                    }

                    // Secondary & Row Operations Overflow Menu
                    let selectedIsPendingDelete = viewModel.selectedRowIndex.map { viewModel.isRowStagedForDeletion($0) } ?? false
                    let canDeleteSelected = viewModel.selectedRowIndex.map { viewModel.canDeleteRow($0) } ?? false

                    Menu {
                        Button {
                            viewModel.openSearchBar()
                        } label: {
                            Label("Search Table…", systemImage: "magnifyingglass")
                        }
                        .disabled(viewModel.currentTable.isEmpty)

                        Divider()

                        if viewModel.isEditable && !viewModel.columns.isEmpty {
                            Button(role: selectedIsPendingDelete ? nil : .destructive) {
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                viewModel.toggleDeleteSelectedRow()
                            } label: {
                                Label(
                                    selectedIsPendingDelete ? "Undo Delete Selected Row" : "Delete Selected Row",
                                    systemImage: selectedIsPendingDelete ? "arrow.uturn.backward" : "trash"
                                )
                            }
                            .keyboardShortcut(.delete, modifiers: [.command])
                            .disabled(!canDeleteSelected || viewModel.isLoading || viewModel.isApplying)

                            Divider()
                        }

                        Button {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            _ = viewModel.prepareCsvExport(config: config)
                        } label: {
                            Label("Export CSV…", systemImage: "square.and.arrow.up")
                        }
                        .disabled(viewModel.columns.isEmpty || viewModel.isLoading)

                        if let onToggleReadOnly {
                            Divider()
                            Button {
                                onToggleReadOnly()
                            } label: {
                                Label(
                                    viewModel.isReadOnly ? "Allow Read-Write Editing" : "Enable Read-Only Mode",
                                    systemImage: viewModel.isReadOnly ? "lock.open" : "lock.fill"
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuIndicator(.hidden)
                    .toolbarCapsuleControlStyle(size: .small)
                    .accessibilityLabel("More Table Actions")
                    .help("More table and row actions (Search Table, Delete Row, Export CSV, Read-Only)")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            // Non-SQL Compact "Search table" Bar (revealed on demand via Cmd+F or menu)
            if viewModel.isSearchBarVisible {
                tableSearchBar
                Divider()
            }

            // Stable Pending-Changes Action Bar (grouped Apply/Discard without crowding the main header)
            if viewModel.hasPendingChanges {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                        Text("Pending changes: \(viewModel.stagedSummaryText)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        Button {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            viewModel.discardChanges()
                        } label: {
                            Label("Discard", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .toolbarCapsuleControlStyle(size: .small)
                        .disabled(viewModel.isApplying)
                        .help("Discard all staged inserts, edits, and deletions for this table")

                        Button {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            viewModel.showingReviewSheet = true
                        } label: {
                            Label("Apply (\(viewModel.totalStagedOperationsCount))", systemImage: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .toolbarCapsuleControlStyle(prominent: true, size: .small)
                        .disabled(viewModel.isReadOnly || viewModel.isSystemSchema || viewModel.isApplying)
                        .help(viewModel.isReadOnly || viewModel.isSystemSchema
                            ? "Read-only mode active; switch to Read-Write to apply changes"
                            : "Review and atomically apply staged changes")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.08))

                Divider()
            }

            // Success Status Banner if present
            if let status = viewModel.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer(minLength: 4)
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

            // Error Banner if present (shown above populated rows or for uncertain commits)
            if let error = viewModel.errorMessage,
               !viewModel.rows.isEmpty || !viewModel.stagedInserts.isEmpty || viewModel.hasUncertainCommitOutcome {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.hasUncertainCommitOutcome ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(viewModel.hasUncertainCommitOutcome ? .orange : .red)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(viewModel.hasUncertainCommitOutcome ? .orange : .red)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    if viewModel.hasUncertainCommitOutcome {
                        Button("Reload & Reconcile") {
                            Task {
                                await viewModel.reconcileUncertainCommit(config: config)
                            }
                        }
                        .toolbarCapsuleControlStyle(prominent: true, size: .small)
                        .tint(.orange)
                    } else {
                        Button("Retry") {
                            viewModel.reloadTable(config: config)
                        }
                        .toolbarCapsuleControlStyle(size: .small)

                        Button {
                            viewModel.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((viewModel.hasUncertainCommitOutcome ? Color.orange : Color.red).opacity(0.08))
                Divider()
            }

            // Grid View, Immediate Loading State, Error State, or Empty State (keep DataTableView mounted for cell/column reuse)
            ZStack {
                DataTableView(
                    viewModel: viewModel,
                    renderSignature: DataTableView.RenderSignature(from: viewModel)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))

                if viewModel.isLoading && viewModel.rows.isEmpty && viewModel.stagedInserts.isEmpty {
                    VStack(spacing: 10) {
                        Spacer(minLength: 4)
                        ProgressView()
                            .controlSize(.regular)
                        Text("Loading \(viewModel.currentSchema).\(viewModel.currentTable)…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
                } else if let error = viewModel.errorMessage,
                          viewModel.rows.isEmpty && viewModel.stagedInserts.isEmpty {
                    VStack(spacing: 12) {
                        Spacer(minLength: 4)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.red)
                        Text("Failed to load \(viewModel.currentSchema).\(viewModel.currentTable)")
                            .font(.system(size: 13, weight: .semibold))
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .frame(maxWidth: 420)
                        Button("Retry") {
                            viewModel.reloadTable(config: config)
                        }
                        .toolbarCapsuleControlStyle(prominent: true, size: .small)
                        Spacer(minLength: 4)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
                } else if viewModel.rows.isEmpty && viewModel.stagedInserts.isEmpty {
                    VStack(spacing: 12) {
                        Spacer(minLength: 4)
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.secondary.opacity(0.08))
                                .frame(width: 54, height: 54)
                            Image(systemName: viewModel.isOutOfRangeEmptyPage ? "doc.text.magnifyingglass" : (viewModel.isSearchActive ? "magnifyingglass" : "tablecells"))
                                .font(.system(size: 26))
                                .foregroundStyle(.tertiary)
                        }
                        if viewModel.isOutOfRangeEmptyPage {
                            Text("No rows on page \(viewModel.currentPage)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Offset \(viewModel.offset) is past the available \(viewModel.isSearchActive ? "matching rows" : "rows in \(viewModel.currentTable)").")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                            Button {
                                viewModel.goToFirstPage(config: config)
                            } label: {
                                Label("Back to Page 1", systemImage: "arrow.uturn.left")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .toolbarCapsuleControlStyle(prominent: true, size: .small)
                        } else if viewModel.isSearchActive {
                            Text("No matching rows in \(viewModel.currentTable)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("No case-insensitive literal matches for \"\(viewModel.appliedSearchQuery ?? "")\" in \(viewModel.appliedSearchColumn ?? "all searchable columns").")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                            Button {
                                viewModel.clearSearch(config: config)
                            } label: {
                                Label("Clear Search", systemImage: "xmark.circle")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .toolbarCapsuleControlStyle(prominent: true, size: .small)
                        } else {
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
                                .toolbarCapsuleControlStyle(prominent: true, size: .small)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
                }
            }

            Divider()

            // Footer Status Bar
            HStack {
                let draftNote = viewModel.stagedInserts.isEmpty ? "" : " + \(viewModel.stagedInserts.count) draft"
                let totalNote = viewModel.knownTotalRows.map { " • \($0) total" } ?? ""
                let filterNote = viewModel.isSearchActive ? " • Filtered" : ""
                Text("\(viewModel.rows.count) rows fetched\(draftNote) in \(viewModel.executionDurationMs) ms (\(viewModel.columns.count) columns)\(totalNote)\(filterNote)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                if viewModel.isEditable {
                    Text("Double-click or Return to edit • ⌥⌘N for NULL • ⌘⌫ or right-click for row menu")
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

                Spacer(minLength: 4)

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
        .sheet(item: $viewModel.exportViewModel) { exportVM in
            CsvExportSheetView(viewModel: exportVM)
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

    // MARK: - Non-SQL Search Table Bar

    private var tableSearchBar: some View {
        let canSearchColumns = viewModel.columns.isEmpty || viewModel.hasSearchableColumns

        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Search table")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 6) {
                TableSearchTextField(
                    text: viewModel.searchInputText,
                    placeholder: canSearchColumns
                        ? "Case-insensitive literal match across table…"
                        : "No searchable columns in this table",
                    isEnabled: canSearchColumns,
                    focusToken: viewModel.searchFocusToken,
                    onTextChange: { newValue in
                        viewModel.updateSearchInput(newValue, config: config)
                    },
                    onSubmit: {
                        viewModel.submitSearchNow(config: config)
                    },
                    onEscape: {
                        viewModel.dismissSearchBar(config: config)
                    }
                )
                .frame(minWidth: 160, maxWidth: 320, minHeight: 20, maxHeight: 20)

                if viewModel.isLoading && (viewModel.isSearchActive || !viewModel.searchInputText.isEmpty) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                }

                if !viewModel.searchInputText.isEmpty || viewModel.isSearchActive {
                    Button {
                        viewModel.clearSearch(config: config)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search and restore normal browsing")
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
            )

            // Column Dropdown (defaults to All searchable columns; non-searchable columns disabled explicitly)
            Menu {
                Button {
                    viewModel.updateSearchColumn(nil, config: config)
                } label: {
                    if viewModel.searchSelectedColumn == nil {
                        Label("All searchable columns", systemImage: "checkmark")
                    } else {
                        Text("All searchable columns")
                    }
                }

                if !viewModel.searchableColumns.isEmpty {
                    Divider()
                    ForEach(viewModel.searchableColumns, id: \.name) { col in
                        Button {
                            viewModel.updateSearchColumn(col.name, config: config)
                        } label: {
                            if viewModel.searchSelectedColumn == col.name {
                                Label("\(col.name) (\(col.pgTypeName))", systemImage: "checkmark")
                            } else {
                                Text("\(col.name) (\(col.pgTypeName))")
                            }
                        }
                    }
                }

                if !viewModel.nonSearchableColumns.isEmpty {
                    Divider()
                    Text("Not searchable (binary, JSON, array, geometric)")
                        .font(.caption)
                    ForEach(viewModel.nonSearchableColumns, id: \.name) { col in
                        Button {
                            // Disabled
                        } label: {
                            Text("\(col.name) (\(col.pgTypeName))")
                        }
                        .disabled(true)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(viewModel.searchSelectedColumn ?? "All searchable columns")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: 210, alignment: .leading)
            .disabled(!canSearchColumns)
            .help("Choose a searchable column or search across all searchable text/scalar columns")
            .accessibilityLabel("Search column scope")

            if !viewModel.columns.isEmpty && !viewModel.hasSearchableColumns {
                Text("No searchable columns")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if viewModel.isSearchActive && !viewModel.isLoading && viewModel.errorMessage == nil {
                if viewModel.rows.isEmpty && viewModel.offset == 0 {
                    Text("No results")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let total = viewModel.knownTotalRows {
                    Text("\(total) \(total == 1 ? "match" : "matches")")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Page \(viewModel.currentPage)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button {
                viewModel.dismissSearchBar(config: config)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(viewModel.isSearchActive ? "Clear search and close bar (Esc)" : "Close search bar (Esc)")
            .accessibilityLabel("Dismiss Search Table")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .onExitCommand {
            viewModel.dismissSearchBar(config: config)
        }
    }

    // MARK: - Pagination Popover

    private var paginationPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Pagination")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(paginationSummaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Rows per page")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    ForEach(TableDataViewModel.pageSizePresets, id: \.self) { size in
                        let isSelected = viewModel.limit == size
                        Button {
                            popoverState.pageJumpError = nil
                            viewModel.setPageSize(size, config: config)
                            popoverState.isPresented = false
                        } label: {
                            Text("\(size)")
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .monospaced))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.09))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(isSelected ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1)
                                )
                                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isLoading)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Go to page")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    TextField("Page #", text: $popoverState.pageJumpInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onChange(of: popoverState.pageJumpInput) { _, _ in
                            popoverState.pageJumpError = nil
                        }
                        .onSubmit {
                            submitPageJump()
                        }

                    Button("Go") {
                        submitPageJump()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isLoading)
                }

                if let errorText = popoverState.pageJumpError {
                    Text(errorText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: viewModel.hasPrimaryKey ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(viewModel.hasPrimaryKey ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                Text(paginationOrderingNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 274)
    }

    private func submitPageJump() {
        switch viewModel.validatePageInput(popoverState.pageJumpInput) {
        case .valid(let targetPage):
            popoverState.pageJumpError = nil
            if viewModel.goToPage(targetPage, config: config) {
                popoverState.isPresented = false
            }
        case .invalid(let message):
            popoverState.pageJumpError = message
        }
    }

    private var paginationSummaryText: String {
        let noun = viewModel.isSearchActive ? "matching rows" : "rows"
        if let totalRows = viewModel.knownTotalRows, let totalPages = viewModel.knownTotalPages {
            return "Page \(viewModel.currentPage) of \(totalPages) • \(totalRows) \(noun)"
        }
        if viewModel.rows.isEmpty && viewModel.offset == 0 {
            return viewModel.isSearchActive ? "0 matching rows" : "0 rows in table"
        }
        if viewModel.isOutOfRangeEmptyPage {
            return "Page \(viewModel.currentPage) has no rows (past end)."
        }
        return "Page \(viewModel.currentPage) (\(viewModel.limit) per page). Total \(noun) not pre-counted."
    }

    private var paginationOrderingNote: String {
        if !viewModel.columns.isEmpty && !viewModel.hasPrimaryKey {
            return "No primary key on this table: page order follows storage order and rows may shift between pages."
        }
        return "Rows are ordered deterministically with primary-key tie-breakers."
    }

    private var rowCountText: String {
        if viewModel.rows.isEmpty {
            return viewModel.offset > 0 ? "Page \(viewModel.currentPage) (0)" : "0 rows"
        }
        let range = "\(viewModel.offset + 1)–\(viewModel.offset + UInt64(viewModel.rows.count))"
        if let total = viewModel.knownTotalRows {
            return "\(range) of \(total)"
        }
        return range
    }
}

private struct TableSearchTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let isEnabled: Bool
    let focusToken: UInt64
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 12)
        field.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.placeholderString = placeholder
        field.stringValue = text
        field.isEnabled = isEnabled
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = placeholder
        nsView.isEnabled = isEnabled

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if focusToken != context.coordinator.lastFocusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                window.makeFirstResponder(nsView)
                nsView.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TableSearchTextField
        var lastFocusToken: UInt64 = 0

        init(_ parent: TableSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.onTextChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
