import SwiftUI
import AppKit
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
    @Published public var activeConnectionSessionToken: UUID = UUID()
    @Published public var savedProfiles: [ConnectionProfile] = []
    @Published public var selectedProfileId: UUID? = nil
    @Published public var initialDialogProfile: ConnectionProfile? = nil
    @Published public var initialDialogNotice: String? = nil
    @Published public var isShowingConnectionSheet: Bool = false
    @Published public var selectedTable: String = ""
    @Published public var currentMode: WorkspaceMode = .sqlEditor
    @Published public var showingDisconnectSessionWarning: Bool = false
    @Published public var disconnectWarningMessage: String = ""
    @Published public var showingSwitchConnectionAlert: Bool = false
    @Published public var switchConnectionWarningMessage: String = ""
    @Published public var showingWelcomeDeleteAlert: Bool = false
    @Published public var profilePendingDelete: ConnectionProfile? = nil
    @Published public var showingTableNavigationAlert: Bool = false
    @Published public var tableNavigationWarningMessage: String = ""
    @Published public var isShowingSettingsSheet: Bool = false

    public var tableViewModel = TableDataViewModel()
    public let sqlWorkspace: SqlWorkspaceViewModel
    public let profileStore: ConnectionProfileStore
    public let draftStore: SqlDraftStore
    public let passwordStore: any PasswordStoring
    public let privacyPreferences: PrivacyPreferencesStore
    public var sweepGlobalSessionsOnDisconnect: Bool = true

    private var terminateObserver: NSObjectProtocol? = nil
    private var pendingTableNavigationAction: (() -> Void)? = nil
    private var pendingConnectionSwitch: (profile: ConnectionProfile, password: String?)? = nil

    public var sqlEditorViewModel: SqlEditorViewModel {
        sqlWorkspace.activeTab ?? SqlEditorViewModel()
    }

    public init(
        profileStore: ConnectionProfileStore = ConnectionProfileStore(),
        draftStore: SqlDraftStore = SqlDraftStore(),
        passwordStore: any PasswordStoring = KeychainPasswordStore.shared,
        privacyPreferences: PrivacyPreferencesStore? = nil
    ) {
        let resolvedPrivacy = privacyPreferences ?? PrivacyPreferencesStore.shared
        self.profileStore = profileStore
        self.draftStore = draftStore
        self.passwordStore = passwordStore
        self.privacyPreferences = resolvedPrivacy
        self.sqlWorkspace = SqlWorkspaceViewModel(
            draftStore: draftStore,
            privacyPreferences: resolvedPrivacy
        )
        bindReadOnlySync()
        registerTerminateObserver()
        refreshSavedProfiles()
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    private func registerTerminateObserver() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sqlWorkspace.flushDrafts()
            }
        }
    }

    private func bindReadOnlySync() {
        sqlWorkspace.onReadOnlyChanged = { [weak self] newValue in
            self?.tableViewModel.isReadOnly = newValue
        }
    }

    public func toggleReadOnly() {
        guard let config = activeConfig else { return }
        if let activeTab = sqlWorkspace.activeTab, activeTab.transactionStatus == .inTransaction {
            tableViewModel.errorMessage = "Cannot toggle read-only mode while inside an active SQL Editor transaction in \"\(activeTab.title)\". Commit or rollback first."
            return
        }
        if let activeTab = sqlWorkspace.activeTab {
            activeTab.toggleReadOnly(config: config)
        } else {
            let newValue = !tableViewModel.isReadOnly
            tableViewModel.isReadOnly = newValue
            sqlWorkspace.defaultReadOnly = newValue
        }
    }

    public var selectedSavedProfile: ConnectionProfile? {
        if let selectedProfileId,
           let match = savedProfiles.first(where: { $0.id == selectedProfileId }) {
            return match
        }
        return savedProfiles.first
    }

    public func refreshSavedProfiles() {
        let profiles = profileStore.loadProfiles()
        self.savedProfiles = profiles
        if let currentId = selectedProfileId, profiles.contains(where: { $0.id == currentId }) {
            return
        }
        self.selectedProfileId = profileStore.lastSelectedProfileId() ?? profiles.first?.id
    }

    public func selectSavedProfile(_ id: UUID) {
        selectedProfileId = id
        try? profileStore.selectProfile(id: id)
    }

    public func openConnectionDialog(
        selecting profile: ConnectionProfile? = nil,
        startNew: Bool = false,
        notice: String? = nil
    ) {
        if startNew {
            initialDialogProfile = ConnectionProfile(name: "New PostgreSQL")
        } else if let profile {
            selectSavedProfile(profile.id)
            initialDialogProfile = profile
        } else {
            initialDialogProfile = activeProfile ?? selectedSavedProfile ?? profileStore.mostRecentProfile() ?? ConnectionProfile()
        }
        initialDialogNotice = notice
        isShowingConnectionSheet = true
    }

    public func quickConnect(profile: ConnectionProfile) {
        selectSavedProfile(profile.id)
        if !profile.rememberPassword {
            openConnectionDialog(
                selecting: profile,
                notice: "Password is not remembered for \"\(profile.name)\". Enter your password to connect (or click Connect if none is required)."
            )
            return
        }
        let storedPassword = (try? passwordStore.getPassword(profileId: profile.id)) ?? nil
        let resolvedPassword = (storedPassword?.isEmpty == false) ? storedPassword : nil
        requestConnection(profile, password: resolvedPassword)
    }

    public func duplicateSavedProfile(_ id: UUID) {
        if let copy = try? profileStore.duplicateProfile(id: id, passwordStore: passwordStore) {
            refreshSavedProfiles()
            selectedProfileId = copy.id
        }
    }

    public func requestDeleteSavedProfile(_ profile: ConnectionProfile) {
        guard activeProfile?.id != profile.id else { return }
        profilePendingDelete = profile
        showingWelcomeDeleteAlert = true
    }

    public func confirmDeleteSavedProfile() {
        guard let profile = profilePendingDelete else { return }
        profilePendingDelete = nil
        showingWelcomeDeleteAlert = false
        try? profileStore.deleteProfile(id: profile.id, draftStore: draftStore, passwordStore: passwordStore)
        selectedProfileId = nil
        refreshSavedProfiles()
    }

    public func cancelDeleteSavedProfile() {
        profilePendingDelete = nil
        showingWelcomeDeleteAlert = false
    }

    public func requestConnection(_ profile: ConnectionProfile, password: String?) {
        guard activeConfig != nil else {
            connect(profile: profile, password: password)
            return
        }

        if !lifecycleSummary.isEmpty {
            pendingConnectionSwitch = (profile, password)
            switchConnectionWarningMessage = formattedLifecycleWarning(actionVerb: "switch connections")
            showingSwitchConnectionAlert = true
        } else {
            Task { @MainActor in
                await self.performConfirmedConnectionSwitch(to: profile, password: password)
            }
        }
    }

    public func confirmConnectionSwitch() {
        let pending = pendingConnectionSwitch
        pendingConnectionSwitch = nil
        showingSwitchConnectionAlert = false
        switchConnectionWarningMessage = ""
        guard let target = pending else { return }
        Task { @MainActor in
            await self.performConfirmedConnectionSwitch(to: target.profile, password: target.password)
        }
    }

    public func cancelConnectionSwitch() {
        pendingConnectionSwitch = nil
        showingSwitchConnectionAlert = false
        switchConnectionWarningMessage = ""
    }

    public func performConfirmedConnectionSwitch(to profile: ConnectionProfile, password: String?) async {
        let currentReadOnly = sqlWorkspace.defaultReadOnly
        tableViewModel.discardChanges()
        await performBoundedTeardown(timeoutSeconds: 2.5)
        self.selectedTable = ""
        self.tableViewModel = TableDataViewModel()
        self.tableViewModel.isReadOnly = currentReadOnly
        connect(profile: profile, password: password)
    }

    public func connect(profile: ConnectionProfile, password: String?) {
        try? profileStore.saveOrUpdateProfile(profile, markAsConnected: true, markSelected: true)
        refreshSavedProfiles()
        self.selectedProfileId = profile.id
        self.activeProfile = profile
        self.activeConfig = profile.toRustConfig(password: password)
        self.activeConnectionSessionToken = UUID()
        self.currentMode = .sqlEditor
        self.sqlWorkspace.activate(profileId: profile.id, readOnlyDefault: self.tableViewModel.isReadOnly)
        self.tableViewModel.isReadOnly = self.sqlWorkspace.activeTab?.isReadOnly ?? self.sqlWorkspace.defaultReadOnly
    }

    public func openNewSqlTab() {
        guard activeConfig != nil else { return }
        self.currentMode = .sqlEditor
        self.sqlWorkspace.createTab()
    }

    public struct LifecycleSummary: Sendable, Equatable {
        public let pendingTableChangesCount: Int
        public let pendingTableSummary: String
        public let currentTableName: String
        public let hasUncertainCommitOutcome: Bool
        public let activeSqlTabDetails: [String]
        public let activeExportsCount: Int

        public var isEmpty: Bool {
            pendingTableChangesCount == 0
                && !hasUncertainCommitOutcome
                && activeSqlTabDetails.isEmpty
                && activeExportsCount == 0
        }
    }

    public var activeExportViewModels: [CsvExportViewModel] {
        var exports: [CsvExportViewModel] = []
        if let tableExport = tableViewModel.exportViewModel, tableExport.isExporting {
            exports.append(tableExport)
        }
        for tab in sqlWorkspace.tabs {
            if let sqlExport = tab.exportViewModel, sqlExport.isExporting {
                exports.append(sqlExport)
            }
        }
        return exports
    }

    public var lifecycleSummary: LifecycleSummary {
        let activeTabDetails: [String] = sqlWorkspace.tabsWithActiveWork.map { tab in
            var parts: [String] = []
            if tab.isRunning { parts.append("query running") }
            if tab.transactionStatus == .inTransaction { parts.append("uncommitted transaction") }
            if tab.transactionStatus == .failedTransaction { parts.append("aborted transaction") }
            return "• \(tab.title) (\(parts.joined(separator: ", ")))"
        }

        return LifecycleSummary(
            pendingTableChangesCount: tableViewModel.totalStagedOperationsCount,
            pendingTableSummary: tableViewModel.stagedSummaryText,
            currentTableName: tableViewModel.currentTable,
            hasUncertainCommitOutcome: tableViewModel.hasUncertainCommitOutcome,
            activeSqlTabDetails: activeTabDetails,
            activeExportsCount: activeExportViewModels.count
        )
    }

    public func formattedLifecycleWarning(actionVerb: String) -> String {
        let summary = lifecycleSummary
        var sections: [String] = []

        if summary.hasUncertainCommitOutcome {
            sections.append("• Uncertain mutation commit on '\(summary.currentTableName)' has not been reconciled yet (recommended: Reload & Reconcile before leaving).")
        } else if summary.pendingTableChangesCount > 0 {
            let tableName = summary.currentTableName.isEmpty ? "Table Data" : summary.currentTableName
            sections.append("• \(summary.pendingTableChangesCount) staged change(s) (\(summary.pendingTableSummary)) in '\(tableName)' will be discarded.")
        }

        if summary.activeExportsCount > 0 {
            sections.append("• \(summary.activeExportsCount) CSV export\(summary.activeExportsCount == 1 ? "" : "s") currently streaming will be cancelled and temporary output discarded.")
        }

        if !summary.activeSqlTabDetails.isEmpty {
            sections.append("• SQL tabs with active work (queries cancelled, transactions rolled back):\n" + summary.activeSqlTabDetails.joined(separator: "\n"))
        }

        let draftNote = privacyPreferences.isSqlDraftPersistenceEnabled
            ? "Saved SQL drafts remain on disk for this profile, while temporary tables and session settings will be lost."
            : "SQL draft saving is disabled: SQL text in memory will not be persisted to disk, and temporary tables/session settings will be lost."

        return "Continuing to \(actionVerb) will affect:\n\n\(sections.joined(separator: "\n\n"))\n\n\(draftNote)"
    }

    public func loadTable(schema: String, table: String) async {
        guard let config = activeConfig else { return }
        let navigate = { [weak self] in
            guard let self = self else { return }
            self.selectedTable = "\(schema).\(table)"
            self.currentMode = .tableData
            Task {
                await self.tableViewModel.loadTable(config: config, schema: schema, table: table)
            }
        }

        if tableViewModel.hasPendingChanges || tableViewModel.hasUncertainCommitOutcome {
            pendingTableNavigationAction = navigate
            let tableName = tableViewModel.currentTable.isEmpty ? "the current table" : tableViewModel.currentTable
            if tableViewModel.hasUncertainCommitOutcome {
                tableNavigationWarningMessage =
                    "The last commit on '\(tableName)' had an uncertain outcome and has not been reconciled yet. Discard staged items and load '\(schema).\(table)', or cancel to reconcile first?"
            } else {
                tableNavigationWarningMessage =
                    "You have \(tableViewModel.totalStagedOperationsCount) unsaved change(s) (\(tableViewModel.stagedSummaryText)) in '\(tableName)'. Discard them and load '\(schema).\(table)'?"
            }
            showingTableNavigationAlert = true
        } else {
            navigate()
        }
    }

    public func confirmTableNavigation() {
        tableViewModel.discardChanges()
        showingTableNavigationAlert = false
        tableNavigationWarningMessage = ""
        let action = pendingTableNavigationAction
        pendingTableNavigationAction = nil
        action?()
    }

    public func cancelTableNavigation() {
        showingTableNavigationAlert = false
        tableNavigationWarningMessage = ""
        pendingTableNavigationAction = nil
    }

    public func disconnect() {
        let summary = lifecycleSummary
        if !summary.isEmpty {
            disconnectWarningMessage = formattedLifecycleWarning(actionVerb: "disconnect")
            showingDisconnectSessionWarning = true
        } else {
            Task { @MainActor in
                await self.performConfirmedDisconnect()
            }
        }
    }

    public func performBoundedTeardown(timeoutSeconds: Double = 2.5) async {
        sqlWorkspace.flushDrafts()
        let activeExports = activeExportViewModels
        let sqlWorkspaceRef = sqlWorkspace
        let shouldSweepGlobal = sweepGlobalSessionsOnDisconnect

        let timeoutNs = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for exportVM in activeExports {
                    await exportVM.cancelAndWait(timeoutSeconds: timeoutSeconds)
                }
                await sqlWorkspaceRef.closeAllSessionsOnDisconnect()
                if shouldSweepGlobal {
                    try? await close_all_sessions()
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    public func performConfirmedDisconnect() async {
        showingDisconnectSessionWarning = false
        disconnectWarningMessage = ""
        showingTableNavigationAlert = false
        tableNavigationWarningMessage = ""
        pendingTableNavigationAction = nil

        let currentReadOnly = sqlWorkspace.defaultReadOnly
        tableViewModel.discardChanges()
        await performBoundedTeardown(timeoutSeconds: 2.5)

        self.activeProfile = nil
        self.activeConfig = nil
        self.selectedTable = ""
        self.currentMode = .sqlEditor
        self.tableViewModel = TableDataViewModel()
        self.tableViewModel.isReadOnly = currentReadOnly
    }

    public func cancelDisconnect() {
        showingDisconnectSessionWarning = false
        disconnectWarningMessage = ""
    }
}

public struct WorkspaceView: View {
    @StateObject private var model: WorkspaceModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(model: WorkspaceModel? = nil) {
        _model = StateObject(wrappedValue: model ?? WorkspaceModel())
    }

    public var body: some View {
        NavigationSplitView {
            // Grounded Sidebar Column
            Group {
                if let config = model.activeConfig {
                    SchemaTreeView(
                        config: config,
                        activeTableKey: model.selectedTable,
                        onOpenSqlEditor: {
                            model.currentMode = .sqlEditor
                        }
                    ) { schema, table in
                        Task {
                            await model.loadTable(schema: schema, table: table)
                        }
                    }
                    .id(model.activeConnectionSessionToken)
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
                        SqlEditorContainerView(workspace: model.sqlWorkspace, config: config)
                            .id(model.activeConnectionSessionToken)
                    case .tableData:
                        if !model.selectedTable.isEmpty {
                            TableDataContainerView(
                                viewModel: model.tableViewModel,
                                config: config,
                                onToggleReadOnly: {
                                    model.toggleReadOnly()
                                }
                            )
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
                            if model.savedProfiles.isEmpty {
                                VStack(spacing: 14) {
                                    PrimaryActionButton(
                                        title: "New Connection",
                                        icon: "plus",
                                        size: .extraLarge
                                    ) {
                                        model.openConnectionDialog(startNew: true)
                                    }
                                    .keyboardShortcut("n", modifiers: [.command])

                                    KeyboardBadge(keys: ["⌘", "N"], label: "New Connection")
                                }
                                .padding(.top, 4)
                            } else {
                                VStack(spacing: 14) {
                                    VStack(spacing: 0) {
                                        HStack {
                                            Text("SAVED CONNECTIONS")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Button {
                                                model.openConnectionDialog(selecting: model.selectedSavedProfile)
                                            } label: {
                                                Text("Manage...")
                                                    .font(.system(size: 11))
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)

                                        Divider()

                                        ScrollView {
                                            VStack(spacing: 2) {
                                                ForEach(model.savedProfiles) { profile in
                                                    let isSelected = model.selectedProfileId == profile.id
                                                    HStack(spacing: 10) {
                                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "cylinder.split.1x2")
                                                            .font(.system(size: 13))
                                                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                                                        VStack(alignment: .leading, spacing: 2) {
                                                            HStack(spacing: 6) {
                                                                Text(profile.name)
                                                                    .font(.system(size: 13, weight: .medium))
                                                                    .lineLimit(1)
                                                                Text(profile.sslMode)
                                                                    .font(.system(size: 10, weight: .medium))
                                                                    .foregroundStyle(.secondary)
                                                                    .padding(.horizontal, 5)
                                                                    .padding(.vertical, 1)
                                                                    .background(Color(NSColor.quaternaryLabelColor).opacity(0.25), in: Capsule())
                                                                if !profile.rememberPassword {
                                                                    Image(systemName: "key.slash")
                                                                        .font(.system(size: 10))
                                                                        .foregroundStyle(.secondary)
                                                                        .help("Password not stored in Keychain")
                                                                }
                                                            }
                                                            Text("\(profile.user)@\(profile.host):\(profile.port)/\(profile.database)")
                                                                .font(.system(size: 11, design: .monospaced))
                                                                .foregroundStyle(.secondary)
                                                                .lineLimit(1)
                                                        }

                                                        Spacer(minLength: 8)

                                                        Button("Edit") {
                                                            model.openConnectionDialog(selecting: profile)
                                                        }
                                                        .controlSize(.small)

                                                        Button("Connect") {
                                                            model.quickConnect(profile: profile)
                                                        }
                                                        .buttonStyle(.borderedProminent)
                                                        .controlSize(.small)
                                                    }
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 8)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                            .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
                                                    )
                                                    .contentShape(Rectangle())
                                                    .onTapGesture {
                                                        model.selectSavedProfile(profile.id)
                                                    }
                                                    .onTapGesture(count: 2) {
                                                        model.quickConnect(profile: profile)
                                                    }
                                                    .contextMenu {
                                                        Button("Quick Connect") {
                                                            model.quickConnect(profile: profile)
                                                        }
                                                        Button("Edit Connection...") {
                                                            model.openConnectionDialog(selecting: profile)
                                                        }
                                                        Button("Duplicate") {
                                                            model.duplicateSavedProfile(profile.id)
                                                        }
                                                        Divider()
                                                        Button("Delete...", role: .destructive) {
                                                            model.requestDeleteSavedProfile(profile)
                                                        }
                                                    }
                                                }
                                            }
                                            .padding(8)
                                        }
                                        .frame(maxHeight: 220)
                                    }
                                    .frame(width: 520)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5)
                                    )

                                    HStack(spacing: 12) {
                                        if let selected = model.selectedSavedProfile {
                                            PrimaryActionButton(
                                                title: "Connect Selected",
                                                icon: "bolt.fill",
                                                size: .large
                                            ) {
                                                model.quickConnect(profile: selected)
                                            }
                                        }

                                        SecondaryActionButton(
                                            title: "New Connection",
                                            icon: "plus",
                                            size: .large
                                        ) {
                                            model.openConnectionDialog(startNew: true)
                                        }
                                        .keyboardShortcut("n", modifiers: [.command])
                                    }

                                    KeyboardBadge(keys: ["⌘", "N"], label: "New Connection")
                                }
                                .padding(.top, 4)
                            }
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
            .background {
                if model.activeConfig != nil {
                    HStack(spacing: 0) {
                        Button("") {
                            model.currentMode = .sqlEditor
                        }
                        .keyboardShortcut("1", modifiers: [.command])

                        Button("") {
                            model.currentMode = .tableData
                        }
                        .keyboardShortcut("2", modifiers: [.command])
                    }
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
            }
        }
        .toolbar {
            if model.activeConfig != nil {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 6) {
                        Picker("View", selection: $model.currentMode) {
                            Label("SQL Editor", systemImage: "terminal").tag(WorkspaceModel.WorkspaceMode.sqlEditor)
                            Label("Table Data", systemImage: "tablecells").tag(WorkspaceModel.WorkspaceMode.tableData)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                        .help("Switch between SQL Editor (⌘1) and Table Data (⌘2)")

                        Button {
                            model.openNewSqlTab()
                        } label: {
                            Image(systemName: "plus.rectangle.on.rectangle")
                        }
                        .keyboardShortcut("t", modifiers: [.command])
                        .help("New SQL Tab (⌘T)")
                    }
                }
            }

            ToolbarItem(placement: .principal) {
                Button {
                    model.openConnectionDialog()
                } label: {
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
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        } else if let selected = model.selectedSavedProfile {
                            Text("Selected: \(selected.name)")
                                .font(.system(size: 11, weight: .medium))
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
                .buttonStyle(.plain)
                .help("Saved Connections & Quick Switch (⌘⇧O)")
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button {
                        model.isShowingSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings & Draft Privacy (⌘,)")

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
                            model.openConnectionDialog()
                        }
                        .help("Open Connections (⌘N)")
                    }
                }
            }
        }
        .sheet(isPresented: $model.isShowingConnectionSheet) {
            ConnectionDialogView(
                profile: model.initialDialogProfile ?? model.activeProfile ?? model.selectedSavedProfile ?? model.profileStore.mostRecentProfile() ?? ConnectionProfile(),
                initialNotice: model.initialDialogNotice,
                activeConnectedProfileId: model.activeProfile?.id,
                profileStore: model.profileStore,
                draftStore: model.draftStore,
                passwordStore: model.passwordStore,
                onProfilesChanged: {
                    model.refreshSavedProfiles()
                }
            ) { profile, password in
                model.requestConnection(profile, password: password)
            }
        }
        .sheet(isPresented: $model.isShowingSettingsSheet) {
            PrivacySettingsView(
                workspaceModel: model,
                preferences: model.privacyPreferences
            )
        }
        .alert("Discard Unsaved Changes?", isPresented: $model.showingTableNavigationAlert) {
            Button("Discard & Switch Table", role: .destructive) {
                model.confirmTableNavigation()
            }
            Button("Cancel", role: .cancel) {
                model.cancelTableNavigation()
            }
        } message: {
            Text(model.tableNavigationWarningMessage)
        }
        .alert("Confirm Disconnect", isPresented: $model.showingDisconnectSessionWarning) {
            Button("Disconnect & Clean Up", role: .destructive) {
                Task { @MainActor in
                    await model.performConfirmedDisconnect()
                }
            }
            Button("Stay Connected", role: .cancel) {
                model.cancelDisconnect()
            }
        } message: {
            Text(model.disconnectWarningMessage)
        }
        .alert("Switch Connection?", isPresented: $model.showingSwitchConnectionAlert) {
            Button("Switch & Clean Up", role: .destructive) {
                model.confirmConnectionSwitch()
            }
            Button("Stay Connected", role: .cancel) {
                model.cancelConnectionSwitch()
            }
        } message: {
            Text(model.switchConnectionWarningMessage)
        }
        .alert("Delete Saved Connection?", isPresented: $model.showingWelcomeDeleteAlert) {
            Button("Delete Profile", role: .destructive) {
                model.confirmDeleteSavedProfile()
            }
            Button("Cancel", role: .cancel) {
                model.cancelDeleteSavedProfile()
            }
        } message: {
            if let profile = model.profilePendingDelete {
                Text("Delete \"\(profile.name)\" (\(profile.host):\(profile.port))? This removes the profile, its Keychain password, and any saved SQL drafts for it.")
            }
        }
    }
}

private struct WorkspaceDetailBackground: View {
    let reduceTransparency: Bool

    var body: some View {
        if reduceTransparency {
            Color(NSColor.controlBackgroundColor)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular, in: Rectangle())
            } else {
                VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
            }
            #else
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
            #endif
        }
    }
}
