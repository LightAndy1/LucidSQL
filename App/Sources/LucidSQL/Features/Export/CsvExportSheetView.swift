import SwiftUI

public struct CsvExportSheetView: View {
    @Bindable public var viewModel: CsvExportViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: CsvExportViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.titleText)
                        .font(.system(size: 15, weight: .semibold))
                    Text("Suggested filename: \(viewModel.suggestedFileName)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            Divider()

            // Target & Consistency Explanation
            switch viewModel.target {
            case .sqlResults(let tabTitle, _, let rows, let isTruncated, let maxRows):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.plaintext")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Fetched SQL Results Only (\(rows.count) row\(rows.count == 1 ? "" : "s") from \"\(tabTitle)\")")
                            .font(.system(size: 12, weight: .semibold))
                    }

                    Text("Exports only the already-fetched rows displayed in this SQL tab. LucidSQL does not silently re-run arbitrary SQL to fetch un-displayed rows.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if isTruncated {
                        warningBox(
                            title: "Incomplete Export Warning (Limit Reached)",
                            message: "This SQL query stopped at the \(maxRows)-row limit. Exporting now will produce an incomplete CSV containing only the first \(rows.count) fetched rows."
                        )
                    }
                }

            case .tableData(_, _, _, _, let fetchedRows, let offset, _, let sortCol, let sortDesc, _, _):
                VStack(alignment: .leading, spacing: 10) {
                    Text("Export Scope")
                        .font(.system(size: 12, weight: .semibold))

                    Picker("Export Scope", selection: $viewModel.tableScope) {
                        Text("Current Fetched Page (\(fetchedRows.count) rows, from #\(offset + 1))")
                            .tag(TableExportScope.currentPage)
                        Text("All Rows Matching Current Order/Filters")
                            .tag(TableExportScope.allRows)
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(viewModel.isExporting)

                    if viewModel.tableScope == .allRows {
                        let orderDesc = sortCol.map { "ordered by \"\($0)\" \(sortDesc ? "DESC" : "ASC")" } ?? "natural scan order (no column filters active)"
                        infoBox(
                            title: "Streaming Snapshot Consistency",
                            message: "Streams directly from Rust to a temporary file on a separate PostgreSQL connection inside REPEATABLE READ READ ONLY (\(orderDesc)). Open SQL-tab transactions are unaffected, and the destination file is written atomically only on full success."
                        )
                    } else {
                        infoBox(
                            title: "Fetched Page Snapshot",
                            message: "Exports the \(fetchedRows.count) fetched database row(s) currently loaded in memory on this page (hidden internal xmin column omitted)."
                        )
                    }

                    if viewModel.hasPendingStagedTableChanges {
                        warningBox(
                            title: "Unapplied Staged Changes Excluded",
                            message: "You have \(viewModel.pendingStagedSummary) in the grid. Exports always represent fetched/database values and will NOT include unapplied edits, draft rows, or pending deletions."
                        )
                    } else {
                        Text("Note: Exports always contain database values only (no UI formatting, badges, or unapplied grid edits).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Unsupported Type Diagnostic
            let unsupportedCols = viewModel.unsupportedFetchedColumnDetails
            if !unsupportedCols.isEmpty {
                warningBox(
                    title: "Unsupported Column Type(s) in Fetched Result",
                    message: "Cannot export placeholder text for: \(unsupportedCols.joined(separator: ", ")). \(viewModel.isSqlTarget ? "Cast those columns with ::text in SQL to export their PostgreSQL text representations." : "Switch scope to \"All Rows Matching Current Order/Filters\" so PostgreSQL streams their canonical ::text representations.")"
                )
            }

            // CSV & NULL Semantics Documentation
            VStack(alignment: .leading, spacing: 4) {
                Text("CSV & NULL Semantics")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("RFC 4180 UTF-8 CSV (commas/quotes/newlines properly quoted). SQL NULL = unquoted empty field (e.g. a,,b); non-null empty string = quoted empty field (a,\"\",b). Exact decimals and timestamps are preserved without float rounding.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            // Progress / Status / Error
            if viewModel.isExporting {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.isCancelling ? "Cancelling export and cleaning up temporary file..." : "Streaming CSV export...")
                            .font(.system(size: 12, weight: .medium))
                        Text("\(viewModel.rowsExportedSoFar) rows • \(CsvExportViewModel.formatByteCount(viewModel.bytesWrittenSoFar))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Cancel Export", role: .destructive) {
                        viewModel.cancelExport()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isCancelling)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let error = viewModel.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.top, 1)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let status = viewModel.statusMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: viewModel.lastResult != nil ? "checkmark.circle.fill" : "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(viewModel.lastResult != nil ? .green : .secondary)
                        .padding(.top, 1)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.lastResult != nil ? .primary : .secondary)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(10)
                .background(
                    (viewModel.lastResult != nil ? Color.green : Color.secondary).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }

            Divider()

            // Footer Buttons
            HStack(spacing: 10) {
                if viewModel.lastResult != nil {
                    Button("Reveal in Finder") {
                        viewModel.revealExportedFileInFinder()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(viewModel.lastResult != nil ? "Done" : "Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isExporting)

                PrimaryActionButton(
                    title: "Choose Destination & Export...",
                    icon: "square.and.arrow.up",
                    size: .regular
                ) {
                    viewModel.chooseDestinationAndExport()
                }
                .disabled(!viewModel.canStartExport)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 580, maxWidth: 640)
    }

    @ViewBuilder
    private func warningBox(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private func infoBox(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
