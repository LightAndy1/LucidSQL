import AppKit
import SwiftUI
import LucidSQLBridge

public struct DataTableView: NSViewRepresentable {
    public let viewModel: TableDataViewModel

    public init(viewModel: TableDataViewModel) {
        self.viewModel = viewModel
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

        tableView.onBeginEditCell = { [weak coordinator = context.coordinator, weak tableView] row, col in
            guard let coord = coordinator, let tv = tableView else { return }
            coord.beginEditingCell(tableView: tv, row: row, tableColumnIndex: col)
        }

        tableView.onSetNullForCell = { [weak coordinator = context.coordinator, weak tableView] row, col in
            guard let coord = coordinator, let tv = tableView else { return }
            let colIndex = col - 1
            guard row >= 0, colIndex >= 0, coord.viewModel.canSetNull(row: row, column: colIndex) else { return }
            coord.viewModel.stageNullEdit(row: row, column: colIndex)
            tv.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: col))
        }

        tableView.onDiscardCellEdit = { [weak coordinator = context.coordinator, weak tableView] row, col in
            guard let coord = coordinator, let tv = tableView else { return }
            let colIndex = col - 1
            guard row >= 0, colIndex >= 0 else { return }
            coord.viewModel.discardEdit(row: row, column: colIndex)
            tv.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: col))
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

        tableView.hasDirtyEditAtCell = { [weak coordinator = context.coordinator] row, col in
            guard let coord = coordinator else { return false }
            let colIndex = col - 1
            return coord.viewModel.stagedEdits[TableDataViewModel.GridCoordinate(row: row, column: colIndex)] != nil
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

        if context.coordinator.isEditingCell {
            return
        }

        let columnsChanged = context.coordinator.syncColumns(tableView: tableView, columns: viewModel.columns)
        let dataChanged = context.coordinator.hasStateChanged(viewModel: viewModel)

        if columnsChanged || dataChanged {
            let prevRow = tableView.activeRow
            let prevCol = tableView.activeColumn

            tableView.reloadData()

            if prevRow >= 0 && prevRow < viewModel.rows.count && prevCol >= 1 && prevCol < tableView.numberOfColumns {
                tableView.activeRow = prevRow
                tableView.activeColumn = prevCol
                if tableView.selectedRow != prevRow {
                    tableView.selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
                }
            } else {
                tableView.activeRow = -1
                tableView.activeColumn = -1
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var viewModel: TableDataViewModel
        var isEditingCell: Bool = false
        private var lastColumnHash: Int = 0
        private var lastTableIdentity: String = ""
        private var lastRowCount: Int = -1
        private var lastDataVersion: UInt64 = 0
        private var lastOffset: UInt64 = 0
        private var lastDurationMs: UInt64 = 0
        private var lastStagedEdits: [TableDataViewModel.GridCoordinate: CellValue] = [:]
        private var lastIsEditable: Bool = false

        init(viewModel: TableDataViewModel) {
            self.viewModel = viewModel
        }

        func hasStateChanged(viewModel: TableDataViewModel) -> Bool {
            let tableIdentity = "\(viewModel.currentSchema).\(viewModel.currentTable)"
            let changed = tableIdentity != lastTableIdentity
                || viewModel.rows.count != lastRowCount
                || viewModel.dataVersion != lastDataVersion
                || viewModel.offset != lastOffset
                || viewModel.executionDurationMs != lastDurationMs
                || viewModel.stagedEdits != lastStagedEdits
                || viewModel.isEditable != lastIsEditable

            if changed {
                lastTableIdentity = tableIdentity
                lastRowCount = viewModel.rows.count
                lastDataVersion = viewModel.dataVersion
                lastOffset = viewModel.offset
                lastDurationMs = viewModel.executionDurationMs
                lastStagedEdits = viewModel.stagedEdits
                lastIsEditable = viewModel.isEditable
            }
            return changed
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            viewModel.rows.count
        }

        @discardableResult
        public func syncColumns(tableView: NSTableView, columns: [ColumnMetadata]) -> Bool {
            let currentHash = columns.map { "\($0.name)_\($0.pgTypeName)_\($0.isPrimaryKey)_\($0.isGenerated)" }.joined().hashValue
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
            indexCol.width = 44
            indexCol.minWidth = 36
            indexCol.maxWidth = 60
            indexCol.headerCell.alignment = .center
            tableView.addTableColumn(indexCol)

            // 2. Data Columns
            for (idx, col) in columns.enumerated() {
                let colId = NSUserInterfaceItemIdentifier("col_\(idx)")
                let tableCol = NSTableColumn(identifier: colId)
                let pkPrefix = col.isPrimaryKey ? "🔑 " : (col.isGenerated ? "⚡ " : "")
                tableCol.title = "\(pkPrefix)\(col.name)"
                tableCol.width = max(110, CGFloat(col.name.count * 10 + 40))
                tableCol.minWidth = 60
                tableView.addTableColumn(tableCol)
            }
            return true
        }

        public func beginEditingCell(tableView: LucidDataTableView, row: Int, tableColumnIndex: Int) {
            let colIndex = tableColumnIndex - 1
            guard row >= 0, row < viewModel.rows.count, colIndex >= 0, colIndex < viewModel.columns.count else {
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

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, row < viewModel.rows.count else { return nil }

            if column.identifier.rawValue == "col_index" {
                let indexId = NSUserInterfaceItemIdentifier("IndexCell")
                var cellView = tableView.makeView(withIdentifier: indexId, owner: self) as? NSTableCellView
                if cellView == nil {
                    let view = NSTableCellView()
                    view.identifier = indexId
                    let label = NSTextField(labelWithString: "")
                    label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                    label.textColor = NSColor.secondaryLabelColor
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
                cellView?.textField?.stringValue = "\(viewModel.offset + UInt64(row) + 1)"
                return cellView
            }

            guard let colIndexStr = column.identifier.rawValue.split(separator: "_").last,
                  let colIndex = Int(colIndexStr),
                  colIndex < viewModel.columns.count else {
                return nil
            }

            let rowData = viewModel.rows[row]

            // If the query returned hidden xmin as column 0, data columns start at 1 if has_pk
            let hasPk = viewModel.hasPrimaryKey
            let rawCellIndex = hasPk ? (colIndex + 1) : colIndex

            let value: CellValue
            if rawCellIndex < rowData.cells.count {
                value = rowData.cells[rawCellIndex]
            } else if colIndex < rowData.cells.count {
                value = rowData.cells[colIndex]
            } else {
                value = .null
            }

            let coord = TableDataViewModel.GridCoordinate(row: row, column: colIndex)
            let displayValue = viewModel.stagedEdits[coord] ?? value
            let isDirty = viewModel.stagedEdits[coord] != nil
            let isCellEditable = viewModel.isCellEditable(row: row, column: colIndex)
            let canSetNull = viewModel.canSetNull(row: row, column: colIndex)

            let lucidTable = tableView as? LucidDataTableView
            let tableColIndex = colIndex + 1
            let isSelectedCell = (lucidTable?.activeRow == row && lucidTable?.activeColumn == tableColIndex)

            let cellView = (tableView.makeView(withIdentifier: DataTableCellView.identifier, owner: self) as? DataTableCellView) ?? DataTableCellView()
            cellView.identifier = DataTableCellView.identifier
            cellView.configure(
                value: displayValue,
                isDirty: isDirty,
                isEditable: isCellEditable,
                canSetNull: canSetNull,
                isSelectedCell: isSelectedCell
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
                self.lastStagedEdits = self.viewModel.stagedEdits
                tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: tableColIndex))
            }

            cellView.onSetNull = { [weak self, weak tableView] in
                guard let self = self else { return }
                self.viewModel.stageNullEdit(row: row, column: colIndex)
                self.lastStagedEdits = self.viewModel.stagedEdits
                tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: tableColIndex))
            }

            cellView.onTabAdvance = { [weak self, weak tableView] direction in
                guard let self = self, let tv = tableView as? LucidDataTableView else { return }
                tv.moveActiveCell(rowDelta: 0, colDelta: direction, wrapRows: true)
                let nextRow = tv.activeRow
                let nextCol = tv.activeColumn
                DispatchQueue.main.async {
                    self.beginEditingCell(tableView: tv, row: nextRow, tableColumnIndex: nextCol)
                }
            }

            return cellView
        }
    }
}

public final class LucidDataTableView: NSTableView {
    public var onBeginEditCell: ((Int, Int) -> Void)?
    public var onSetNullForCell: ((Int, Int) -> Void)?
    public var onDiscardCellEdit: ((Int, Int) -> Void)?
    public var canEditCell: ((Int, Int) -> Bool)?
    public var canSetNullAtCell: ((Int, Int) -> Bool)?
    public var hasDirtyEditAtCell: ((Int, Int) -> Bool)?

    public var activeRow: Int = -1
    public var activeColumn: Int = -1

    public override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let tf = responder as? NSTextField {
            return tf.isEditable
        }
        return super.validateProposedFirstResponder(responder, for: event)
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
        guard clickedRow >= 0, clickedCol >= 1 else { return nil }

        let prevRow = activeRow
        let prevCol = activeColumn
        activeRow = clickedRow
        activeColumn = clickedCol
        if selectedRow != clickedRow {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        reloadCellSelection(prevRow: prevRow, prevCol: prevCol)

        let editable = canEditCell?(clickedRow, clickedCol) ?? false
        let allowNull = canSetNullAtCell?(clickedRow, clickedCol) ?? false
        let isDirty = hasDirtyEditAtCell?(clickedRow, clickedCol) ?? false
        guard editable || isDirty else { return nil }

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
        }
        if isDirty {
            let discardItem = NSMenuItem(title: "Discard Cell Edit", action: #selector(contextDiscardCell(_:)), keyEquivalent: "")
            discardItem.target = self
            menu.addItem(discardItem)
        }
        return menu
    }

    @objc private func contextEditCell(_ sender: Any?) {
        guard activeRow >= 0, activeColumn >= 1 else { return }
        onBeginEditCell?(activeRow, activeColumn)
    }

    @objc private func contextSetNull(_ sender: Any?) {
        guard activeRow >= 0, activeColumn >= 1 else { return }
        onSetNullForCell?(activeRow, activeColumn)
    }

    @objc private func contextDiscardCell(_ sender: Any?) {
        guard activeRow >= 0, activeColumn >= 1 else { return }
        onDiscardCellEdit?(activeRow, activeColumn)
    }
}
