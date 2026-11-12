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

        tableView.onSetNullForSelection = { [weak coordinator = context.coordinator] in
            guard let coord = coordinator else { return }
            let row = tableView.selectedRow
            let col = tableView.selectedColumn
            if row >= 0 && col >= 1 {
                let colIndex = col - 1
                if colIndex < coord.viewModel.columns.count {
                    coord.viewModel.stageNullEdit(row: row, column: colIndex)
                    tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: col))
                }
            }
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? LucidDataTableView else { return }
        context.coordinator.syncColumns(tableView: tableView, columns: viewModel.columns)
        tableView.reloadData()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var viewModel: TableDataViewModel
        private var lastColumnHash: Int = 0

        init(viewModel: TableDataViewModel) {
            self.viewModel = viewModel
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            viewModel.rows.count
        }

        public func syncColumns(tableView: NSTableView, columns: [ColumnMetadata]) {
            let currentHash = columns.map { "\($0.name)_\($0.pgTypeName)_\($0.isPrimaryKey)_\($0.isGenerated)" }.joined().hashValue
            if currentHash == lastColumnHash && tableView.tableColumns.count == columns.count + 1 {
                return
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
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, row < viewModel.rows.count else { return nil }

            if column.identifier.rawValue == "col_index" {
                let cellView = NSTableCellView()
                let label = NSTextField(labelWithString: "\(viewModel.offset + UInt64(row) + 1)")
                label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                label.textColor = NSColor.secondaryLabelColor
                label.alignment = .center
                label.translatesAutoresizingMaskIntoConstraints = false
                cellView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: cellView.trailingAnchor),
                    label.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                ])
                return cellView
            }

            guard let colIndexStr = column.identifier.rawValue.split(separator: "_").last,
                  let colIndex = Int(colIndexStr),
                  colIndex < viewModel.columns.count else {
                return nil
            }

            let col = viewModel.columns[colIndex]
            let rowData = viewModel.rows[row]

            // If the query returned hidden xmin as column 0, data columns start at 1 if has_pk
            let hasPk = viewModel.columns.contains(where: { $0.isPrimaryKey })
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
            let isColumnEditable = viewModel.isEditable && !col.isGenerated

            let cellView = DataTableCellView()
            cellView.configure(value: displayValue, isDirty: isDirty, isEditable: isColumnEditable)

            cellView.onCommitEdit = { [weak self, weak tableView] newText in
                guard let self = self else { return }
                self.viewModel.stageTextEdit(row: row, column: colIndex, text: newText)
                tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: colIndex + 1))
            }

            cellView.onSetNull = { [weak self, weak tableView] in
                guard let self = self else { return }
                self.viewModel.stageNullEdit(row: row, column: colIndex)
                tableView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: colIndex + 1))
            }

            return cellView
        }
    }
}

public final class LucidDataTableView: NSTableView {
    public var onSetNullForSelection: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        // Enter / Return key starts editing
        if event.keyCode == 36 && selectedRow >= 0 && selectedColumn >= 1 {
            editColumn(selectedColumn, row: selectedRow, with: event, select: true)
            return
        }

        // Cmd+Option+N sets NULL
        if event.modifierFlags.contains([.command, .option]) && event.charactersIgnoringModifiers == "n" {
            onSetNullForSelection?()
            return
        }

        super.keyDown(with: event)
    }
}
