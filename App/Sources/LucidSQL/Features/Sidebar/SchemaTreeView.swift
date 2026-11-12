import SwiftUI
import LucidSQLBridge

@MainActor
public final class SchemaTreeModel: ObservableObject {
    @Published public var schemas: [String] = []
    @Published public var tablesBySchema: [String: [TableInfo]] = [:]
    @Published public var expandedSchemas: Set<String> = ["public"]
    @Published public var selectedTableKey: String? = nil
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
            if list.contains("public") {
                await loadTables(for: "public")
            } else if let first = list.first {
                await loadTables(for: first)
            }
            self.isLoading = false
        } catch {
            self.errorMessage = error.userFacingMessage
            self.isLoading = false
        }
    }

    public func loadTables(for schema: String) async {
        do {
            let tables = try await introspect_tables(config: config, schema: schema)
            self.tablesBySchema[schema] = tables
        } catch {
            self.errorMessage = error.userFacingMessage
        }
    }

    public func toggleSchemaExpanded(_ schema: String, isExpanded: Bool) {
        if isExpanded {
            expandedSchemas.insert(schema)
            Task { await loadTables(for: schema) }
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
    private let activeTableKey: String?
    private let onOpenSqlEditor: (() -> Void)?
    private let onSelectTable: (String, String) -> Void

    public init(
        config: ConnectionConfig,
        activeTableKey: String? = nil,
        onOpenSqlEditor: (() -> Void)? = nil,
        onSelectTable: @escaping (String, String) -> Void
    ) {
        _model = StateObject(wrappedValue: SchemaTreeModel(config: config))
        self.activeTableKey = activeTableKey
        self.onOpenSqlEditor = onOpenSqlEditor
        self.onSelectTable = onSelectTable
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
                        Image(systemName: "cylinder.split.1x2.fill")
                            .font(.system(size: 11, weight: .semibold))
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
                        .help("Open SQL Editor (⌘T)")
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
                    Spacer()
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
            }

            List(selection: $model.selectedTableKey) {
                ForEach(model.schemas, id: \.self) { schema in
                    let tables = model.filteredTables(for: schema)
                    if model.searchText.isEmpty || !tables.isEmpty {
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { model.expandedSchemas.contains(schema) },
                                set: { isExp in model.toggleSchemaExpanded(schema, isExpanded: isExp) }
                            )
                        ) {
                            if model.tablesBySchema[schema] == nil && model.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.vertical, 4)
                            } else if tables.isEmpty {
                                Text(model.searchText.isEmpty ? "No tables" : "No matches")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 8)
                            } else {
                                ForEach(tables, id: \.tableName) { table in
                                    Button {
                                        onSelectTable(schema, table.tableName)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: table.isView ? "eye.fill" : "tablecells")
                                                .font(.system(size: 11))
                                                .foregroundStyle(table.isView ? Color.purple.opacity(0.85) : Color.blue.opacity(0.85))
                                                .frame(width: 14)

                                            Text(table.tableName)
                                                .font(.system(size: 12))
                                                .lineLimit(1)

                                            Spacer()

                                            if table.estimatedRowCount > 0 {
                                                Text(formatNumber(table.estimatedRowCount))
                                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1.5)
                                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .tag("\(schema).\(table.tableName)")
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                                Text(schema)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                if let total = model.tablesBySchema[schema]?.count {
                                    Text("\(total)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .task {
            await model.loadSchemas()
        }
        .onChange(of: activeTableKey) { _, newValue in
            model.selectedTableKey = (newValue?.isEmpty == false) ? newValue : nil
        }
    }

    private func formatNumber(_ num: Int64) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000.0)
        } else if num >= 1_000 {
            return String(format: "%.1fk", Double(num) / 1_000.0)
        } else {
            return "\(num)"
        }
    }
}
