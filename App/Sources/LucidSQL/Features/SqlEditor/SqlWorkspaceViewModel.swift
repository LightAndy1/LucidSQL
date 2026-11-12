import Foundation
import Observation
import LucidSQLBridge

@Observable
@MainActor
public final class SqlWorkspaceViewModel {
    public static let restoredDraftNotice =
        "Saved draft restored — no database session opened yet. Restored tabs do not recreate temporary tables, session variables, or open transactions."

    public private(set) var tabs: [SqlEditorViewModel] = []
    public var activeTabID: UUID? = nil
    public private(set) var currentProfileId: UUID? = nil

    public var showingCloseTabConfirmation: Bool = false
    public private(set) var tabPendingClose: SqlEditorViewModel? = nil
    public var renamingTabID: UUID? = nil
    public var renameDraft: String = ""
    public var defaultReadOnly: Bool = false
    public var onReadOnlyChanged: ((Bool) -> Void)? = nil

    public let draftStore: SqlDraftStore
    public let privacyPreferences: PrivacyPreferencesStore
    private var pendingSaveTask: Task<Void, Never>? = nil

    public var activeTab: SqlEditorViewModel? {
        if let activeTabID, let found = tabs.first(where: { $0.id == activeTabID }) {
            return found
        }
        return tabs.first
    }

    public var tabsWithActiveWork: [SqlEditorViewModel] {
        tabs.filter { $0.isRunning || $0.transactionStatus != .idle }
    }

    public var hasActiveWorkOrTransactions: Bool {
        !tabsWithActiveWork.isEmpty
    }

    public var activeSessionsInTabsCount: Int {
        tabs.filter(\.hasActiveSession).count
    }

    public init(
        draftStore: SqlDraftStore = SqlDraftStore(),
        privacyPreferences: PrivacyPreferencesStore? = nil
    ) {
        self.draftStore = draftStore
        self.privacyPreferences = privacyPreferences ?? PrivacyPreferencesStore.shared
    }

    public func activateSingleTab(_ tab: SqlEditorViewModel) {
        self.currentProfileId = nil
        bindTab(tab)
        self.tabs = [tab]
        self.activeTabID = tab.id
    }

    public func activate(profileId: UUID, readOnlyDefault: Bool = false) {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        self.currentProfileId = profileId
        self.defaultReadOnly = readOnlyDefault
        self.tabPendingClose = nil
        self.showingCloseTabConfirmation = false
        self.renamingTabID = nil

        if privacyPreferences.isSqlDraftPersistenceEnabled,
           let snapshot = draftStore.loadWorkspace(for: profileId),
           !snapshot.tabs.isEmpty {
            let restoredTabs = snapshot.tabs.map { draft -> SqlEditorViewModel in
                let vm = SqlEditorViewModel(
                    id: draft.id,
                    title: draft.title.isEmpty ? "Query" : draft.title,
                    sqlText: draft.sqlText,
                    selectedRange: NSRange(
                        location: draft.selectionLocation,
                        length: draft.selectionLength
                    ),
                    isReadOnly: draft.isReadOnly,
                    sessionBannerMessage: Self.restoredDraftNotice
                )
                bindTab(vm)
                return vm
            }
            self.tabs = restoredTabs
            if let savedActive = snapshot.activeTabId,
               restoredTabs.contains(where: { $0.id == savedActive }) {
                self.activeTabID = savedActive
            } else {
                self.activeTabID = restoredTabs.first?.id
            }
        } else {
            let first = SqlEditorViewModel(
                title: "Query 1",
                sqlText: SqlEditorViewModel.defaultStarterSql,
                isReadOnly: readOnlyDefault
            )
            bindTab(first)
            self.tabs = [first]
            self.activeTabID = first.id
        }
    }

    @discardableResult
    public func createTab(
        title: String? = nil,
        sqlText: String = "",
        select: Bool = true
    ) -> SqlEditorViewModel {
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tabTitle = (resolvedTitle?.isEmpty == false) ? resolvedTitle! : nextDefaultTabTitle()
        let tab = SqlEditorViewModel(
            title: tabTitle,
            sqlText: sqlText,
            isReadOnly: defaultReadOnly
        )
        bindTab(tab)
        tabs.append(tab)
        if select {
            activeTabID = tab.id
        }
        flushDrafts()
        return tab
    }

    public func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        flushDrafts()
    }

    public func beginRenaming(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = id
        renameDraft = tab.title
        renamingTabID = id
    }

    public func cancelRenaming() {
        renamingTabID = nil
        renameDraft = ""
    }

    public func renameTab(_ id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if renamingTabID == id {
            renamingTabID = nil
            renameDraft = ""
        }
        guard !trimmed.isEmpty, let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.title = trimmed
        flushDrafts()
    }

    public func requestCloseTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.isRunning || tab.transactionStatus != .idle {
            tabPendingClose = tab
            showingCloseTabConfirmation = true
        } else {
            Task { @MainActor in
                await closeTab(id)
            }
        }
    }

    public func confirmClosePendingTab() async {
        guard let tab = tabPendingClose else {
            showingCloseTabConfirmation = false
            return
        }
        tabPendingClose = nil
        showingCloseTabConfirmation = false
        await closeTab(tab.id)
    }

    public func cancelClosePendingTab() {
        tabPendingClose = nil
        showingCloseTabConfirmation = false
    }

    public func closeTab(_ id: UUID) async {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs[idx]
        await removed.cancelAndCloseSession()

        guard let currentIdx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: currentIdx)

        if tabs.isEmpty {
            let replacement = SqlEditorViewModel(
                title: "Query 1",
                sqlText: "",
                isReadOnly: defaultReadOnly
            )
            bindTab(replacement)
            tabs = [replacement]
            activeTabID = replacement.id
        } else if activeTabID == id {
            let nextIdx = min(currentIdx, tabs.count - 1)
            activeTabID = tabs[nextIdx].id
        }

        if renamingTabID == id {
            renamingTabID = nil
        }

        flushDrafts()
    }

    public func closeAllSessionsOnDisconnect() async {
        flushDrafts()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        let previousTabs = tabs
        for tab in previousTabs {
            await tab.cancelAndCloseSession()
        }

        currentProfileId = nil
        tabs = []
        activeTabID = nil
        tabPendingClose = nil
        showingCloseTabConfirmation = false
        renamingTabID = nil
    }

    public func setDraftPersistenceEnabled(_ enabled: Bool) throws {
        privacyPreferences.setSqlDraftPersistenceEnabled(enabled)
        if enabled {
            flushDrafts()
        } else {
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            try draftStore.deleteAllWorkspaces()
        }
    }

    public func clearSavedDrafts() throws {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        try draftStore.deleteAllWorkspaces()
    }

    public func flushDrafts() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        guard privacyPreferences.isSqlDraftPersistenceEnabled else { return }
        guard let profileId = currentProfileId, !tabs.isEmpty else { return }
        let snapshot = ProfileSqlWorkspaceSnapshot(
            profileId: profileId,
            activeTabId: activeTabID ?? tabs.first?.id,
            tabs: tabs.map { tab in
                SqlDraftTabSnapshot(
                    id: tab.id,
                    title: tab.title,
                    sqlText: tab.sqlText,
                    selectionLocation: max(0, tab.selectedRange.location),
                    selectionLength: max(0, tab.selectedRange.length),
                    isReadOnly: tab.isReadOnly
                )
            }
        )
        try? draftStore.saveWorkspace(snapshot)
    }

    private func scheduleSave() {
        guard privacyPreferences.isSqlDraftPersistenceEnabled else {
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            return
        }
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.flushDrafts()
        }
    }

    private func bindTab(_ tab: SqlEditorViewModel) {
        tab.onDraftChanged = { [weak self] in
            self?.scheduleSave()
        }
        tab.onReadOnlyChanged = { [weak self, weak tab] newValue in
            guard let self, let tab else { return }
            if self.activeTabID == tab.id {
                self.defaultReadOnly = newValue
                self.onReadOnlyChanged?(newValue)
            }
            self.flushDrafts()
        }
    }

    private func nextDefaultTabTitle() -> String {
        let existing = Set(tabs.map(\.title))
        var idx = max(1, tabs.count + 1)
        while existing.contains("Query \(idx)") {
            idx += 1
        }
        return "Query \(idx)"
    }
}
