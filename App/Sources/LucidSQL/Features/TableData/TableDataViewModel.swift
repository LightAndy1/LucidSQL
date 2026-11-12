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

    public var isEditable: Bool {
        hasPrimaryKey && !isReadOnly
    }

    public var nonEditableReason: String? {
        if isReadOnly {
            return "Read-only guardrail is active. Editing is disabled."
        }
        if !hasPrimaryKey && !columns.isEmpty {
            return "Table has no primary key. In-grid editing requires a primary key for safe row identity."
        }
        return nil
    }

    public var stagedRowsCount: Int {
        Set(stagedEdits.keys.map(\.row)).count
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
            self.isLoading = false
        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
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
        guard isEditable, column < columns.count else { return }
        let col = columns[column]
        guard !col.isGenerated else { return }

        let parsed = parseCellValue(text: text, column: col)
        stagedEdits[GridCoordinate(row: row, column: column)] = parsed
    }

    public func stageNullEdit(row: Int, column: Int) {
        guard isEditable, column < columns.count else { return }
        let col = columns[column]
        guard !col.isGenerated else { return }

        stagedEdits[GridCoordinate(row: row, column: column)] = .null
    }

    public func setCellValue(row: Int, column: Int, value: CellValue) {
        guard isEditable else { return }
        stagedEdits[GridCoordinate(row: row, column: column)] = value
    }

    public func discardChanges() {
        stagedEdits.removeAll()
    }

    public func discardEdit(row: Int, column: Int) {
        stagedEdits.removeValue(forKey: GridCoordinate(row: row, column: column))
    }

    public func buildBatchMutationRequest() -> BatchMutationRequest? {
        guard hasPrimaryKey, !stagedEdits.isEmpty else { return nil }

        let pkCols = columns.filter { $0.isPrimaryKey }
        guard !pkCols.isEmpty else { return nil }

        // Group edits by row
        var rowEdits: [Int: [(colIdx: Int, value: CellValue)]] = [:]
        for (coord, val) in stagedEdits {
            rowEdits[coord.row, default: []].append((coord.column, val))
        }

        var mutations: [RowMutation] = []
        for (rowIdx, edits) in rowEdits {
            guard rowIdx < rows.count else { continue }
            let rawRow = rows[rowIdx]

            // xmin is at cells[0] because has_pk is true
            let xminStr = rawRow.cells.first?.displayString ?? ""

            var pkNames: [String] = []
            var pkValues: [CellValue] = []
            for pkCol in pkCols {
                if let pkIdx = columns.firstIndex(where: { $0.name == pkCol.name }) {
                    pkNames.append(pkCol.name)
                    let cellVal = (pkIdx + 1 < rawRow.cells.count) ? rawRow.cells[pkIdx + 1] : .null
                    pkValues.append(cellVal)
                }
            }

            var updatedCols: [String] = []
            var updatedVals: [CellValue] = []
            for edit in edits {
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

        return BatchMutationRequest(
            schemaName: currentSchema,
            tableName: currentTable,
            mutations: mutations
        )
    }

    public func applyStagedEdits(config: ConnectionConfig) async {
        guard let request = buildBatchMutationRequest(), !request.mutations.isEmpty else {
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
        } catch let LucidError.ConflictDetected(tableName, pkVals) {
            self.isApplying = false
            self.errorMessage = "Conflict detected in table \(tableName): row with key (\(pkVals.joined(separator: ", "))) was modified or deleted by another transaction. All changes were rolled back to prevent overwriting."
        } catch let LucidError.ReadOnlyViolation(op) {
            self.isApplying = false
            self.errorMessage = "Read-only guardrail violation: \(op)"
        } catch {
            self.isApplying = false
            self.errorMessage = "Failed to apply changes: \(error.localizedDescription)"
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

        // 2. Integers (int2, int4, int8, smallint, integer, bigint, serial)
        if lowerType.contains("int") || lowerType == "serial" || lowerType == "bigserial" {
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
        if lowerType.contains("float") || lowerType == "real" || lowerType.contains("double") {
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
        if lowerType.contains("time") && !lowerType.contains("timestamp") {
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
