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
        tableViewModel.cancelActiveLoad()
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
            self.tableViewModel.startTableLoad(config: config, schema: schema, table: table)
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
        tableViewModel.cancelActiveLoad()
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
                                                    SavedProfileRowView(
                                                        profile: profile,
                                                        isSelected: model.selectedProfileId == profile.id,
                                                        model: model
                                                    )
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
            workspaceToolbar
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

private struct SavedProfileRowView: View {
    let profile: ConnectionProfile
    let isSelected: Bool
    @ObservedObject var model: WorkspaceModel

    var body: some View {
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

private struct ToolbarWorkspaceModePicker: View {
    @Binding var selection: WorkspaceModel.WorkspaceMode

    var body: some View {
        Picker("Workspace Mode", selection: $selection) {
            Label("SQL Editor", systemImage: "terminal")
                .tag(WorkspaceModel.WorkspaceMode.sqlEditor)
            Label("Table Data", systemImage: "tablecells")
                .tag(WorkspaceModel.WorkspaceMode.tableData)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Switch Workspace Mode: SQL Editor (⌘1) · Table Data (⌘2)")
    }
}

private struct ToolbarConnectionSelector: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Button {
            model.openConnectionDialog()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.activeConfig != nil ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)

                if let profile = model.activeProfile {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            Text(profile.name)
                                .font(.system(size: 12, weight: .medium))
                                .fixedSize(horizontal: true, vertical: false)
                            Text(hostSummary(for: profile))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        HStack(spacing: 5) {
                            Text(profile.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if !hostSummary(for: profile).isEmpty {
                                Text(hostSummary(for: profile))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(minWidth: 72)
                            }
                        }

                        Text(profile.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if let selected = model.selectedSavedProfile {
                    Text(selected.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not Connected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: 280)
        }
        .buttonStyle(.plain)
        .help(tooltipText)
        .accessibilityLabel(accessibilityText)
    }

    private func hostSummary(for profile: ConnectionProfile) -> String {
        profile.port == 5432 ? profile.host : "\(profile.host):\(profile.port)"
    }

    private var tooltipText: String {
        if let profile = model.activeProfile {
            return "\(profile.name)\n\(profile.user)@\(profile.host):\(profile.port)/\(profile.database) (SSL: \(profile.sslMode))\nClick to switch or manage connections (⌘⇧O)"
        }
        if let selected = model.selectedSavedProfile {
            return "Selected profile: \(selected.name) (\(selected.user)@\(selected.host):\(selected.port)/\(selected.database))\nClick to connect or switch profiles (⌘⇧O)"
        }
        return "Saved Connections & Quick Switch (⌘⇧O)"
    }

    private var accessibilityText: String {
        if let profile = model.activeProfile {
            return "Connected to \(profile.name), \(profile.host)"
        }
        if let selected = model.selectedSavedProfile {
            return "Selected profile \(selected.name), not connected"
        }
        return "Not connected, open connections"
    }
}

private extension WorkspaceView {
    @ToolbarContentBuilder
    var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ToolbarConnectionSelector(model: model)
        }

        if model.activeConfig != nil {
            ToolbarItem(placement: .automatic) {
                ToolbarWorkspaceModePicker(selection: $model.currentMode)
            }

            newSqlTabToolbarItem
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.isShowingSettingsSheet = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)
            .help("Settings & Draft Privacy (⌘,)")
            .accessibilityLabel("Settings")

            if model.activeConfig != nil {
                Button {
                    model.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "cable.connector.slash")
                }
                .labelStyle(.iconOnly)
                .help("Disconnect from Database")
                .accessibilityLabel("Disconnect from Database")
            } else {
                Button {
                    model.openConnectionDialog()
                } label: {
                    Label("Connect", systemImage: "cable.connector")
                }
                .labelStyle(.titleAndIcon)
                .help("Open Connections (⌘N)")
                .accessibilityLabel("Connect to Database")
            }
        }
    }

    @ToolbarContentBuilder
    var newSqlTabToolbarItem: some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .automatic) {
                newSqlTabButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) {
                newSqlTabButton
            }
        }
        #else
        ToolbarItem(placement: .automatic) {
            newSqlTabButton
        }
        #endif
    }

    var newSqlTabButton: some View {
        Button {
            model.openNewSqlTab()
        } label: {
            Label("New SQL Tab", systemImage: "plus.rectangle.on.rectangle")
        }
        .labelStyle(.iconOnly)
        .keyboardShortcut("t", modifiers: [.command])
        .help("New SQL Tab (⌘T)")
        .accessibilityLabel("New SQL Tab")
    }
}
