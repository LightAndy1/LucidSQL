import AppKit
import SwiftUI
import LucidSQLBridge

@MainActor
public final class SchemaTreeModel: ObservableObject {
    @Published public var schemas: [String] = []
    @Published public var tablesBySchema: [String: [TableInfo]] = [:]
    @Published public var loadingSchemas: Set<String> = []
    @Published public var schemaErrors: [String: String] = [:]
    @Published public var expandedSchemas: Set<String> = ["public"]
    @Published public var selectedTableKey: String? = nil
    @Published public var selectedNodeKey: String? = nil
    @Published public var searchText: String = ""
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? = nil

    public let config: ConnectionConfig

    public init(config: ConnectionConfig) {
        self.config = config
    }

    public func loadSchemas() async {
        isLoading = true
        errorMessage = nil
        do {
            let list = try await introspect_schemas(config: config)
            self.schemas = list
            if !list.contains("public"), let first = list.first, expandedSchemas == ["public"] {
                expandedSchemas = [first]
            }
            let toLoad = list.filter { expandedSchemas.contains($0) }
            for schema in toLoad {
                await loadTables(for: schema)
            }
            self.isLoading = false
        } catch {
            self.errorMessage = error.userFacingMessage
            self.isLoading = false
        }
    }

    public func loadTables(for schema: String) async {
        loadingSchemas.insert(schema)
        schemaErrors.removeValue(forKey: schema)
        do {
            let tables = try await introspect_tables(config: config, schema: schema)
            self.tablesBySchema[schema] = tables
            self.loadingSchemas.remove(schema)
        } catch {
            self.schemaErrors[schema] = error.userFacingMessage
            self.loadingSchemas.remove(schema)
        }
    }

    public func loadTablesIfNeeded(for schema: String) {
        guard tablesBySchema[schema] == nil, !loadingSchemas.contains(schema) else { return }
        Task { await loadTables(for: schema) }
    }

    public func toggleSchemaExpanded(_ schema: String, isExpanded: Bool) {
        if isExpanded {
            expandedSchemas.insert(schema)
            loadTablesIfNeeded(for: schema)
        } else {
            expandedSchemas.remove(schema)
        }
    }

    public func filteredTables(for schema: String) -> [TableInfo] {
        guard let list = tablesBySchema[schema] else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return list }
        return list.filter { $0.tableName.lowercased().contains(query) }
    }
}

public struct SchemaTreeView: View {
    @StateObject private var model: SchemaTreeModel
    private let tableViewModel: TableDataViewModel?
    private let activeTableKey: String?
    private let onOpenSqlEditor: (() -> Void)?
    private let onSelectTable: (String, String) -> Void

    public init(
        config: ConnectionConfig,
        activeTableKey: String? = nil,
        tableViewModel: TableDataViewModel? = nil,
        onOpenSqlEditor: (() -> Void)? = nil,
        onSelectTable: @escaping (String, String) -> Void
    ) {
        _model = StateObject(wrappedValue: SchemaTreeModel(config: config))
        self.activeTableKey = activeTableKey
        self.tableViewModel = tableViewModel
        self.onOpenSqlEditor = onOpenSqlEditor
        self.onSelectTable = onSelectTable
    }

    private var loadingTableKey: String? {
        guard let tableViewModel,
              tableViewModel.isLoading,
              !tableViewModel.currentTable.isEmpty else {
            return nil
        }
        return "\(tableViewModel.currentSchema).\(tableViewModel.currentTable)"
    }

    private var displayedTableKey: String? {
        guard let activeTableKey, !activeTableKey.isEmpty else { return nil }
        return activeTableKey
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sidebar Header
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 24, height: 24)
                        Image(systemName: "cylinder.split.1x2")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.config.database)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("\(model.config.host):\(model.config.port)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let onOpen = onOpenSqlEditor {
                        Button {
                            onOpen()
                        } label: {
                            Image(systemName: "terminal")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("SQL Editor (⌘1)")
                    }

                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await model.loadSchemas() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Refresh Schemas")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)

                // Search Filter Pill
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    TextField("Filter tables...", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                    if !model.searchText.isEmpty {
                        Button {
                            model.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 0.5)
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            Divider()

            if let error = model.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Retry") {
                        Task { await model.loadSchemas() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
                Divider()
            }

            SidebarOutlineView(
                model: model,
                displayedTableKey: displayedTableKey,
                loadingTableKey: loadingTableKey,
                onActivateTable: onSelectTable
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await model.loadSchemas()
        }
        .onChange(of: activeTableKey) { _, newValue in
            let normalized = (newValue?.isEmpty == false) ? newValue : nil
            model.selectedTableKey = normalized
            if let normalized {
                let targetNodeKey = "table:\(normalized)"
                if model.selectedNodeKey == nil {
                    model.selectedNodeKey = targetNodeKey
                }
            }
        }
    }
}

// MARK: - Native NSOutlineView Sidebar Tree

private enum SidebarNodeKind {
    case schema(String)
    case table(schema: String, info: TableInfo)
    case status(schema: String, message: String, isLoading: Bool, isError: Bool)
}

private final class SidebarNode: NSObject {
    let key: String
    var kind: SidebarNodeKind
    var children: [SidebarNode] = []

    init(key: String, kind: SidebarNodeKind) {
        self.key = key
        self.kind = kind
    }
}

private struct SidebarStructureSignature: Equatable {
    let schemas: [String]
    let tableNamesBySchema: [String: [String]]
    let loadingSchemas: Set<String>
    let schemaErrors: [String: String]
    let searchText: String
}

private struct SidebarOutlineView: NSViewRepresentable {
    @ObservedObject var model: SchemaTreeModel
    let displayedTableKey: String?
    let loadingTableKey: String?
    let onActivateTable: (String, String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let outline = LucidSidebarOutlineView()
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.indentationPerLevel = 12
        outline.rowHeight = 24
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.focusRingType = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.onPrimaryClickNode = { [weak coordinator = context.coordinator] node in
            coordinator?.handlePrimaryClick(node)
        }
        outline.onReturnNode = { [weak coordinator = context.coordinator] node in
            coordinator?.handleReturn(node)
        }

        scrollView.documentView = outline
        context.coordinator.outlineView = outline
        context.coordinator.sync(from: self)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(from: self)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: SidebarOutlineView
        weak var outlineView: LucidSidebarOutlineView?

        private var rootNodes: [SidebarNode] = []
        private var nodesByKey: [String: SidebarNode] = [:]
        private var lastSignature: SidebarStructureSignature?
        private var lastExpandedSchemas: Set<String> = []
        private var lastDisplayedTableKey: String?
        private var lastLoadingTableKey: String?
        private var lastSelectedNodeKey: String?
        private var isSyncingFromSwiftUI = false

        init(_ parent: SidebarOutlineView) {
            self.parent = parent
        }

        func sync(from view: SidebarOutlineView) {
            guard let outline = outlineView else { return }
            let model = view.model

            let signature = SidebarStructureSignature(
                schemas: model.schemas,
                tableNamesBySchema: model.schemas.reduce(into: [:]) { acc, schema in
                    acc[schema] = model.filteredTables(for: schema).map(\.tableName)
                },
                loadingSchemas: model.loadingSchemas,
                schemaErrors: model.schemaErrors,
                searchText: model.searchText
            )

            let structureChanged = signature != lastSignature
            let expansionChanged = model.expandedSchemas != lastExpandedSchemas
            let visualChanged = view.displayedTableKey != lastDisplayedTableKey
                || view.loadingTableKey != lastLoadingTableKey
            let selectionChanged = model.selectedNodeKey != lastSelectedNodeKey

            isSyncingFromSwiftUI = true
            defer { isSyncingFromSwiftUI = false }

            if structureChanged {
                lastSignature = signature
                rebuildTree(model: model)
                outline.reloadData()
            }

            if structureChanged || expansionChanged {
                lastExpandedSchemas = model.expandedSchemas
                let isFiltering = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
                for node in rootNodes {
                    guard case .schema(let schema) = node.kind else { continue }
                    let shouldExpand = isFiltering || model.expandedSchemas.contains(schema)
                    if shouldExpand && !outline.isItemExpanded(node) {
                        outline.expandItem(node)
                    } else if !shouldExpand && outline.isItemExpanded(node) {
                        outline.collapseItem(node)
                    }
                }
            }

            if structureChanged || selectionChanged {
                lastSelectedNodeKey = model.selectedNodeKey
                if let key = model.selectedNodeKey, let node = nodesByKey[key] {
                    let row = outline.row(forItem: node)
                    if row >= 0 && outline.selectedRow != row {
                        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                } else if model.selectedNodeKey == nil && outline.selectedRow >= 0 {
                    outline.deselectAll(nil)
                }
            }

            if !structureChanged && visualChanged {
                let rowCount = outline.numberOfRows
                if rowCount > 0 {
                    outline.reloadData(
                        forRowIndexes: IndexSet(0..<rowCount),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            }

            lastDisplayedTableKey = view.displayedTableKey
            lastLoadingTableKey = view.loadingTableKey
        }

        private func rebuildTree(model: SchemaTreeModel) {
            var nextRoot: [SidebarNode] = []
            var nextCache: [String: SidebarNode] = [:]
            let isFiltering = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty

            for schema in model.schemas {
                let tables = model.filteredTables(for: schema)
                if isFiltering && tables.isEmpty {
                    continue
                }

                let schemaKey = "schema:\(schema)"
                let schemaNode = nodesByKey[schemaKey] ?? SidebarNode(key: schemaKey, kind: .schema(schema))
                schemaNode.kind = .schema(schema)
                nextCache[schemaKey] = schemaNode

                var children: [SidebarNode] = []
                if model.loadingSchemas.contains(schema) {
                    let statusKey = "status:\(schema):loading"
                    let statusNode = nodesByKey[statusKey] ?? SidebarNode(
                        key: statusKey,
                        kind: .status(schema: schema, message: "Loading…", isLoading: true, isError: false)
                    )
                    statusNode.kind = .status(schema: schema, message: "Loading…", isLoading: true, isError: false)
                    nextCache[statusKey] = statusNode
                    children.append(statusNode)
                } else if let schemaError = model.schemaErrors[schema] {
                    let statusKey = "status:\(schema):error"
                    let statusNode = nodesByKey[statusKey] ?? SidebarNode(
                        key: statusKey,
                        kind: .status(schema: schema, message: schemaError, isLoading: false, isError: true)
                    )
                    statusNode.kind = .status(schema: schema, message: schemaError, isLoading: false, isError: true)
                    nextCache[statusKey] = statusNode
                    children.append(statusNode)
                } else if model.tablesBySchema[schema] == nil {
                    let statusKey = "status:\(schema):pending"
                    let statusNode = nodesByKey[statusKey] ?? SidebarNode(
                        key: statusKey,
                        kind: .status(schema: schema, message: "Loading…", isLoading: true, isError: false)
                    )
                    statusNode.kind = .status(schema: schema, message: "Loading…", isLoading: true, isError: false)
                    nextCache[statusKey] = statusNode
                    children.append(statusNode)
                } else if tables.isEmpty {
                    let msg = isFiltering ? "No matches" : "No tables"
                    let statusKey = "status:\(schema):empty"
                    let statusNode = nodesByKey[statusKey] ?? SidebarNode(
                        key: statusKey,
                        kind: .status(schema: schema, message: msg, isLoading: false, isError: false)
                    )
                    statusNode.kind = .status(schema: schema, message: msg, isLoading: false, isError: false)
                    nextCache[statusKey] = statusNode
                    children.append(statusNode)
                } else {
                    for info in tables {
                        let tableKey = "table:\(schema).\(info.tableName)"
                        let tableNode = nodesByKey[tableKey] ?? SidebarNode(
                            key: tableKey,
                            kind: .table(schema: schema, info: info)
                        )
                        tableNode.kind = .table(schema: schema, info: info)
                        nextCache[tableKey] = tableNode
                        children.append(tableNode)
                    }
                }

                schemaNode.children = children
                nextRoot.append(schemaNode)
            }

            rootNodes = nextRoot
            nodesByKey = nextCache
        }

        func handlePrimaryClick(_ node: SidebarNode) {
            parent.model.selectedNodeKey = node.key
            lastSelectedNodeKey = node.key
            if case .table(let schema, let info) = node.kind {
                let tableKey = "\(schema).\(info.tableName)"
                parent.model.selectedTableKey = tableKey
                parent.onActivateTable(schema, info.tableName)
            }
        }

        func handleReturn(_ node: SidebarNode) {
            guard let outline = outlineView else { return }
            switch node.kind {
            case .table(let schema, let info):
                let tableKey = "\(schema).\(info.tableName)"
                parent.model.selectedTableKey = tableKey
                parent.onActivateTable(schema, info.tableName)
            case .schema:
                if outline.isItemExpanded(node) {
                    outline.collapseItem(node)
                } else {
                    outline.expandItem(node)
                }
            case .status:
                break
            }
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return rootNodes.count
            }
            guard let node = item as? SidebarNode else { return 0 }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return rootNodes[index]
            }
            let node = item as! SidebarNode
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            if case .schema = node.kind {
                return true
            }
            return false
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            if case .status = node.kind {
                return false
            }
            return true
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard !isSyncingFromSwiftUI,
                  let node = notification.userInfo?["NSObject"] as? SidebarNode,
                  case .schema(let schema) = node.kind else {
                return
            }
            parent.model.toggleSchemaExpanded(schema, isExpanded: true)
            lastExpandedSchemas = parent.model.expandedSchemas
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncingFromSwiftUI,
                  let node = notification.userInfo?["NSObject"] as? SidebarNode,
                  case .schema(let schema) = node.kind else {
                return
            }
            parent.model.toggleSchemaExpanded(schema, isExpanded: false)
            lastExpandedSchemas = parent.model.expandedSchemas
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingFromSwiftUI, let outline = outlineView else { return }
            let row = outline.selectedRow
            if row >= 0, let node = outline.item(atRow: row) as? SidebarNode {
                parent.model.selectedNodeKey = node.key
                lastSelectedNodeKey = node.key
            } else {
                parent.model.selectedNodeKey = nil
                lastSelectedNodeKey = nil
            }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            switch node.kind {
            case .schema(let schema):
                let identifier = NSUserInterfaceItemIdentifier("SchemaRow")
                let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarSchemaCellView)
                    ?? SidebarSchemaCellView(identifier: identifier)
                let isLoading = parent.model.loadingSchemas.contains(schema)
                let count = parent.model.tablesBySchema[schema]?.count
                cell.configure(schema: schema, count: count, isLoading: isLoading)
                return cell

            case .table(let schema, let info):
                let identifier = NSUserInterfaceItemIdentifier("TableRow")
                let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarTableCellView)
                    ?? SidebarTableCellView(identifier: identifier)
                let key = "\(schema).\(info.tableName)"
                let isDisplayed = parent.displayedTableKey == key
                let isLoading = parent.loadingTableKey == key
                cell.configure(
                    info: info,
                    isDisplayed: isDisplayed,
                    isLoading: isLoading
                )
                return cell

            case .status(let schema, let message, let isLoading, let isError):
                let identifier = NSUserInterfaceItemIdentifier("StatusRow")
                let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarStatusCellView)
                    ?? SidebarStatusCellView(identifier: identifier)
                cell.configure(message: message, isLoading: isLoading, isError: isError) { [weak self] in
                    Task { @MainActor in
                        await self?.parent.model.loadTables(for: schema)
                    }
                }
                return cell
            }
        }
    }
}

private final class LucidSidebarOutlineView: NSOutlineView {
    var onPrimaryClickNode: ((SidebarNode) -> Void)?
    var onReturnNode: ((SidebarNode) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(point), hit is NSButton {
            super.mouseDown(with: event)
            return
        }

        let clickedRow = row(at: point)
        guard clickedRow >= 0 else {
            super.mouseDown(with: event)
            return
        }

        // Disclosure triangle only toggles expand/collapse
        let disclosureFrame = frameOfOutlineCell(atRow: clickedRow)
        if !disclosureFrame.isEmpty && disclosureFrame.contains(point) {
            super.mouseDown(with: event)
            return
        }

        let clickedNode = item(atRow: clickedRow) as? SidebarNode
        if let clickedNode, case .status = clickedNode.kind {
            return
        }

        super.mouseDown(with: event)

        // Double-click must NOT dispatch a duplicate load
        guard event.clickCount == 1, let node = clickedNode else {
            return
        }

        onPrimaryClickNode?(node)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 124: // Right arrow
            if selectedRow >= 0, let node = item(atRow: selectedRow) as? SidebarNode {
                if case .schema = node.kind {
                    if !isItemExpanded(node) {
                        expandItem(node)
                    } else if numberOfChildren(ofItem: node) > 0 {
                        let firstChild = child(0, ofItem: node)
                        if let firstNode = firstChild as? SidebarNode,
                           case .status = firstNode.kind {
                            return
                        }
                        let childRow = row(forItem: firstChild)
                        if childRow >= 0 {
                            selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
                            scrollRowToVisible(childRow)
                        }
                    }
                    return
                }
            }
            return

        case 123: // Left arrow
            if selectedRow >= 0, let node = item(atRow: selectedRow) as? SidebarNode {
                if case .schema = node.kind {
                    if isItemExpanded(node) {
                        collapseItem(node)
                    }
                    return
                }
                if let parentNode = parent(forItem: node) {
                    let parentRow = row(forItem: parentNode)
                    if parentRow >= 0 {
                        selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
                        scrollRowToVisible(parentRow)
                    }
                    return
                }
            }
            return

        case 36, 76: // Return / Keypad Enter
            if selectedRow >= 0, let node = item(atRow: selectedRow) as? SidebarNode {
                onReturnNode?(node)
                return
            }

        default:
            super.keyDown(with: event)
        }
    }
}

private final class SidebarSchemaCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Schema")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        countField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countField.textColor = .tertiaryLabelColor
        countField.alignment = .right
        countField.setContentHuggingPriority(.required, for: .horizontal)
        countField.setContentCompressionResistancePriority(.required, for: .horizontal)
        countField.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)
        addSubview(countField)
        addSubview(spinner)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: countField.leadingAnchor, constant: -6),

            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateAppearance()
        }
    }

    func configure(schema: String, count: Int?, isLoading: Bool) {
        titleField.stringValue = schema
        if isLoading {
            countField.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            if let count {
                countField.stringValue = "\(count)"
                countField.isHidden = false
            } else {
                countField.isHidden = true
            }
        }
        updateAppearance()
    }

    private func updateAppearance() {
        let emphasized = backgroundStyle == .emphasized
        iconView.contentTintColor = emphasized ? .white : .secondaryLabelColor
        titleField.textColor = emphasized ? .white : .labelColor
        countField.textColor = emphasized ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
    }
}

private final class SidebarTableCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let trailingStack = NSStackView()
    private let activeDot = NSView()
    private let countField = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private var isDisplayed = false
    private var isLoading = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 12, weight: .regular)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        activeDot.wantsLayer = true
        activeDot.layer?.cornerRadius = 3
        activeDot.isHidden = true
        activeDot.translatesAutoresizingMaskIntoConstraints = false

        countField.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        countField.alignment = .right
        countField.setContentHuggingPriority(.required, for: .horizontal)
        countField.setContentCompressionResistancePriority(.required, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 5
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.addArrangedSubview(activeDot)
        trailingStack.addArrangedSubview(countField)
        trailingStack.addArrangedSubview(spinner)

        addSubview(iconView)
        addSubview(titleField)
        addSubview(trailingStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -6),

            activeDot.widthAnchor.constraint(equalToConstant: 6),
            activeDot.heightAnchor.constraint(equalToConstant: 6),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateAppearance()
        }
    }

    func configure(info: TableInfo, isDisplayed: Bool, isLoading: Bool) {
        self.isDisplayed = isDisplayed
        self.isLoading = isLoading

        let symbolName = info.isView ? "eye" : "tablecells"
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: info.isView ? "View" : "Table")
        titleField.stringValue = info.tableName
        titleField.font = .systemFont(ofSize: 12, weight: isDisplayed ? .semibold : .regular)

        activeDot.isHidden = !isDisplayed || isLoading

        if isLoading {
            countField.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            if info.estimatedRowCount > 0 {
                countField.stringValue = Self.formatNumber(info.estimatedRowCount)
                countField.isHidden = false
            } else {
                countField.isHidden = true
            }
        }

        updateAppearance()
    }

    private func updateAppearance() {
        let emphasized = backgroundStyle == .emphasized
        if emphasized {
            iconView.contentTintColor = .white
            titleField.textColor = .white
            activeDot.layer?.backgroundColor = NSColor.white.cgColor
            countField.textColor = NSColor.white.withAlphaComponent(0.75)
        } else {
            iconView.contentTintColor = isDisplayed ? .controlAccentColor : .secondaryLabelColor
            titleField.textColor = .labelColor
            activeDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            countField.textColor = .secondaryLabelColor
        }
    }

    private static func formatNumber(_ num: Int64) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000.0)
        } else if num >= 1_000 {
            return String(format: "%.1fk", Double(num) / 1_000.0)
        } else {
            return "\(num)"
        }
    }
}

private final class SidebarStatusCellView: NSTableCellView {
    private let spinner = NSProgressIndicator()
    private let messageField = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var onRetry: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        messageField.font = .systemFont(ofSize: 11)
        messageField.lineBreakMode = .byTruncatingTail
        messageField.translatesAutoresizingMaskIntoConstraints = false

        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .mini
        retryButton.target = self
        retryButton.action = #selector(handleRetry)
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(spinner)
        addSubview(messageField)
        addSubview(retryButton)

        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),

            messageField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            messageField.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageField.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -6),

            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(message: String, isLoading: Bool, isError: Bool, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        messageField.stringValue = isError ? "Failed to load" : message
        messageField.toolTip = isError ? message : nil
        messageField.textColor = isError ? .systemRed : .secondaryLabelColor
        retryButton.isHidden = !isError
        if isLoading {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    @objc private func handleRetry() {
        onRetry?()
    }
}
