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
    @Published public var currentMode: WorkspaceMode = .tableData
    @Published public var showingDisconnectSessionWarning: Bool = false
    @Published public var disconnectWarningMessage: String = ""
    @Published public var showingSwitchConnectionAlert: Bool = false
    @Published public var switchConnectionWarningMessage: String = ""
    @Published public var showingWelcomeDeleteAlert: Bool = false
    @Published public var profilePendingDelete: ConnectionProfile? = nil
    @Published public var showingTableNavigationAlert: Bool = false
    @Published public var tableNavigationWarningMessage: String = ""
    @Published public var isShowingSettingsSheet: Bool = false
    @Published public var connectingProfileId: UUID? = nil
    @Published public var quickConnectErrorProfileId: UUID? = nil
    @Published public var quickConnectErrorMessage: String? = nil
    @Published public var showingQuickConnectErrorAlert: Bool = false

    public var tableViewModel = TableDataViewModel()
    public let sqlWorkspace: SqlWorkspaceViewModel
    public let profileStore: ConnectionProfileStore
    public let draftStore: SqlDraftStore
    public let passwordStore: any PasswordStoring
    public let privacyPreferences: PrivacyPreferencesStore
    public var sweepGlobalSessionsOnDisconnect: Bool = true
    public var connectionTester: @Sendable (ConnectionConfig) async throws -> String = { config in
        try await test_database_connection(config: config)
    }

    private var terminateObserver: NSObjectProtocol? = nil
    private var pendingTableNavigationAction: (() -> Void)? = nil
    private var pendingConnectionSwitch: (profile: ConnectionProfile, password: String?, needsKeychainLookup: Bool)? = nil
    private var quickConnectTask: Task<Void, Never>? = nil

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
        cancelInFlightQuickConnect()
        clearQuickConnectError()
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

    public func clearQuickConnectError() {
        quickConnectErrorProfileId = nil
        quickConnectErrorMessage = nil
        showingQuickConnectErrorAlert = false
    }

    private func cancelInFlightQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        connectingProfileId = nil
    }

    public func quickConnect(profile: ConnectionProfile) {
        guard connectingProfileId == nil else { return }
        if activeConfig != nil, activeProfile?.id == profile.id {
            return
        }

        selectSavedProfile(profile.id)
        clearQuickConnectError()

        if !profile.rememberPassword {
            openConnectionDialog(
                selecting: profile,
                notice: "Enter password for \"\(profile.name)\"."
            )
            return
        }

        // Check active-session and pending-edit safeguards BEFORE reading Keychain.
        if activeConfig != nil && !lifecycleSummary.isEmpty {
            pendingConnectionSwitch = (profile, nil, true)
            switchConnectionWarningMessage = formattedLifecycleWarning(actionVerb: "switch connections")
            showingSwitchConnectionAlert = true
            return
        }

        startQuickConnectAttempt(profile: profile, preResolvedPassword: nil, lookupFromKeychain: true)
    }

    private func resolveSavedPasswordForConnect(profile: ConnectionProfile) -> (proceed: Bool, password: String?) {
        guard profile.rememberPassword, passwordStore.hasStoredPassword(profileId: profile.id) else {
            return (true, nil)
        }
        switch passwordStore.lookupPassword(profileId: profile.id) {
        case .found(let pw):
            return (true, pw)
        case .notFound:
            return (true, nil)
        case .accessDenied:
            self.quickConnectErrorProfileId = profile.id
            self.quickConnectErrorMessage = "Keychain access was denied or cancelled. Enter a password or allow Keychain access to connect."
            if self.activeConfig != nil {
                self.showingQuickConnectErrorAlert = true
            }
            return (false, nil)
        case .failed(let reason):
            self.quickConnectErrorProfileId = profile.id
            self.quickConnectErrorMessage = reason
            if self.activeConfig != nil {
                self.showingQuickConnectErrorAlert = true
            }
            return (false, nil)
        }
    }

    private func startQuickConnectAttempt(
        profile: ConnectionProfile,
        preResolvedPassword: String?,
        lookupFromKeychain: Bool
    ) {
        let resolvedPassword: String?
        if let preResolvedPassword {
            resolvedPassword = preResolvedPassword.isEmpty ? nil : preResolvedPassword
        } else if lookupFromKeychain {
            let resolution = resolveSavedPasswordForConnect(profile: profile)
            guard resolution.proceed else { return }
            resolvedPassword = resolution.password
        } else {
            resolvedPassword = nil
        }

        connectingProfileId = profile.id
        let config = profile.toRustConfig(password: resolvedPassword)
        let tester = connectionTester

        quickConnectTask = Task { @MainActor [weak self, profile, resolvedPassword] in
            guard let self else { return }
            do {
                _ = try await tester(config)
                guard !Task.isCancelled else { return }
                self.connectingProfileId = nil
                self.quickConnectTask = nil
                if self.activeConfig != nil {
                    await self.performConfirmedConnectionSwitch(to: profile, password: resolvedPassword)
                } else {
                    self.connect(profile: profile, password: resolvedPassword)
                }
            } catch is CancellationError {
                self.connectingProfileId = nil
                self.quickConnectTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.connectingProfileId = nil
                self.quickConnectTask = nil
                self.quickConnectErrorProfileId = profile.id
                self.quickConnectErrorMessage = error.userFacingMessage
                if self.activeConfig != nil {
                    self.showingQuickConnectErrorAlert = true
                }
            }
        }
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
            pendingConnectionSwitch = (profile, password, false)
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
        if target.needsKeychainLookup {
            startQuickConnectAttempt(profile: target.profile, preResolvedPassword: nil, lookupFromKeychain: true)
            return
        }
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
        cancelInFlightQuickConnect()
        clearQuickConnectError()
        try? profileStore.saveOrUpdateProfile(profile, markAsConnected: true, markSelected: true)
        refreshSavedProfiles()
        self.selectedProfileId = profile.id
        self.activeProfile = profile
        self.activeConfig = profile.toRustConfig(password: password)
        self.activeConnectionSessionToken = UUID()
        self.currentMode = .tableData
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
        cancelInFlightQuickConnect()
        clearQuickConnectError()
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
        self.currentMode = .tableData
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
                        tableViewModel: model.tableViewModel,
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SCHEMAS & TABLES")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)

                        Text("Connect to browse schemas and tables.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
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
                            VStack(spacing: 10) {
                                Spacer()
                                Image(systemName: "tablecells")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(.tertiary)
                                Text("Select a table in the sidebar")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                } else {
                    WelcomeView(model: model)
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
        .alert("Connection Failed", isPresented: $model.showingQuickConnectErrorAlert) {
            if let failedId = model.quickConnectErrorProfileId,
               let failedProfile = model.savedProfiles.first(where: { $0.id == failedId }) {
                Button("Edit Connection…") {
                    model.openConnectionDialog(selecting: failedProfile)
                }
            }
            Button("OK", role: .cancel) {
                model.clearQuickConnectError()
            }
        } message: {
            Text(model.quickConnectErrorMessage ?? "Could not connect to PostgreSQL.")
        }
    }
}

@MainActor
private final class WelcomeHoverState: ObservableObject {
    @Published var hoveredProfileId: UUID? = nil
}

private struct WelcomeView: View {
    @ObservedObject var model: WorkspaceModel
    @StateObject private var hoverState = WelcomeHoverState()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)

            VStack(spacing: 10) {
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.accentColor)

                Text("LucidSQL")
                    .font(.system(size: 28, weight: .semibold))

                Text("PostgreSQL client for macOS")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            if model.savedProfiles.isEmpty {
                VStack(spacing: 10) {
                    PrimaryActionButton(
                        title: "New Connection",
                        icon: "plus",
                        size: .large
                    ) {
                        model.openConnectionDialog(startNew: true)
                    }

                    Text("Add a PostgreSQL connection to get started.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else {
                VStack(spacing: 16) {
                    savedConnectionsList
                        .frame(maxWidth: 348)
                        .background {
                            if reduceTransparency {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(NSColor.controlBackgroundColor))
                            } else {
                                #if compiler(>=6.2)
                                if #available(macOS 26.0, *) {
                                    Color.clear
                                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(.regularMaterial)
                                }
                                #else
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(.regularMaterial)
                                #endif
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(reduceTransparency ? 0.16 : 0.08), lineWidth: 0.5)
                        )

                    if let errorMsg = model.quickConnectErrorMessage {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                            Text(errorMsg)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            if let failedId = model.quickConnectErrorProfileId,
                               let failedProfile = model.savedProfiles.first(where: { $0.id == failedId }) {
                                Button("Edit…") {
                                    model.openConnectionDialog(selecting: failedProfile)
                                }
                                .toolbarCapsuleControlStyle(size: .mini)
                            }
                            Button {
                                model.clearQuickConnectError()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 348)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    VStack(spacing: 10) {
                        PrimaryActionButton(
                            title: "New Connection",
                            icon: "plus",
                            size: .large
                        ) {
                            model.openConnectionDialog(startNew: true)
                        }

                        Button("Manage Connections…") {
                            model.openConnectionDialog(selecting: model.selectedSavedProfile)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var savedConnectionsList: some View {
        let rows = VStack(spacing: 0) {
            ForEach(Array(model.savedProfiles.enumerated()), id: \.element.id) { index, profile in
                SavedProfileRowView(
                    profile: profile,
                    model: model,
                    hoverState: hoverState
                )
                if index < model.savedProfiles.count - 1 {
                    Divider()
                        .opacity(0.45)
                        .padding(.leading, 38)
                }
            }
        }
        .padding(.vertical, 4)

        if model.savedProfiles.count <= 5 {
            rows
        } else {
            ScrollView {
                rows
            }
            .frame(height: 232)
        }
    }
}

private struct SavedProfileRowView: View {
    let profile: ConnectionProfile
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var hoverState: WelcomeHoverState

    private var isHovered: Bool {
        hoverState.hoveredProfileId == profile.id
    }

    private var isConnectingThis: Bool {
        model.connectingProfileId == profile.id
    }

    private var isAnyConnecting: Bool {
        model.connectingProfileId != nil
    }

    private var hostSummary: String {
        profile.port == 5432 ? profile.host : "\(profile.host):\(String(profile.port))"
    }

    var body: some View {
        Button {
            model.quickConnect(profile: profile)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isConnectingThis ? Color.accentColor : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(hostSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if isConnectingThis {
                    ProgressView()
                        .controlSize(.small)
                } else if !profile.rememberPassword {
                    Image(systemName: "key.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("Password not stored in Keychain")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowBackgroundColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAnyConnecting)
        .opacity(isAnyConnecting && !isConnectingThis ? 0.55 : 1.0)
        .onHover { hovering in
            if hovering {
                hoverState.hoveredProfileId = profile.id
            } else if hoverState.hoveredProfileId == profile.id {
                hoverState.hoveredProfileId = nil
            }
        }
        .contextMenu {
            Button("Connect") {
                model.quickConnect(profile: profile)
            }
            .disabled(isAnyConnecting)
            Button("Edit…") {
                model.openConnectionDialog(selecting: profile)
            }
            Button("Duplicate") {
                model.duplicateSavedProfile(profile.id)
            }
            Divider()
            Button("Delete…", role: .destructive) {
                model.requestDeleteSavedProfile(profile)
            }
        }
    }

    private var rowBackgroundColor: Color {
        if isConnectingThis {
            return Color.accentColor.opacity(0.14)
        }
        if isHovered && !isAnyConnecting {
            return Color.primary.opacity(0.065)
        }
        return Color.clear
    }
}

private struct WorkspaceDetailBackground: View {
    let reduceTransparency: Bool

    var body: some View {
        if reduceTransparency {
            Color(NSColor.controlBackgroundColor)
        } else {
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
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

public enum ConnectionSelectorState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(name: String, endpoint: String?)
}

public enum ConnectionDisplayFormatting {
    public static func hostSummary(for profile: ConnectionProfile) -> String {
        profile.port == 5432 ? profile.host : "\(profile.host):\(String(profile.port))"
    }

    public static func shouldAppendEndpoint(for profile: ConnectionProfile) -> Bool {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return false }
        let summary = hostSummary(for: profile).lowercased()
        let hostWithPort = "\(host):\(profile.port)"
        return !name.contains(summary) && !name.contains(hostWithPort) && !name.contains(host)
    }

    public static func menuLabel(for profile: ConnectionProfile) -> String {
        if shouldAppendEndpoint(for: profile) {
            return "\(profile.name) — \(hostSummary(for: profile))"
        }
        return profile.name
    }

    public static func selectorState(
        activeProfile: ConnectionProfile?,
        isConnected: Bool,
        isConnecting: Bool
    ) -> ConnectionSelectorState {
        if isConnecting {
            return .connecting
        }
        guard isConnected, let profile = activeProfile else {
            return .disconnected
        }
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = hostSummary(for: profile)
        if trimmedName.isEmpty {
            return .connected(name: host.isEmpty ? "Connected" : host, endpoint: nil)
        }
        let endpoint = shouldAppendEndpoint(for: profile) ? host : nil
        return .connected(name: trimmedName, endpoint: endpoint)
    }

    public static func truncateToFit(
        _ value: String,
        maxWidth: CGFloat,
        middle: Bool = false,
        measure: (String) -> CGFloat
    ) -> String {
        if measure(value) <= maxWidth {
            return value
        }
        let chars = Array(value)
        guard !chars.isEmpty else { return value }
        var low = 0
        var high = chars.count
        var best = "…"
        while low <= high {
            let count = (low + high) / 2
            let candidate: String
            if count == 0 {
                candidate = "…"
            } else if middle {
                let prefixCount = (count + 1) / 2
                let suffixCount = count / 2
                candidate = String(chars.prefix(prefixCount)) + "…" + String(chars.suffix(suffixCount))
            } else {
                candidate = String(chars.prefix(count)) + "…"
            }
            if measure(candidate) <= maxWidth {
                best = candidate
                low = count + 1
            } else {
                high = count - 1
            }
        }
        return best
    }

    public static func fitConnectedStrings(
        name: String,
        endpoint: String?,
        availableTextWidth: CGFloat,
        gapWidth: CGFloat,
        measureName: (String) -> CGFloat,
        measureEndpoint: (String) -> CGFloat
    ) -> (name: String, endpoint: String?) {
        let clampedAvailable = max(60, availableTextWidth)
        guard let endpoint, !endpoint.isEmpty else {
            return (
                truncateToFit(name, maxWidth: clampedAvailable, middle: false, measure: measureName),
                nil
            )
        }
        let fullNameWidth = measureName(name)
        let fullEndpointWidth = measureEndpoint(endpoint)
        if fullNameWidth + gapWidth + fullEndpointWidth <= clampedAvailable {
            return (name, endpoint)
        }

        // Preserve both profile name and host/IP when truncating long names.
        let endpointBudget = min(fullEndpointWidth, max(72, clampedAvailable * 0.40))
        let nameBudget = max(48, clampedAvailable - gapWidth - endpointBudget)
        let fittedName = truncateToFit(name, maxWidth: nameBudget, middle: false, measure: measureName)
        let fittedEndpoint = truncateToFit(endpoint, maxWidth: endpointBudget, middle: true, measure: measureEndpoint)
        return (fittedName, fittedEndpoint)
    }
}

private struct ToolbarConnectionSelector: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.colorScheme) private var colorScheme

    private var selectorState: ConnectionSelectorState {
        ConnectionDisplayFormatting.selectorState(
            activeProfile: model.activeProfile,
            isConnected: model.activeConfig != nil,
            isConnecting: model.connectingProfileId != nil
        )
    }

    var body: some View {
        ToolbarConnectionDropdownBridge(
            model: model,
            selectorState: selectorState,
            tooltip: tooltipText,
            accessibilityLabelText: accessibilityText,
            colorScheme: colorScheme
        )
        .help(tooltipText)
    }

    private func hostSummary(for profile: ConnectionProfile) -> String {
        ConnectionDisplayFormatting.hostSummary(for: profile)
    }

    private var tooltipText: String {
        if model.connectingProfileId != nil {
            if let connectingId = model.connectingProfileId,
               let connectingProfile = model.savedProfiles.first(where: { $0.id == connectingId }) {
                return "Connecting to \(connectingProfile.name) (\(hostSummary(for: connectingProfile)))…"
            }
            return "Connecting to PostgreSQL…"
        }
        if let profile = model.activeProfile, model.activeConfig != nil {
            return "\(profile.name) · \(profile.user)@\(hostSummary(for: profile))/\(profile.database) · SSL: \(profile.sslMode)"
        }
        return "Connections (⌘⇧O)"
    }

    private var accessibilityText: String {
        if model.connectingProfileId != nil {
            return "Connecting to database"
        }
        if let profile = model.activeProfile, model.activeConfig != nil {
            return "Connected to \(profile.name), \(hostSummary(for: profile))"
        }
        return "Connections, not connected"
    }
}

private struct ToolbarConnectionDropdownBridge: NSViewRepresentable {
    let model: WorkspaceModel
    let selectorState: ConnectionSelectorState
    let tooltip: String
    let accessibilityLabelText: String
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> ToolbarConnectionDropdownButton {
        let button = ToolbarConnectionDropdownButton()
        button.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.buildMenu() ?? NSMenu()
        }
        apply(to: button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ nsView: ToolbarConnectionDropdownButton, context: Context) {
        apply(to: nsView, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ToolbarConnectionDropdownButton,
        context: Context
    ) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            let clamped = max(nsView.minimumDisplayWidth, min(intrinsic.width, proposedWidth))
            return CGSize(width: clamped, height: intrinsic.height)
        }
        return intrinsic
    }

    private func apply(to button: ToolbarConnectionDropdownButton, coordinator: Coordinator) {
        coordinator.model = model
        button.selectorState = selectorState
        button.toolTip = tooltip
        button.setAccessibilityLabel(accessibilityLabelText)
        button.refreshTitle(forceInvalidateSize: true)
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: WorkspaceModel

        init(model: WorkspaceModel) {
            self.model = model
        }

        func buildMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            if !model.savedProfiles.isEmpty {
                for profile in model.savedProfiles {
                    let isActive = model.activeProfile?.id == profile.id && model.activeConfig != nil
                    let itemTitle = ConnectionDisplayFormatting.menuLabel(for: profile)
                    let item = NSMenuItem(
                        title: itemTitle,
                        action: #selector(selectProfile(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = profile.id
                    item.state = isActive ? .on : .off
                    item.isEnabled = (model.connectingProfileId == nil && !isActive)
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            }

            let newItem = NSMenuItem(
                title: "New Connection…",
                action: #selector(openNewConnection(_:)),
                keyEquivalent: ""
            )
            newItem.target = self
            newItem.isEnabled = true
            menu.addItem(newItem)

            let manageItem = NSMenuItem(
                title: "Manage Connections…",
                action: #selector(openManageConnections(_:)),
                keyEquivalent: ""
            )
            manageItem.target = self
            manageItem.isEnabled = true
            menu.addItem(manageItem)

            if model.activeConfig != nil {
                menu.addItem(.separator())
                let disconnectItem = NSMenuItem(
                    title: "Disconnect",
                    action: #selector(disconnectActive(_:)),
                    keyEquivalent: ""
                )
                disconnectItem.target = self
                disconnectItem.isEnabled = true
                menu.addItem(disconnectItem)
            }

            return menu
        }

        @objc func selectProfile(_ sender: NSMenuItem) {
            guard let profileId = sender.representedObject as? UUID,
                  let profile = model.savedProfiles.first(where: { $0.id == profileId }) else {
                return
            }
            model.quickConnect(profile: profile)
        }

        @objc func openNewConnection(_ sender: NSMenuItem) {
            model.openConnectionDialog(startNew: true)
        }

        @objc func openManageConnections(_ sender: NSMenuItem) {
            model.openConnectionDialog(selecting: model.activeProfile ?? model.selectedSavedProfile)
        }

        @objc func disconnectActive(_ sender: NSMenuItem) {
            model.disconnect()
        }
    }
}

/// Native toolbar dropdown button backed by `NSButton` + `NSMenu` so macOS 26+ Liquid Glass
/// and earlier macOS toolbars render one capsule surface, one hit target, and full label fidelity.
private final class ToolbarConnectionDropdownButton: NSButton {
    var selectorState: ConnectionSelectorState = .disconnected
    var menuProvider: (() -> NSMenu)?

    private let maxButtonWidth: CGFloat = 360
    private let minConnectedWidth: CGFloat = 96
    private let minDisconnectedWidth: CGFloat = 58
    private let minimumBezelOverhead: CGFloat = 16
    private var fullTitleWidth: CGFloat = 0
    private var desiredWidth: CGFloat = 58
    private var lastRenderedWidthBudget: CGFloat? = nil

    var minimumDisplayWidth: CGFloat {
        (selectorState == .disconnected) ? minDisconnectedWidth : minConnectedWidth
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = true
        bezelStyle = .toolbar
        setButtonType(.momentaryPushIn)
        imagePosition = .noImage
        lineBreakMode = .byClipping
        focusRingType = .default
        setAccessibilityRole(.popUpButton)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshTitle(forceInvalidateSize: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let width = min(max(desiredWidth, minimumDisplayWidth), maxButtonWidth)
        return NSSize(width: width, height: max(super.intrinsicContentSize.height, 26))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTitle(forceInvalidateSize: false)
    }

    override func layout() {
        super.layout()
        // If a compressed window narrows the button below what the fitted title requires,
        // re-fit the name/endpoint text so the trailing chevron remains visible.
        if bounds.width > 0, bounds.width < fullTitleWidth + minimumBezelOverhead - 1 {
            let constrainedBudget = max(48, bounds.width - horizontalPadding)
            if lastRenderedWidthBudget != constrainedBudget {
                attributedTitle = buildAttributedTitle(maxTextWidth: constrainedBudget)
                lastRenderedWidthBudget = constrainedBudget
            }
        } else if lastRenderedWidthBudget != nil {
            let fullBudget = maxButtonWidth - horizontalPadding
            attributedTitle = buildAttributedTitle(maxTextWidth: fullBudget)
            lastRenderedWidthBudget = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        presentDropdownMenu()
    }

    override func performClick(_ sender: Any?) {
        presentDropdownMenu()
    }

    override func keyDown(with event: NSEvent) {
        // Space (49), Return (36), Keypad Enter (76), Down Arrow (125)
        if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 125 {
            presentDropdownMenu()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        presentDropdownMenu()
        return true
    }

    func refreshTitle(forceInvalidateSize: Bool) {
        let maxTextWidth = maxButtonWidth - horizontalPadding
        let fullTitle = buildAttributedTitle(maxTextWidth: maxTextWidth)
        fullTitleWidth = ceil(fullTitle.size().width)
        desiredWidth = fullTitleWidth + horizontalPadding
        lastRenderedWidthBudget = nil
        attributedTitle = fullTitle

        if forceInvalidateSize {
            invalidateIntrinsicContentSize()
        }
    }

    private var horizontalPadding: CGFloat {
        switch selectorState {
        case .disconnected: return 24
        case .connecting: return 26
        case .connected: return 28
        }
    }

    private func presentDropdownMenu() {
        guard isEnabled, let menu = menuProvider?() else { return }
        highlight(true)
        defer { highlight(false) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 6), in: self)
    }

    private func buildAttributedTitle(maxTextWidth: CGFloat) -> NSAttributedString {
        let primaryFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let secondaryFont = NSFont.systemFont(ofSize: 11.5)
        let gapString = "  "
        let gapWidth = (gapString as NSString).size(withAttributes: [.font: primaryFont]).width

        let chevronImage = symbolImage(name: "chevron.down", pointSize: 9, weight: .semibold, color: .secondaryLabelColor)

        switch selectorState {
        case .disconnected:
            let result = NSMutableAttributedString()
            if let dbImage = symbolImage(name: "cylinder.split.1x2", pointSize: 12.5, weight: .medium, color: .secondaryLabelColor) {
                result.append(attachmentString(for: dbImage, yOffset: -1.5))
            }
            result.append(NSAttributedString(string: gapString, attributes: [.font: primaryFont]))
            if let chevronImage {
                result.append(attachmentString(for: chevronImage, yOffset: 0.5))
            }
            return result

        case .connecting:
            let result = NSMutableAttributedString()
            if let dotImage = symbolImage(name: "circle.fill", pointSize: 7, weight: .regular, color: .systemOrange) {
                result.append(attachmentString(for: dotImage, yOffset: 1.5))
                result.append(NSAttributedString(string: gapString, attributes: [.font: primaryFont]))
            }
            result.append(NSAttributedString(string: "Connecting…", attributes: [
                .font: primaryFont,
                .foregroundColor: NSColor.labelColor,
            ]))
            result.append(NSAttributedString(string: gapString, attributes: [.font: primaryFont]))
            if let chevronImage {
                result.append(attachmentString(for: chevronImage, yOffset: 0.5))
            }
            return result

        case .connected(let name, let endpoint):
            let dotImage = symbolImage(name: "circle.fill", pointSize: 7, weight: .regular, color: .systemGreen)
            let fixedWidth = (dotImage?.size.width ?? 8) + gapWidth + gapWidth + (chevronImage?.size.width ?? 10)
            let availableForText = max(60, maxTextWidth - fixedWidth)

            let fitted = ConnectionDisplayFormatting.fitConnectedStrings(
                name: name,
                endpoint: endpoint,
                availableTextWidth: availableForText,
                gapWidth: gapWidth,
                measureName: { ($0 as NSString).size(withAttributes: [.font: primaryFont]).width },
                measureEndpoint: { ($0 as NSString).size(withAttributes: [.font: secondaryFont]).width }
            )

            let result = NSMutableAttributedString()
            if let dotImage {
                result.append(attachmentString(for: dotImage, yOffset: 1.5))
                result.append(NSAttributedString(string: gapString, attributes: [.font: primaryFont]))
            }
            result.append(NSAttributedString(string: fitted.name, attributes: [
                .font: primaryFont,
                .foregroundColor: NSColor.labelColor,
            ]))
            if let fittedEndpoint = fitted.endpoint, !fittedEndpoint.isEmpty {
                result.append(NSAttributedString(string: gapString + fittedEndpoint, attributes: [
                    .font: secondaryFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            result.append(NSAttributedString(string: gapString, attributes: [.font: primaryFont]))
            if let chevronImage {
                result.append(attachmentString(for: chevronImage, yOffset: 0.5))
            }
            return result
        }
    }

    private func symbolImage(name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(config)
    }

    private func attachmentString(for image: NSImage, yOffset: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: yOffset, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
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

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "cable.connector.slash")
                }
                .labelStyle(.iconOnly)
                .help("Disconnect")
                .accessibilityLabel("Disconnect")
            }
        }
    }
}
