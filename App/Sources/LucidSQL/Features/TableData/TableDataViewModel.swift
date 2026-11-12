import Foundation
import Observation
import LucidSQLBridge

@Observable
public final class TableDataViewModel: @unchecked Sendable {
    public var currentSchema: String = "public"
    public var currentTable: String = ""
    public var columns: [ColumnMetadata] = []
    public var rows: [RowData] = []
    public private(set) var dataVersion: UInt64 = 0
    public var offset: UInt64 = 0
    public var limit: UInt32 = 100
    public var hasMore: Bool = false
    public var executionDurationMs: UInt64 = 0
    public var isLoading: Bool = false
    public var isApplying: Bool = false
    public var isReadOnly: Bool = false
    public var errorMessage: String? = nil
    public var statusMessage: String? = nil

    public var stagedEdits: [GridCoordinate: CellValue] = [:]
    public var showingReviewSheet: Bool = false
    public var showingUnsavedChangesAlert: Bool = false
    public var pendingNavigationAction: (() -> Void)? = nil

    public struct GridCoordinate: Hashable, Sendable {
        public let row: Int
        public let column: Int

        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    public struct StagedEditDiff: Identifiable, Sendable {
        public let id: String
        public let row: Int
        public let column: Int
        public let columnName: String
        public let primaryKeyDescription: String
        public let originalValue: CellValue
        public let newValue: CellValue

        public init(
            id: String = UUID().uuidString,
            row: Int,
            column: Int,
            columnName: String,
            primaryKeyDescription: String,
            originalValue: CellValue,
            newValue: CellValue
        ) {
            self.id = id
            self.row = row
            self.column = column
            self.columnName = columnName
            self.primaryKeyDescription = primaryKeyDescription
            self.originalValue = originalValue
            self.newValue = newValue
        }
    }

    public init() {}

    public var hasPrimaryKey: Bool {
        columns.contains { $0.isPrimaryKey }
    }

    public var isSystemSchema: Bool {
        let lower = currentSchema.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "pg_catalog" || lower == "information_schema" || lower.hasPrefix("pg_")
    }

    public var isEditable: Bool {
        hasPrimaryKey && !isReadOnly && !isSystemSchema
    }

    public var nonEditableReason: String? {
        if isReadOnly {
            return "Read-only guardrail is active. Editing is disabled."
        }
        if isSystemSchema {
            return "System schema '\(currentSchema)' is read-only. Catalog tables cannot be edited."
        }
        if !hasPrimaryKey && !columns.isEmpty {
            return "Table has no primary key. In-grid editing requires a primary key for safe row identity."
        }
        return nil
    }

    public var stagedRowsCount: Int {
        Set(stagedEdits.keys.map(\.row)).count
    }

    public func originalCellValue(row: Int, column: Int) -> CellValue? {
        guard row >= 0, row < rows.count, column >= 0, column < columns.count else {
            return nil
        }
        let rawRow = rows[row]
        let rawColIdx = hasPrimaryKey ? (column + 1) : column
        guard rawColIdx < rawRow.cells.count else { return nil }
        return rawRow.cells[rawColIdx]
    }

    public func rowXmin(row: Int) -> String? {
        guard hasPrimaryKey, row >= 0, row < rows.count else { return nil }
        guard let xmin = rows[row].cells.first?.rawTextValue,
              !xmin.isEmpty,
              xmin.allSatisfy(\.isASCII),
              xmin.allSatisfy(\.isNumber) else {
            return nil
        }
        return xmin
    }

    public func isRowIdentifiable(row: Int) -> Bool {
        guard hasPrimaryKey, rowXmin(row: row) != nil else { return false }
        let pkIndices = columns.indices.filter { columns[$0].isPrimaryKey }
        guard !pkIndices.isEmpty else { return false }
        for pkIdx in pkIndices {
            guard let pkVal = originalCellValue(row: row, column: pkIdx),
                  !pkVal.isNull,
                  !pkVal.isUnsupported else {
                return false
            }
        }
        return true
    }

    public func isCellEditable(row: Int, column: Int) -> Bool {
        guard isEditable, row >= 0, row < rows.count, column >= 0, column < columns.count else {
            return false
        }
        if columns[column].isGenerated {
            return false
        }
        guard isRowIdentifiable(row: row) else {
            return false
        }
        if let orig = originalCellValue(row: row, column: column), orig.isUnsupported {
            return false
        }
        return true
    }

    public func canSetNull(row: Int, column: Int) -> Bool {
        guard isCellEditable(row: row, column: column) else { return false }
        let col = columns[column]
        return col.isNullable && !col.isPrimaryKey
    }

    public var stagedDiffs: [StagedEditDiff] {
        guard hasPrimaryKey else { return [] }
        var diffs: [StagedEditDiff] = []

        let pkCols = columns.filter { $0.isPrimaryKey }

        for (coord, newVal) in stagedEdits.sorted(by: { $0.key.row < $1.key.row || ($0.key.row == $1.key.row && $0.key.column < $1.key.column) }) {
            guard coord.row < rows.count, coord.column < columns.count else { continue }
            let rawRow = rows[coord.row]
            let col = columns[coord.column]

            // PK description
            var pkPairs: [String] = []
            for pkCol in pkCols {
                if let pkIdx = columns.firstIndex(where: { $0.name == pkCol.name }) {
                    let cellVal = (pkIdx + 1 < rawRow.cells.count) ? rawRow.cells[pkIdx + 1] : .null
                    pkPairs.append("\(pkCol.name): \(cellVal.displayString)")
                }
            }
            let pkDesc = pkPairs.joined(separator: ", ")

            // Original value
            let rawColIdx = coord.column + 1
            let origVal = rawColIdx < rawRow.cells.count ? rawRow.cells[rawColIdx] : .null

            diffs.append(StagedEditDiff(
                row: coord.row,
                column: coord.column,
                columnName: col.name,
                primaryKeyDescription: pkDesc,
                originalValue: origVal,
                newValue: newVal
            ))
        }

        return diffs
    }

    public func loadTable(config: ConnectionConfig, schema: String, table: String) async {
        self.currentSchema = schema
        self.currentTable = table
        self.offset = 0
        self.stagedEdits.removeAll()
        self.statusMessage = nil
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
            self.dataVersion &+= 1
            self.isLoading = false
        } catch {
            self.errorMessage = error.userFacingMessage
            self.isLoading = false
        }
    }

    public func notifyRowsUpdated() {
        dataVersion &+= 1
    }

    public func nextPage(config: ConnectionConfig) {
        guard hasMore else { return }
        safeNavigate { [weak self] in
            guard let self = self else { return }
            self.offset += UInt64(self.limit)
            Task { await self.fetchPage(config: config) }
        }
    }

    public func previousPage(config: ConnectionConfig) {
        guard offset >= UInt64(limit) else { return }
        safeNavigate { [weak self] in
            guard let self = self else { return }
            self.offset -= UInt64(self.limit)
            Task { await self.fetchPage(config: config) }
        }
    }

    public func reloadTable(config: ConnectionConfig) {
        safeNavigate { [weak self] in
            guard let self = self else { return }
            Task { await self.fetchPage(config: config) }
        }
    }

    public func discardAndReload(config: ConnectionConfig) async {
        stagedEdits.removeAll()
        errorMessage = nil
        statusMessage = nil
        showingReviewSheet = false
        await fetchPage(config: config)
    }

    public func safeNavigate(action: @escaping () -> Void) {
        if stagedEdits.isEmpty {
            action()
        } else {
            self.pendingNavigationAction = action
            self.showingUnsavedChangesAlert = true
        }
    }

    public func confirmDiscardAndNavigate() {
        stagedEdits.removeAll()
        showingUnsavedChangesAlert = false
        let action = pendingNavigationAction
        pendingNavigationAction = nil
        action?()
    }

    public func cancelNavigation() {
        showingUnsavedChangesAlert = false
        pendingNavigationAction = nil
    }

    public func stageTextEdit(row: Int, column: Int, text: String) {
        guard isCellEditable(row: row, column: column) else { return }
        let col = columns[column]
        let parsed = parseCellValue(text: text, column: col)
        stageParsedValue(row: row, column: column, value: parsed)
    }

    public func stageNullEdit(row: Int, column: Int) {
        guard canSetNull(row: row, column: column) else { return }
        stageParsedValue(row: row, column: column, value: .null)
    }

    public func setCellValue(row: Int, column: Int, value: CellValue) {
        guard isEditable, !value.isUnsupported else { return }
        if !rows.isEmpty {
            guard isCellEditable(row: row, column: column) else { return }
            if value.isNull, !canSetNull(row: row, column: column) { return }
        }
        stageParsedValue(row: row, column: column, value: value)
    }

    private func stageParsedValue(row: Int, column: Int, value: CellValue) {
        let coord = GridCoordinate(row: row, column: column)
        if let orig = originalCellValue(row: row, column: column), orig == value {
            stagedEdits.removeValue(forKey: coord)
        } else {
            stagedEdits[coord] = value
        }
    }

    public func discardChanges() {
        stagedEdits.removeAll()
    }

    public func discardEdit(row: Int, column: Int) {
        stagedEdits.removeValue(forKey: GridCoordinate(row: row, column: column))
    }

    public func buildBatchMutationRequest() -> BatchMutationRequest? {
        guard isEditable, !stagedEdits.isEmpty else { return nil }

        let pkCols = columns.filter { $0.isPrimaryKey }
        guard !pkCols.isEmpty else { return nil }

        // Group edits by row
        var rowEdits: [Int: [(colIdx: Int, value: CellValue)]] = [:]
        for (coord, val) in stagedEdits {
            guard !val.isUnsupported else { return nil }
            rowEdits[coord.row, default: []].append((coord.column, val))
        }

        var mutations: [RowMutation] = []
        for (rowIdx, edits) in rowEdits.sorted(by: { $0.key < $1.key }) {
            guard rowIdx < rows.count else { continue }
            guard let xminStr = rowXmin(row: rowIdx) else {
                return nil
            }

            var pkNames: [String] = []
            var pkValues: [CellValue] = []
            for pkCol in pkCols {
                guard let pkIdx = columns.firstIndex(where: { $0.name == pkCol.name }),
                      let cellVal = originalCellValue(row: rowIdx, column: pkIdx),
                      !cellVal.isNull,
                      !cellVal.isUnsupported else {
                    return nil
                }
                pkNames.append(pkCol.name)
                pkValues.append(cellVal)
            }

            var updatedCols: [String] = []
            var updatedVals: [CellValue] = []
            for edit in edits.sorted(by: { $0.colIdx < $1.colIdx }) {
                guard edit.colIdx < columns.count else { continue }
                let col = columns[edit.colIdx]
                if col.isGenerated { continue }
                updatedCols.append(col.name)
                updatedVals.append(edit.value)
            }

            if !updatedCols.isEmpty {
                mutations.append(RowMutation(
                    primaryKeyColumns: pkNames,
                    primaryKeyValues: pkValues,
                    originalXmin: xminStr,
                    updatedColumns: updatedCols,
                    updatedValues: updatedVals
                ))
            }
        }

        guard !mutations.isEmpty else { return nil }

        return BatchMutationRequest(
            schemaName: currentSchema,
            tableName: currentTable,
            mutations: mutations
        )
    }

    public func applyStagedEdits(config: ConnectionConfig) async {
        guard !stagedEdits.isEmpty else { return }

        if isReadOnly {
            self.errorMessage = "Read-only guardrail is active. Mutations are disabled."
            return
        }
        if isSystemSchema {
            self.errorMessage = "System schema '\(currentSchema)' is read-only. Catalog tables cannot be edited."
            return
        }

        guard let request = buildBatchMutationRequest(), !request.mutations.isEmpty else {
            self.errorMessage = "Cannot apply edits: selected rows lack valid primary key or version identity."
            return
        }

        self.isApplying = true
        self.errorMessage = nil

        do {
            let res = try await apply_table_mutations(config: config, request: request, readOnly: isReadOnly)
            self.stagedEdits.removeAll()
            self.statusMessage = "Successfully applied \(res.rowsAffected) row modification\(res.rowsAffected == 1 ? "" : "s")."
            self.isApplying = false
            self.showingReviewSheet = false
            await fetchPage(config: config)
        } catch let error as LucidError {
            self.isApplying = false
            self.errorMessage = error.userFacingMessage
        } catch {
            self.isApplying = false
            self.errorMessage = "Failed to apply changes: \(error.userFacingMessage)"
        }
    }

    public func parseCellValue(text: String, column: ColumnMetadata) -> CellValue {
        let lowerType = column.pgTypeName.lowercased()

        // 1. Boolean
        if lowerType == "bool" || lowerType == "boolean" {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "true" || trimmed == "t" || trimmed == "1" || trimmed == "yes" {
                return .boolean(true)
            } else if trimmed == "false" || trimmed == "f" || trimmed == "0" || trimmed == "no" {
                return .boolean(false)
            }
        }

        // 2. Integers (exact integer / oid types only; avoid matching "point" or "interval")
        let intTypes: Set<String> = [
            "int2", "int4", "int8",
            "smallint", "integer", "bigint",
            "serial", "serial2", "serial4", "serial8",
            "smallserial", "bigserial", "oid"
        ]
        if intTypes.contains(lowerType) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let val = Int64(trimmed) {
                return .integer(val)
            }
        }

        // 3. Exact Numeric / Decimal
        if lowerType == "numeric" || lowerType == "decimal" {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .decimal(trimmed)
        }

        // 4. Floating point (float4, float8, real, double precision)
        if lowerType == "float4" || lowerType == "float8" || lowerType == "real" || lowerType == "double precision" {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let val = Double(trimmed) {
                return .float(val)
            }
        }

        // 5. JSON / JSONB
        if lowerType == "json" || lowerType == "jsonb" {
            return .json(text)
        }

        // 6. UUID
        if lowerType == "uuid" {
            return .uuid(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 7. Date
        if lowerType == "date" {
            return .date(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 8. Time
        if lowerType == "time" || lowerType == "timetz" || lowerType == "time without time zone" || lowerType == "time with time zone" {
            return .time(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 9. Timestamps
        if lowerType == "timestamptz" || lowerType.contains("with time zone") {
            return .timestampWithTimeZone(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if lowerType == "timestamp" || lowerType.contains("without time zone") {
            return .timestampWithoutTimeZone(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 10. Default / Text / Varchar
        return .text(text)
    }
}
