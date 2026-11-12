import AppKit
import SwiftUI
import LucidSQLBridge

public struct DataTableView: NSViewRepresentable {
    public struct RenderSignature: Equatable {
        public let tableIdentity: String
        public let columnCount: Int
        public let rowCount: Int
        public let dataVersion: UInt64
        public let offset: UInt64
        public let durationMs: UInt64
        public let stagedEditCount: Int
        public let stagedInsertCount: Int
        public let stagedDeleteCount: Int
        public let isEditable: Bool
        public let pendingActiveCell: TableDataViewModel.GridCoordinate?

        @MainActor
        public init(from viewModel: TableDataViewModel) {
            self.tableIdentity = "\(viewModel.currentSchema).\(viewModel.currentTable)"
            self.columnCount = viewModel.columns.count
            self.rowCount = viewModel.totalGridRowCount
            self.dataVersion = viewModel.dataVersion
            self.offset = viewModel.offset
            self.durationMs = viewModel.executionDurationMs
            self.stagedEditCount = viewModel.stagedEdits.count
            self.stagedInsertCount = viewModel.stagedInserts.count
            self.stagedDeleteCount = viewModel.stagedDeletes.count
            self.isEditable = viewModel.isEditable
            self.pendingActiveCell = viewModel.pendingActiveCell
        }
    }

    public let viewModel: TableDataViewModel
    public let renderSignature: RenderSignature?

    public init(viewModel: TableDataViewModel, renderSignature: RenderSignature? = nil) {
        self.viewModel = viewModel
        self.renderSignature = renderSignature
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tableView = LucidDataTableView()

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 26

        tableView.onSelectionChanged = { [weak coordinator = context.coordinator] row in
            guard let coord = coordinator else { return }
            coord.viewModel.selectedRowIndex = (row >= 0 && row < coord.viewModel.totalGridRowCount) ? row : nil
        }

        tableView.onBeginEditCell = { [weak coordinator = context.coordinator, weak tableView] row, col in
            guard let coord = coordinator, let tv = tableView else { return }
            coord.beginEditingCell(tableView: tv, row: row, tableColumnIndex: col)
        }

        tableView.onSetNullForCell = { [weak coordinator = context.coordinator, weak tableView] row, col in
            guard let coord = coordinator, let tv = tableView else { return }
            let colIndex = col - 1
            guard row >= 0, colIndex >= 0, coord.viewModel.canSetNull(row: row, column: colIndex) else { return }
            coord.viewModel.stageNullEdit(row: row, column: colIndex)
            coord.syncSnapshot(from: coord.viewModel)
            tv.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: col))
        }

        tableView.onSetEmptyStringForCell = { [weak coordinator = context.coordinator, weak tableView] row, col in
            guard let coord = coordinator, let tv = tableView else { return }
            let colIndex = col - 1
            guard row >= 0, colIndex >= 0 else { return }
            coord.viewModel.stageEmptyStringEdit(row: row, column: colIndex)
            coord.syncSnapshot(from: coord.viewModel)
            tv.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: col))
        }

        tableView.onUseDefaultForCell = { [weak coordinator = context.coordinator, weak tableView] row, col in
            guard let coord = coordinator, let tv = tableView else { return }
            let colIndex = col - 1
            guard row >= 0, colIndex >= 0, coord.viewModel.canUseDefault(row: row, column: colIndex) else { return }
            coord.viewModel.revertDraftCellToDefault(row: row, column: colIndex)
            coord.syncSnapshot(from: coord.viewModel)
            tv.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: col))
        }

        tableView.onDiscardCellEdit = { [weak coordinator = context.coordinator, weak tableView] row, col in
            guard let coord = coordinator, let tv = tableView else { return }
            let colIndex = col - 1
            guard row >= 0, colIndex >= 0 else { return }
            coord.viewModel.discardEdit(row: row, column: colIndex)
            coord.syncSnapshot(from: coord.viewModel)
            tv.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: col))
        }

        tableView.onToggleDeleteRow = { [weak coordinator = context.coordinator, weak tableView] row in
            guard let coord = coordinator, let tv = tableView else { return }
            if coord.viewModel.isRowStagedForDeletion(row) {
                coord.viewModel.unstageDeleteRow(row: row)
            } else {
                coord.viewModel.stageDeleteRow(row: row)
            }
            coord.syncSnapshot(from: coord.viewModel)
            tv.reloadData()
        }

        tableView.canEditCell = { [weak coordinator = context.coordinator] row, col in
            guard let coord = coordinator else { return false }
            let colIndex = col - 1
            return coord.viewModel.isCellEditable(row: row, column: colIndex)
        }

        tableView.canSetNullAtCell = { [weak coordinator = context.coordinator] row, col in
            guard let coord = coordinator else { return false }
            let colIndex = col - 1
            return coord.viewModel.canSetNull(row: row, column: colIndex)
        }

        tableView.canSetEmptyStringAtCell = { [weak coordinator = context.coordinator] row, col in
            guard let coord = coordinator else { return false }
            let colIndex = col - 1
            guard colIndex >= 0, colIndex < coord.viewModel.columns.count else { return false }
            return coord.viewModel.isCellEditable(row: row, column: colIndex)
                && coord.viewModel.isColumnTextLike(coord.viewModel.columns[colIndex])
        }

        tableView.canUseDefaultAtCell = { [weak coordinator = context.coordinator] row, col in
            guard let coord = coordinator else { return false }
            let colIndex = col - 1
            return coord.viewModel.canUseDefault(row: row, column: colIndex)
        }

        tableView.hasDirtyEditAtCell = { [weak coordinator = context.coordinator] row, col in
            guard let coord = coordinator else { return false }
            let colIndex = col - 1
            return coord.viewModel.stagedEdits[TableDataViewModel.GridCoordinate(row: row, column: colIndex)] != nil
        }

        tableView.isDraftRowHandler = { [weak coordinator = context.coordinator] row in
            coordinator?.viewModel.isDraftRow(row) ?? false
        }

        tableView.canDeleteRowHandler = { [weak coordinator = context.coordinator] row in
            coordinator?.viewModel.canDeleteRow(row) ?? false
        }

        tableView.isRowStagedForDeletionHandler = { [weak coordinator = context.coordinator] row in
            coordinator?.viewModel.isRowStagedForDeletion(row) ?? false
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? LucidDataTableView else { return }
        context.coordinator.viewModel = viewModel
        context.coordinator.tableViewRef = tableView
        context.coordinator.syncTableViewIfNeeded(tableView)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var viewModel: TableDataViewModel
        weak var tableViewRef: LucidDataTableView?
        var isEditingCell: Bool = false {
            didSet {
                if !isEditingCell, let tableView = tableViewRef {
                    syncTableViewIfNeeded(tableView)
                }
            }
        }
        private var lastColumnHash: Int = 0
        private var lastTableIdentity: String = ""
        private var lastRowCount: Int = -1
        private var lastDataVersion: UInt64 = 0
        private var lastOffset: UInt64 = 0
        private var lastDurationMs: UInt64 = 0
        private var lastStagedEdits: [TableDataViewModel.GridCoordinate: CellValue] = [:]
        private var lastStagedInserts: [TableDataViewModel.StagedInsertRow] = []
        private var lastStagedDeletes: Set<Int> = []
        private var lastIsEditable: Bool = false

        init(viewModel: TableDataViewModel) {
            self.viewModel = viewModel
        }

        func syncTableViewIfNeeded(_ tableView: LucidDataTableView) {
            guard !isEditingCell else { return }

            let columnsChanged = syncColumns(tableView: tableView, columns: viewModel.columns)
            let dataChanged = hasStateChanged(viewModel: viewModel)

            guard columnsChanged || dataChanged else { return }

            let prevRow = tableView.activeRow
            let prevCol = tableView.activeColumn

            tableView.reloadData()

            if let pending = viewModel.pendingActiveCell,
               pending.row >= 0, pending.row < viewModel.totalGridRowCount,
               pending.column >= 1, pending.column < tableView.numberOfColumns {
                viewModel.pendingActiveCell = nil
                tableView.activeRow = pending.row
                tableView.activeColumn = pending.column
                tableView.selectRowIndexes(IndexSet(integer: pending.row), byExtendingSelection: false)
                tableView.scrollRowToVisible(pending.row)
                tableView.scrollColumnToVisible(pending.column)
                viewModel.selectedRowIndex = pending.row
            } else if prevRow >= 0 && prevRow < viewModel.totalGridRowCount && prevCol >= 1 && prevCol < tableView.numberOfColumns {
                tableView.activeRow = prevRow
                tableView.activeColumn = prevCol
                if tableView.selectedRow != prevRow {
                    tableView.selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
                }
                viewModel.selectedRowIndex = prevRow
            } else {
                tableView.activeRow = -1
                tableView.activeColumn = -1
                viewModel.selectedRowIndex = nil
            }
        }

        func syncSnapshot(from vm: TableDataViewModel) {
            lastStagedEdits = vm.stagedEdits
            lastStagedInserts = vm.stagedInserts
            lastStagedDeletes = vm.stagedDeletes
            lastDataVersion = vm.dataVersion
            lastRowCount = vm.totalGridRowCount
        }

        func hasStateChanged(viewModel: TableDataViewModel) -> Bool {
            let tableIdentity = "\(viewModel.currentSchema).\(viewModel.currentTable)"
            let changed = tableIdentity != lastTableIdentity
                || viewModel.totalGridRowCount != lastRowCount
                || viewModel.dataVersion != lastDataVersion
                || viewModel.offset != lastOffset
                || viewModel.executionDurationMs != lastDurationMs
                || viewModel.stagedEdits != lastStagedEdits
                || viewModel.stagedInserts != lastStagedInserts
                || viewModel.stagedDeletes != lastStagedDeletes
                || viewModel.isEditable != lastIsEditable

            if changed {
                lastTableIdentity = tableIdentity
                lastRowCount = viewModel.totalGridRowCount
                lastDataVersion = viewModel.dataVersion
                lastOffset = viewModel.offset
                lastDurationMs = viewModel.executionDurationMs
                lastStagedEdits = viewModel.stagedEdits
                lastStagedInserts = viewModel.stagedInserts
                lastStagedDeletes = viewModel.stagedDeletes
                lastIsEditable = viewModel.isEditable
            }
            return changed
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            viewModel.totalGridRowCount
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv = notification.object as? LucidDataTableView else { return }
            let row = tv.selectedRow
            viewModel.selectedRowIndex = (row >= 0 && row < viewModel.totalGridRowCount) ? row : nil
        }

        @discardableResult
        public func syncColumns(tableView: NSTableView, columns: [ColumnMetadata]) -> Bool {
            let currentHash = columns.map {
                "\($0.name)_\($0.pgTypeName)_\($0.isPrimaryKey)_\($0.isGenerated)_\($0.isIdentityAlways)"
            }.joined().hashValue
            if currentHash == lastColumnHash && tableView.tableColumns.count == columns.count + 1 {
                return false
            }
            lastColumnHash = currentHash

            while !tableView.tableColumns.isEmpty {
                tableView.removeTableColumn(tableView.tableColumns[0])
            }

            // 1. Row Index Header Column
            let indexCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_index"))
            indexCol.title = "#"
            indexCol.width = 48
            indexCol.minWidth = 40
            indexCol.maxWidth = 68
            indexCol.headerCell.alignment = .center
            tableView.addTableColumn(indexCol)

            // 2. Data Columns
            for (idx, col) in columns.enumerated() {
                let colId = NSUserInterfaceItemIdentifier("col_\(idx)")
                let tableCol = NSTableColumn(identifier: colId)
                let pkPrefix = col.isPrimaryKey ? "🔑 " : ((col.isGenerated || col.isIdentityAlways) ? "⚡ " : "")
                tableCol.title = "\(pkPrefix)\(col.name)"
                tableCol.width = max(110, CGFloat(col.name.count * 10 + 40))
                tableCol.minWidth = 60
                tableView.addTableColumn(tableCol)
            }
            return true
        }

        public func beginEditingCell(tableView: LucidDataTableView, row: Int, tableColumnIndex: Int) {
            let colIndex = tableColumnIndex - 1
            guard row >= 0, row < viewModel.totalGridRowCount, colIndex >= 0, colIndex < viewModel.columns.count else {
                return
            }
            guard viewModel.isCellEditable(row: row, column: colIndex) else {
                return
            }

            tableView.scrollRowToVisible(row)
            tableView.scrollColumnToVisible(tableColumnIndex)

            if let cellView = tableView.view(atColumn: tableColumnIndex, row: row, makeIfNecessary: true) as? DataTableCellView {
                cellView.beginEditing()
            }
        }

        public func findNextEditableCoordinate(
            fromRow: Int,
            fromTableCol: Int,
            direction: Int,
            totalRows: Int,
            totalTableCols: Int
        ) -> (row: Int, tableCol: Int)? {
            guard totalRows > 0, totalTableCols > 1 else { return nil }
            let dataColCount = totalTableCols - 1
            let maxSteps = totalRows * dataColCount
            var curRow = fromRow
            var curCol = fromTableCol

            for _ in 0..<maxSteps {
                curCol += direction
                if curCol >= totalTableCols {
                    curCol = 1
                    curRow += 1
                } else if curCol < 1 {
                    curCol = totalTableCols - 1
                    curRow -= 1
                }
                if curRow < 0 || curRow >= totalRows {
                    return nil
                }
                if viewModel.isCellEditable(row: curRow, column: curCol - 1) {
                    return (curRow, curCol)
                }
            }
            return nil
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, row < viewModel.totalGridRowCount else { return nil }

            let isDraft = viewModel.isDraftRow(row)
            let isPendingDelete = viewModel.isRowStagedForDeletion(row)

            if column.identifier.rawValue == "col_index" {
                let indexId = NSUserInterfaceItemIdentifier("IndexCell")
                var cellView = tableView.makeView(withIdentifier: indexId, owner: self) as? NSTableCellView
                if cellView == nil {
                    let view = NSTableCellView()
                    view.identifier = indexId
                    let label = NSTextField(labelWithString: "")
                    label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                    label.alignment = .center
                    label.translatesAutoresizingMaskIntoConstraints = false
                    view.addSubview(label)
                    view.textField = label
                    NSLayoutConstraint.activate([
                        label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                        label.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                        label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    ])
                    cellView = view
                }
                if isDraft {
                    let draftNum = row - viewModel.rows.count + 1
                    cellView?.textField?.stringValue = "+\(draftNum)"
                    cellView?.textField?.textColor = NSColor.systemGreen
                    cellView?.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
                } else if isPendingDelete {
                    cellView?.textField?.stringValue = "DEL"
                    cellView?.textField?.textColor = NSColor.systemRed
                    cellView?.textField?.font = NSFont.systemFont(ofSize: 10, weight: .bold)
                } else {
                    cellView?.textField?.stringValue = "\(viewModel.offset + UInt64(row) + 1)"
                    cellView?.textField?.textColor = NSColor.secondaryLabelColor
                    cellView?.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                }
                return cellView
            }

            guard let colIndexStr = column.identifier.rawValue.split(separator: "_").last,
                  let colIndex = Int(colIndexStr),
                  colIndex < viewModel.columns.count else {
                return nil
            }

            let state = viewModel.cellState(row: row, column: colIndex)
            let isCellEditable = viewModel.isCellEditable(row: row, column: colIndex)
            let canSetNull = viewModel.canSetNull(row: row, column: colIndex)
            let isTextLike = viewModel.isColumnTextLike(viewModel.columns[colIndex])

            let lucidTable = tableView as? LucidDataTableView
            let tableColIndex = colIndex + 1
            let isSelectedCell = (lucidTable?.activeRow == row && lucidTable?.activeColumn == tableColIndex)

            let cellView = (tableView.makeView(withIdentifier: DataTableCellView.identifier, owner: self) as? DataTableCellView) ?? DataTableCellView()
            cellView.identifier = DataTableCellView.identifier
            cellView.configure(
                value: state.value,
                isDefault: state.isDefault,
                isDirty: state.isDirty,
                isEditable: isCellEditable,
                canSetNull: canSetNull,
                isSelectedCell: isSelectedCell,
                isDraftRow: isDraft,
                isPendingDelete: isPendingDelete,
                isTextLikeColumn: isTextLike
            )

            cellView.onEditingStateChanged = { [weak self] editing in
                self?.isEditingCell = editing
            }

            cellView.onRestoreFocusToTable = { [weak tableView] in
                if let tv = tableView, let window = tv.window {
                    window.makeFirstResponder(tv)
                }
            }

            cellView.onCommitEdit = { [weak self, weak tableView] newText in
                guard let self = self else { return }
                self.viewModel.stageTextEdit(row: row, column: colIndex, text: newText)
                self.syncSnapshot(from: self.viewModel)
                tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: tableColIndex))
            }

            cellView.onSetNull = { [weak self, weak tableView] in
                guard let self = self else { return }
                self.viewModel.stageNullEdit(row: row, column: colIndex)
                self.syncSnapshot(from: self.viewModel)
                tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: tableColIndex))
            }

            cellView.onTabAdvance = { [weak self, weak tableView] direction in
                guard let self = self, let tv = tableView as? LucidDataTableView else { return }
                if let target = self.findNextEditableCoordinate(
                    fromRow: row,
                    fromTableCol: tableColIndex,
                    direction: direction,
                    totalRows: tv.numberOfRows,
                    totalTableCols: tv.numberOfColumns
                ) {
                    tv.selectActiveCell(row: target.row, tableColumn: target.tableCol)
                    DispatchQueue.main.async {
                        self.beginEditingCell(tableView: tv, row: target.row, tableColumnIndex: target.tableCol)
                    }
                } else {
                    tv.moveActiveCell(rowDelta: 0, colDelta: direction, wrapRows: true)
                }
            }

            return cellView
        }
    }
}

public final class LucidDataTableView: NSTableView {
    public var onSelectionChanged: ((Int) -> Void)?
    public var onBeginEditCell: ((Int, Int) -> Void)?
    public var onSetNullForCell: ((Int, Int) -> Void)?
    public var onSetEmptyStringForCell: ((Int, Int) -> Void)?
    public var onUseDefaultForCell: ((Int, Int) -> Void)?
    public var onDiscardCellEdit: ((Int, Int) -> Void)?
    public var onToggleDeleteRow: ((Int) -> Void)?

    public var canEditCell: ((Int, Int) -> Bool)?
    public var canSetNullAtCell: ((Int, Int) -> Bool)?
    public var canSetEmptyStringAtCell: ((Int, Int) -> Bool)?
    public var canUseDefaultAtCell: ((Int, Int) -> Bool)?
    public var hasDirtyEditAtCell: ((Int, Int) -> Bool)?
    public var isDraftRowHandler: ((Int) -> Bool)?
    public var canDeleteRowHandler: ((Int) -> Bool)?
    public var isRowStagedForDeletionHandler: ((Int) -> Bool)?

    public var activeRow: Int = -1
    public var activeColumn: Int = -1

    public override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let tf = responder as? NSTextField {
            return tf.isEditable
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    public func selectActiveCell(row: Int, tableColumn: Int) {
        guard row >= 0, row < numberOfRows, tableColumn >= 1, tableColumn < numberOfColumns else { return }
        let prevRow = activeRow
        let prevCol = activeColumn
        activeRow = row
        activeColumn = tableColumn
        if selectedRow != row {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        scrollRowToVisible(row)
        scrollColumnToVisible(tableColumn)
        reloadCellSelection(prevRow: prevRow, prevCol: prevCol)
        onSelectionChanged?(row)
    }

    public override func mouseDown(with event: NSEvent) {
        let prevRow = activeRow
        let prevCol = activeColumn

        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedCol = column(at: point)

        super.mouseDown(with: event)

        if clickedRow >= 0 && clickedRow < numberOfRows {
            activeRow = clickedRow
            activeColumn = clickedCol >= 1 ? clickedCol : (numberOfColumns > 1 ? 1 : -1)
        } else {
            activeRow = -1
            activeColumn = -1
        }

        onSelectionChanged?(activeRow)
        reloadCellSelection(prevRow: prevRow, prevCol: prevCol)

        if event.clickCount == 2 && activeRow >= 0 && activeColumn >= 1 {
            onBeginEditCell?(activeRow, activeColumn)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.contains([.command, .option]),
           event.charactersIgnoringModifiers?.lowercased() == "n",
           activeRow >= 0,
           activeColumn >= 1 {
            onSetNullForCell?(activeRow, activeColumn)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        // Enter / Return / Numpad Enter starts editing
        if (event.keyCode == 36 || event.keyCode == 76) && activeRow >= 0 && activeColumn >= 1 {
            onBeginEditCell?(activeRow, activeColumn)
            return
        }

        // Cmd+Option+N sets NULL
        if event.modifierFlags.contains([.command, .option]) && event.charactersIgnoringModifiers?.lowercased() == "n" {
            if activeRow >= 0 && activeColumn >= 1 {
                onSetNullForCell?(activeRow, activeColumn)
            }
            return
        }

        // Left / Right arrows move active column
        if event.keyCode == 123 {
            moveActiveCell(rowDelta: 0, colDelta: -1, wrapRows: false)
            return
        }
        if event.keyCode == 124 {
            moveActiveCell(rowDelta: 0, colDelta: 1, wrapRows: false)
            return
        }

        // Tab / Shift+Tab moves cell selection
        if event.keyCode == 48 {
            let dir = event.modifierFlags.contains(.shift) ? -1 : 1
            moveActiveCell(rowDelta: 0, colDelta: dir, wrapRows: true)
            return
        }

        // Up / Down arrows move active row deterministically
        if event.keyCode == 125 {
            moveActiveCell(rowDelta: 1, colDelta: 0, wrapRows: false)
            return
        }
        if event.keyCode == 126 {
            moveActiveCell(rowDelta: -1, colDelta: 0, wrapRows: false)
            return
        }

        super.keyDown(with: event)
    }

    public func moveActiveCell(rowDelta: Int, colDelta: Int, wrapRows: Bool) {
        guard numberOfRows > 0, numberOfColumns > 1 else { return }

        let prevRow = activeRow
        let prevCol = activeColumn

        var nextRow = activeRow >= 0 ? activeRow + rowDelta : 0
        var nextCol = activeColumn >= 1 ? activeColumn + colDelta : 1

        if wrapRows {
            if nextCol >= numberOfColumns {
                nextCol = 1
                nextRow += 1
            } else if nextCol < 1 {
                nextCol = numberOfColumns - 1
                nextRow -= 1
            }
        } else {
            nextCol = max(1, min(numberOfColumns - 1, nextCol))
        }

        nextRow = max(0, min(numberOfRows - 1, nextRow))

        activeRow = nextRow
        activeColumn = nextCol

        if selectedRow != nextRow {
            selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        }
        scrollRowToVisible(nextRow)
        scrollColumnToVisible(nextCol)
        onSelectionChanged?(nextRow)
        reloadCellSelection(prevRow: prevRow, prevCol: prevCol)
    }

    private func reloadCellSelection(prevRow: Int, prevCol: Int) {
        var rowsToReload = IndexSet()
        var colsToReload = IndexSet()

        if prevRow >= 0 && prevRow < numberOfRows && prevCol >= 1 && prevCol < numberOfColumns {
            rowsToReload.insert(prevRow)
            colsToReload.insert(prevCol)
        }
        if activeRow >= 0 && activeRow < numberOfRows && activeColumn >= 1 && activeColumn < numberOfColumns {
            rowsToReload.insert(activeRow)
            colsToReload.insert(activeColumn)
        }
        if !rowsToReload.isEmpty && !colsToReload.isEmpty {
            reloadData(forRowIndexes: rowsToReload, columnIndexes: colsToReload)
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedCol = column(at: point)
        guard clickedRow >= 0, clickedRow < numberOfRows else { return nil }

        let effectiveCol = clickedCol >= 1 ? clickedCol : (numberOfColumns > 1 ? 1 : -1)
        guard effectiveCol >= 1 else { return nil }

        let prevRow = activeRow
        let prevCol = activeColumn
        activeRow = clickedRow
        activeColumn = effectiveCol
        if selectedRow != clickedRow {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        onSelectionChanged?(clickedRow)
        reloadCellSelection(prevRow: prevRow, prevCol: prevCol)

        let editable = canEditCell?(clickedRow, effectiveCol) ?? false
        let allowNull = canSetNullAtCell?(clickedRow, effectiveCol) ?? false
        let allowEmpty = canSetEmptyStringAtCell?(clickedRow, effectiveCol) ?? false
        let allowDefault = canUseDefaultAtCell?(clickedRow, effectiveCol) ?? false
        let isDirty = hasDirtyEditAtCell?(clickedRow, effectiveCol) ?? false
        let isDraft = isDraftRowHandler?(clickedRow) ?? false
        let canDelete = canDeleteRowHandler?(clickedRow) ?? false
        let isPendingDelete = isRowStagedForDeletionHandler?(clickedRow) ?? false

        guard editable || allowDefault || isDirty || canDelete || isPendingDelete else { return nil }

        let menu = NSMenu()
        if editable {
            let editItem = NSMenuItem(title: "Edit Cell", action: #selector(contextEditCell(_:)), keyEquivalent: "")
            editItem.target = self
            menu.addItem(editItem)

            if allowNull {
                let nullItem = NSMenuItem(title: "Set to NULL (⌥⌘N)", action: #selector(contextSetNull(_:)), keyEquivalent: "")
                nullItem.target = self
                menu.addItem(nullItem)
            }

            if allowEmpty {
                let emptyItem = NSMenuItem(title: "Set to Empty String (\"\")", action: #selector(contextSetEmptyString(_:)), keyEquivalent: "")
                emptyItem.target = self
                menu.addItem(emptyItem)
            }
        }

        if allowDefault {
            let defaultItem = NSMenuItem(title: "Use DEFAULT", action: #selector(contextUseDefault(_:)), keyEquivalent: "")
            defaultItem.target = self
            menu.addItem(defaultItem)
        }

        if isDirty && !isDraft {
            let discardItem = NSMenuItem(title: "Discard Cell Edit", action: #selector(contextDiscardCell(_:)), keyEquivalent: "")
            discardItem.target = self
            menu.addItem(discardItem)
        }

        if canDelete || isPendingDelete {
            if !menu.items.isEmpty {
                menu.addItem(NSMenuItem.separator())
            }
            let title: String
            if isDraft {
                title = "Delete Draft Row"
            } else if isPendingDelete {
                title = "Undo Delete Row"
            } else {
                title = "Stage Row for Deletion"
            }
            let deleteItem = NSMenuItem(title: title, action: #selector(contextToggleDeleteRow(_:)), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func contextEditCell(_ sender: Any?) {
        guard activeRow >= 0, activeColumn >= 1 else { return }
        onBeginEditCell?(activeRow, activeColumn)
    }

    @objc private func contextSetNull(_ sender: Any?) {
        guard activeRow >= 0, activeColumn >= 1 else { return }
        onSetNullForCell?(activeRow, activeColumn)
    }

    @objc private func contextSetEmptyString(_ sender: Any?) {
        guard activeRow >= 0, activeColumn >= 1 else { return }
        onSetEmptyStringForCell?(activeRow, activeColumn)
    }

    @objc private func contextUseDefault(_ sender: Any?) {
        guard activeRow >= 0, activeColumn >= 1 else { return }
        onUseDefaultForCell?(activeRow, activeColumn)
    }

    @objc private func contextDiscardCell(_ sender: Any?) {
        guard activeRow >= 0, activeColumn >= 1 else { return }
        onDiscardCellEdit?(activeRow, activeColumn)
    }

    @objc private func contextToggleDeleteRow(_ sender: Any?) {
        guard activeRow >= 0 else { return }
        onToggleDeleteRow?(activeRow)
    }
}
