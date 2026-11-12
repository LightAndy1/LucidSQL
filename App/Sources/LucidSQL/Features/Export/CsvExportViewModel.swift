import AppKit
import Foundation
import LucidSQLBridge
import Observation
import UniformTypeIdentifiers

public enum TableExportScope: String, CaseIterable, Identifiable, Sendable {
    case currentPage = "Current Fetched Page"
    case allRows = "All Rows in Table"

    public var id: String { rawValue }
}

public enum CsvExportTarget: Sendable {
    case sqlResults(
        tabTitle: String,
        columns: [ColumnMetadata],
        rows: [RowData],
        isTruncated: Bool,
        maxRows: UInt32
    )
    case tableData(
        config: ConnectionConfig,
        schema: String,
        table: String,
        columns: [ColumnMetadata],
        fetchedRows: [RowData],
        offset: UInt64,
        hasPrimaryKey: Bool,
        sortCol: String?,
        sortDesc: Bool,
        pendingChangesCount: Int,
        stagedSummary: String
    )
}

@Observable
@MainActor
public final class CsvExportViewModel: Identifiable {
    public nonisolated let id = UUID()
    public let target: CsvExportTarget
    public var tableScope: TableExportScope

    public var isExporting: Bool = false
    public var isCancelling: Bool = false
    public var rowsExportedSoFar: UInt64 = 0
    public var bytesWrittenSoFar: UInt64 = 0
    public var lastResult: CsvExportResult? = nil
    public var statusMessage: String? = nil
    public var errorMessage: String? = nil

    private var activeExportId: String? = nil
    private var activeTask: Task<Void, Never>? = nil
    private var progressTask: Task<Void, Never>? = nil

    private let destinationPicker: (@MainActor (_ suggestedName: String) -> URL?)

    public init(
        target: CsvExportTarget,
        initialTableScope: TableExportScope = .currentPage,
        destinationPicker: (@MainActor (_ suggestedName: String) -> URL?)? = nil
    ) {
        self.target = target
        self.tableScope = initialTableScope
        self.destinationPicker = destinationPicker ?? { suggested in
            Self.presentNativeSavePanel(suggestedFileName: suggested)
        }
    }

    public var isSqlTarget: Bool {
        if case .sqlResults = target { return true }
        return false
    }

    public var titleText: String {
        switch target {
        case .sqlResults:
            return "Export Fetched SQL Results to CSV"
        case .tableData(_, let schema, let table, _, _, _, _, _, _, _, _):
            return "Export \(schema).\(table) to CSV"
        }
    }

    public var suggestedFileName: String {
        switch target {
        case .sqlResults(let tabTitle, _, _, _, _):
            let clean = Self.sanitizeFileNameComponent(tabTitle)
            return "\(clean.isEmpty ? "query" : clean)_fetched_results.csv"
        case .tableData(_, let schema, let table, _, _, _, _, _, _, _, _):
            let s = Self.sanitizeFileNameComponent(schema)
            let t = Self.sanitizeFileNameComponent(table)
            let suffix = tableScope == .currentPage ? "_page" : "_all"
            return "\(s)_\(t)\(suffix).csv"
        }
    }

    public var fetchedRowCount: Int {
        switch target {
        case .sqlResults(_, _, let rows, _, _):
            return rows.count
        case .tableData(_, _, _, _, let fetchedRows, _, _, _, _, _, _):
            return fetchedRows.count
        }
    }

    public var isTruncatedSqlResult: Bool {
        if case .sqlResults(_, _, _, let isTruncated, _) = target {
            return isTruncated
        }
        return false
    }

    public var sqlMaxRows: UInt32 {
        if case .sqlResults(_, _, _, _, let maxRows) = target {
            return maxRows
        }
        return 0
    }

    public var hasPendingStagedTableChanges: Bool {
        if case .tableData(_, _, _, _, _, _, _, _, _, let count, _) = target {
            return count > 0
        }
        return false
    }

    public var pendingStagedSummary: String {
        if case .tableData(_, _, _, _, _, _, _, _, _, let count, let summary) = target, count > 0 {
            return "\(count) unapplied staged change\(count == 1 ? "" : "s") (\(summary))"
        }
        return ""
    }

    public var usesFetchedInMemoryRows: Bool {
        switch target {
        case .sqlResults:
            return true
        case .tableData:
            return tableScope == .currentPage
        }
    }

    /// Detects columns in already-fetched rows whose PostgreSQL type produced `CellValue.unsupported(...)`.
    /// When exporting fetched rows, LucidSQL refuses to emit placeholder strings like `"Unsupported (...)"`.
    public var unsupportedFetchedColumnDetails: [String] {
        let columns: [ColumnMetadata]
        let rows: [RowData]
        let offset: Int

        switch target {
        case .sqlResults(_, let cols, let r, _, _):
            columns = cols
            rows = r
            offset = 0
        case .tableData(_, _, _, let cols, let r, _, let hasPK, _, _, _, _):
            guard tableScope == .currentPage else { return [] }
            columns = cols
            rows = r
            offset = hasPK ? 1 : 0
        }

        var seen = Set<String>()
        var details: [String] = []
        for row in rows {
            for (colIdx, col) in columns.enumerated() {
                let rawIdx = colIdx + offset
                guard rawIdx < row.cells.count else { continue }
                if case .unsupported(let reason) = row.cells[rawIdx] {
                    let entry = "\(col.name) (\(reason))"
                    if seen.insert(entry).inserted {
                        details.append(entry)
                    }
                }
            }
        }
        return details
    }

    public var canStartExport: Bool {
        guard !isExporting else { return false }
        switch target {
        case .sqlResults(_, let columns, _, _, _):
            return !columns.isEmpty && unsupportedFetchedColumnDetails.isEmpty
        case .tableData(_, _, _, let columns, _, _, _, _, _, _, _):
            if tableScope == .currentPage {
                return !columns.isEmpty && unsupportedFetchedColumnDetails.isEmpty
            }
            return !columns.isEmpty
        }
    }

    public func chooseDestinationAndExport() {
        guard !isExporting else { return }
        guard let url = destinationPicker(suggestedFileName) else {
            return
        }
        startExport(to: url)
    }

    public func startExport(to destinationURL: URL) {
        let handle = startExportTask(to: destinationURL)
        activeTask = handle
    }

    @discardableResult
    public func exportToDestination(_ destinationURL: URL) async -> CsvExportResult? {
        let task = startExportTask(to: destinationURL)
        activeTask = task
        await task.value
        return lastResult
    }

    private func startExportTask(to destinationURL: URL) -> Task<Void, Never> {
        isExporting = true
        isCancelling = false
        rowsExportedSoFar = 0
        bytesWrittenSoFar = 0
        lastResult = nil
        statusMessage = nil
        errorMessage = nil

        let exportId = "export_\(UUID().uuidString)"
        activeExportId = exportId
        let destPath = destinationURL.path
        let currentTarget = target
        let currentScope = tableScope

        return Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.progressTask?.cancel()
                self.progressTask = nil
                self.isExporting = false
                self.isCancelling = false
                self.activeExportId = nil
                self.activeTask = nil
            }

            if case .tableData = currentTarget, currentScope == .allRows {
                self.progressTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        if let prog = get_export_progress(exportId: exportId) {
                            self?.rowsExportedSoFar = prog.rowsExported
                            self?.bytesWrittenSoFar = prog.bytesWritten
                            if prog.isFinished { break }
                        }
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }
                }
            }

            do {
                let result: CsvExportResult
                switch currentTarget {
                case .sqlResults(_, let columns, let rows, let isTruncated, _):
                    result = try await export_fetched_rows_csv(
                        columns: columns,
                        rows: rows,
                        destinationPath: destPath,
                        excludeLeadingXmin: false
                    )
                    let truncNote = isTruncated ? " (partial fetched set only)" : ""
                    self.statusMessage =
                        "Exported \(result.rowsExported) fetched rows\(truncNote) (\(Self.formatByteCount(result.bytesWritten))) to \(destinationURL.lastPathComponent)."

                case .tableData(let config, let schema, let table, let columns, let fetchedRows, _, let hasPrimaryKey, let sortCol, let sortDesc, _, _):
                    if currentScope == .currentPage {
                        result = try await export_fetched_rows_csv(
                            columns: columns,
                            rows: fetchedRows,
                            destinationPath: destPath,
                            excludeLeadingXmin: hasPrimaryKey
                        )
                        self.statusMessage =
                            "Exported current page (\(result.rowsExported) rows, \(Self.formatByteCount(result.bytesWritten))) to \(destinationURL.lastPathComponent)."
                    } else {
                        let req = TableCsvExportRequest(
                            schemaName: schema,
                            tableName: table,
                            sortCol: sortCol,
                            sortDesc: sortDesc
                        )
                        result = try await export_table_csv(
                            config: config,
                            request: req,
                            destinationPath: destPath,
                            exportId: exportId
                        )
                        let snap = result.snapshotIsolation ?? "REPEATABLE READ"
                        self.statusMessage =
                            "Exported \(result.rowsExported) rows (\(Self.formatByteCount(result.bytesWritten))) in \(result.executionDurationMs) ms (\(snap)) to \(destinationURL.lastPathComponent)."
                    }
                }

                self.rowsExportedSoFar = result.rowsExported
                self.bytesWrittenSoFar = result.bytesWritten
                self.lastResult = result
            } catch let error as LucidError {
                if case .QueryCancelled = error {
                    self.statusMessage = "Export cancelled. Temporary file cleaned up; any existing destination file was left untouched."
                } else {
                    self.errorMessage = error.userFacingMessage
                }
            } catch is CancellationError {
                self.statusMessage = "Export cancelled. Temporary file cleaned up; any existing destination file was left untouched."
            } catch {
                self.errorMessage = error.userFacingMessage
            }
        }
    }

    public func cancelExport() {
        guard isExporting, !isCancelling else { return }
        isCancelling = true
        if let exportId = activeExportId {
            Task {
                _ = try? await cancel_export(exportId: exportId)
            }
        }
    }

    public func revealExportedFileInFinder() {
        guard let path = lastResult?.destinationPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func presentNativeSavePanel(suggestedFileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export CSV"
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggestedFileName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    public static func formatByteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }

    private static func sanitizeFileNameComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "") { $0.append($1) }
    }
}
