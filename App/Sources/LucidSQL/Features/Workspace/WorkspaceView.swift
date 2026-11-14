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
}

private struct ToolbarConnectionSelector: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Menu {
            if !model.savedProfiles.isEmpty {
                ForEach(model.savedProfiles) { profile in
                    let isActive = model.activeProfile?.id == profile.id && model.activeConfig != nil
                    let itemTitle = ConnectionDisplayFormatting.menuLabel(for: profile)
                    Button {
                        model.quickConnect(profile: profile)
                    } label: {
                        if isActive {
                            Label(itemTitle, systemImage: "checkmark")
                        } else {
                            Text(itemTitle)
                        }
                    }
                    .disabled(model.connectingProfileId != nil || isActive)
                }

                Divider()
            }

            Button("New Connection…") {
                model.openConnectionDialog(startNew: true)
            }

            Button("Manage Connections…") {
                model.openConnectionDialog(selecting: model.activeProfile ?? model.selectedSavedProfile)
            }

            if model.activeConfig != nil {
                Divider()
                Button("Disconnect") {
                    model.disconnect()
                }
            }
        } label: {
            selectorLabel
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .help(tooltipText)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var selectorLabel: some View {
        if let profile = model.activeProfile, model.activeConfig != nil {
            Group {
                if model.connectingProfileId != nil {
                    (
                        Text("Connecting…  ")
                            .font(.system(size: 12, weight: .medium))
                        + Text(Image(systemName: "chevron.down"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    )
                } else {
                    let showEndpoint = ConnectionDisplayFormatting.shouldAppendEndpoint(for: profile)
                    let displayName = profile.name.count > 26 ? String(profile.name.prefix(25)) + "…" : profile.name
                    let host = hostSummary(for: profile)
                    let displayHost = host.count > 26 ? String(host.prefix(25)) + "…" : host
                    if showEndpoint {
                        (
                            Text(Image(systemName: "circle.fill"))
                                .font(.system(size: 7))
                                .foregroundColor(.green)
                            + Text("  \(displayName)")
                                .font(.system(size: 12.5, weight: .medium))
                            + Text("  \(displayHost)")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                            + Text("  ")
                                .font(.system(size: 8))
                            + Text(Image(systemName: "chevron.down"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    } else {
                        (
                            Text(Image(systemName: "circle.fill"))
                                .font(.system(size: 7))
                                .foregroundColor(.green)
                            + Text("  \(displayName)")
                                .font(.system(size: 12.5, weight: .medium))
                            + Text("  ")
                                .font(.system(size: 8))
                            + Text(Image(systemName: "chevron.down"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 5)
            .frame(minHeight: 26)
            .frame(maxWidth: 360)
            .fixedSize(horizontal: true, vertical: false)
        } else {
            Group {
                if model.connectingProfileId != nil {
                    (
                        Text("Connecting…  ")
                            .font(.system(size: 12, weight: .medium))
                        + Text(Image(systemName: "chevron.down"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    )
                } else {
                    (
                        Text(Image(systemName: "cylinder.split.1x2"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.secondary)
                        + Text("  ")
                            .font(.system(size: 8))
                        + Text(Image(systemName: "chevron.down"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .frame(minWidth: 52, minHeight: 26)
            .fixedSize()
        }
    }

    private func hostSummary(for profile: ConnectionProfile) -> String {
        ConnectionDisplayFormatting.hostSummary(for: profile)
    }

    private var tooltipText: String {
        if let profile = model.activeProfile, model.activeConfig != nil {
            return "\(profile.name) · \(profile.user)@\(hostSummary(for: profile))/\(profile.database) · SSL: \(profile.sslMode)"
        }
        return "Connections (⌘⇧O)"
    }

    private var accessibilityText: String {
        if let profile = model.activeProfile, model.activeConfig != nil {
            return "Connected to \(profile.name), \(profile.host)"
        }
        return "Connections, not connected"
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
