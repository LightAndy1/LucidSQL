import Foundation
import Observation
import LucidSQLBridge

@Observable
public final class TableDataViewModel: @unchecked Sendable {
    public var currentSchema: String = "public"
    public var currentTable: String = ""
    public var columns: [ColumnMetadata] = []
    public var rows: [RowData] = []
    public var offset: UInt64 = 0
    public var limit: UInt32 = 100
    public var hasMore: Bool = false
    public var executionDurationMs: UInt64 = 0
    public var isLoading: Bool = false
    public var errorMessage: String? = nil

    public var stagedEdits: [GridCoordinate: CellValue] = [:]

    public struct GridCoordinate: Hashable, Sendable {
        public let row: Int
        public let column: Int

        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    public init() {}

    public func loadTable(config: ConnectionConfig, schema: String, table: String) async {
        self.currentSchema = schema
        self.currentTable = table
        self.offset = 0
        self.stagedEdits.removeAll()
        await fetchPage(config: config)
    }

    public func fetchPage(config: ConnectionConfig) async {
        guard !currentTable.isEmpty else { return }
        self.isLoading = true
        self.errorMessage = nil

        do {
            let cols = try await introspect_columns(config: config, schema: currentSchema, table: currentTable)
            let page = try await fetch_table_page(
                config: config,
                schema: currentSchema,
                table: currentTable,
                offset: offset,
                limit: limit
            )

            self.columns = cols
            self.rows = page.rows
            self.hasMore = page.hasMore
            self.executionDurationMs = page.executionDurationMs
            self.isLoading = false
        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }

    public func nextPage(config: ConnectionConfig) async {
        guard hasMore else { return }
        self.offset += UInt64(limit)
        await fetchPage(config: config)
    }

    public func previousPage(config: ConnectionConfig) async {
        guard offset >= UInt64(limit) else { return }
        self.offset -= UInt64(limit)
        await fetchPage(config: config)
    }

    public func setCellValue(row: Int, column: Int, value: CellValue) {
        stagedEdits[GridCoordinate(row: row, column: column)] = value
    }

    public func discardChanges() {
        stagedEdits.removeAll()
    }
}
