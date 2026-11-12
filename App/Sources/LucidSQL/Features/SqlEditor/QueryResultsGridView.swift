import AppKit
import SwiftUI
import LucidSQLBridge

public struct QueryResultsGridView: NSViewRepresentable {
    public let result: QueryResult

    public init(result: QueryResult) {
        self.result = result
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tableView = NSTableView()

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 24

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.configureColumns(tableView: tableView, result: result)
        tableView.reloadData()

        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NSTableView else { return }
        context.coordinator.result = result
        context.coordinator.configureColumns(tableView: tableView, result: result)
        tableView.reloadData()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(result: result)
    }

    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var result: QueryResult
        private var lastColumnsSignature: String = ""

        init(result: QueryResult) {
            self.result = result
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            result.rows.count
        }

        public func configureColumns(tableView: NSTableView, result: QueryResult) {
            let signature = result.columns.map { "\($0.name):\($0.pgTypeName)" }.joined(separator: ",")
            if signature == lastColumnsSignature && tableView.tableColumns.count == result.columns.count + 1 {
                return
            }
            self.lastColumnsSignature = signature

            // Clear old columns
            while !tableView.tableColumns.isEmpty {
                tableView.removeTableColumn(tableView.tableColumns[0])
            }

            // Index column (#)
            let indexCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_index"))
            indexCol.title = "#"
            indexCol.width = 44
            indexCol.minWidth = 36
            indexCol.maxWidth = 70
            indexCol.headerCell.alignment = .right
            tableView.addTableColumn(indexCol)

            // Data columns
            for (idx, col) in result.columns.enumerated() {
                let tableCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(idx)"))
                tableCol.title = "\(col.name)  (\(col.pgTypeName))"
                tableCol.width = max(110, CGFloat(col.name.count * 10 + 40))
                tableCol.minWidth = 70
                tableCol.maxWidth = 600
                tableView.addTableColumn(tableCol)
            }
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn = tableColumn else { return nil }
            let identifier = tableColumn.identifier.rawValue

            if identifier == "col_index" {
                let cellId = NSUserInterfaceItemIdentifier("IndexCell")
                var cell = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView
                if cell == nil {
                    cell = NSTableCellView()
                    cell?.identifier = cellId
                    let tf = NSTextField(labelWithString: "")
                    tf.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                    tf.textColor = NSColor.tertiaryLabelColor
                    tf.alignment = .right
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    cell?.addSubview(tf)
                    cell?.textField = tf
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                        tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -6),
                        tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
                    ])
                }
                cell?.textField?.stringValue = "\(row + 1)"
                return cell
            }

            guard identifier.hasPrefix("col_"),
                  let colIndex = Int(identifier.dropFirst(4)),
                  colIndex < result.columns.count,
                  row < result.rows.count else {
                return nil
            }

            let cellValue = result.rows[row].cells.indices.contains(colIndex)
                ? result.rows[row].cells[colIndex]
                : CellValue.null

            let cellId = NSUserInterfaceItemIdentifier("ResultCell")
            var cell = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView
            if cell == nil {
                cell = NSTableCellView()
                cell?.identifier = cellId
                let tf = NSTextField()
                tf.isEditable = false
                tf.isSelectable = true
                tf.isBordered = false
                tf.drawsBackground = false
                tf.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                tf.translatesAutoresizingMaskIntoConstraints = false
                cell?.addSubview(tf)
                cell?.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
                ])
            }

            let displayStr = cellValue.displayString
            cell?.textField?.stringValue = displayStr
            cell?.toolTip = displayStr

            switch cellValue {
            case .null:
                cell?.textField?.textColor = NSColor.tertiaryLabelColor
                cell?.textField?.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            case .boolean:
                cell?.textField?.textColor = NSColor.systemPurple
                cell?.textField?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            case .integer, .float, .decimal:
                cell?.textField?.textColor = NSColor.systemBlue
                cell?.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            default:
                cell?.textField?.textColor = NSColor.labelColor
                cell?.textField?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            }

            return cell
        }
    }
}
