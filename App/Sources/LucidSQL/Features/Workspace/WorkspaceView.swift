import SwiftUI
import LucidSQLBridge

@MainActor
public final class WorkspaceModel: ObservableObject {
    public enum WorkspaceMode: String, CaseIterable, Identifiable {
        case sqlEditor = "SQL Editor"
        case tableData = "Table Data"
        public var id: String { rawValue }
    }

    @Published public var activeProfile: ConnectionProfile? = nil
    @Published public var activeConfig: ConnectionConfig? = nil
    @Published public var isShowingConnectionSheet: Bool = false
    @Published public var selectedTable: String = ""
    @Published public var currentMode: WorkspaceMode = .sqlEditor
    public var tableViewModel = TableDataViewModel()
    public var sqlEditorViewModel = SqlEditorViewModel()

    public init() {}

    public func connect(profile: ConnectionProfile, password: String?) {
        self.activeProfile = profile
        self.activeConfig = profile.toRustConfig(password: password)
        self.currentMode = .sqlEditor
    }

    public func loadTable(schema: String, table: String) async {
        guard let config = activeConfig else { return }
        self.selectedTable = "\(schema).\(table)"
        self.currentMode = .tableData
        await tableViewModel.loadTable(config: config, schema: schema, table: table)
    }

    public func disconnect() {
        self.sqlEditorViewModel.reset()
        self.activeProfile = nil
        self.activeConfig = nil
        self.selectedTable = ""
        self.currentMode = .sqlEditor
        self.tableViewModel = TableDataViewModel()
    }
}

public struct WorkspaceView: View {
    @StateObject private var model = WorkspaceModel()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    public var body: some View {
        NavigationSplitView {
            // Grounded Sidebar Column
            Group {
                if let config = model.activeConfig {
                    SchemaTreeView(config: config, onOpenSqlEditor: {
                        model.currentMode = .sqlEditor
                    }) { schema, table in
                        Task {
                            await model.loadTable(schema: schema, table: table)
                        }
                    }
                } else {
                    // Quiet Disconnected Sidebar
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SCHEMAS & TABLES")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)

                        Text("Connect to a PostgreSQL database to inspect schemas, tables, and views.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .padding(.horizontal, 16)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow))
        } detail: {
            // Translucent Main Workspace Pane
            Group {
                if let config = model.activeConfig {
                    switch model.currentMode {
                    case .sqlEditor:
                        SqlEditorContainerView(viewModel: model.sqlEditorViewModel, config: config)
                    case .tableData:
                        if !model.selectedTable.isEmpty {
                            TableDataContainerView(viewModel: model.tableViewModel, config: config)
                        } else {
                            VStack(spacing: 16) {
                                Spacer()
                                Image(systemName: "tablecells")
                                    .font(.system(size: 48))
                                    .foregroundStyle(Color.accentColor)
                                Text("Select a table or view from the sidebar to inspect records")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                SecondaryActionButton(
                                    title: "Open SQL Editor",
                                    icon: "terminal",
                                    size: .regular
                                ) {
                                    model.currentMode = .sqlEditor
                                }
                                Spacer()
                            }
                        }
                    }
                } else {
                    // Clean Translucent Welcome Pane
                    VStack(spacing: 28) {
                        Spacer()

                        Image(systemName: "cylinder.split.1x2.fill")
                            .font(.system(size: 58))
                            .foregroundStyle(Color.accentColor)

                        VStack(spacing: 8) {
                            Text("LucidSQL")
                                .font(.system(size: 34, weight: .bold))

                            Text(model.activeConfig == nil
                                 ? "Fast, safe native PostgreSQL client for macOS"
                                 : "Select a table or view from the sidebar to inspect records")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }

                        if model.activeConfig == nil {
                            VStack(spacing: 14) {
                                PrimaryActionButton(
                                    title: "New Connection",
                                    icon: "plus",
                                    size: .extraLarge
                                ) {
                                    model.isShowingConnectionSheet = true
                                }
                                .keyboardShortcut("n", modifiers: [.command])

                                KeyboardBadge(keys: ["⌘", "N"], label: "New Connection")
                            }
                            .padding(.top, 4)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                WorkspaceDetailBackground(reduceTransparency: reduceTransparency)
                    .ignoresSafeArea()
            }
        }
        .toolbar {
            if model.activeConfig != nil {
                ToolbarItem(placement: .automatic) {
                    Picker("View", selection: $model.currentMode) {
                        Label("SQL Editor", systemImage: "terminal").tag(WorkspaceModel.WorkspaceMode.sqlEditor)
                        Label("Table Data", systemImage: "tablecells").tag(WorkspaceModel.WorkspaceMode.tableData)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    .help("Switch view (⌘T for SQL Editor)")
                }
            }

            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.activeConfig != nil ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)

                    if let profile = model.activeProfile {
                        Text(profile.name)
                            .font(.system(size: 11, weight: .medium))
                        Text("(\(profile.host):\(profile.port))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not Connected")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 0.5)
                )
            }

            ToolbarItem(placement: .primaryAction) {
                if model.activeConfig != nil {
                    SecondaryActionButton(
                        title: "Disconnect",
                        icon: "eject.fill",
                        size: .regular
                    ) {
                        model.disconnect()
                    }
                    .help("Disconnect from Database")
                } else {
                    PrimaryActionButton(
                        title: "Connect",
                        icon: "cable.connector",
                        size: .regular
                    ) {
                        model.isShowingConnectionSheet = true
                    }
                    .help("Connect to PostgreSQL (⌘N)")
                }
            }
        }
        .sheet(isPresented: $model.isShowingConnectionSheet) {
            ConnectionDialogView(
                profile: model.activeProfile ?? ConnectionProfile()
            ) { profile, password in
                model.connect(profile: profile, password: password)
            }
        }
    }
}

private struct WorkspaceDetailBackground: View {
    let reduceTransparency: Bool

    var body: some View {
        if reduceTransparency {
            Color(NSColor.controlBackgroundColor)
        } else if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: Rectangle())
        } else {
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
        }
    }
}
