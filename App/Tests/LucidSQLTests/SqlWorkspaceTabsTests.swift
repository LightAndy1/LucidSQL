import Foundation
import Testing
@testable import LucidSQL
import LucidSQLBridge

@Suite("SQL Multi-Tab Workspace & Draft Persistence Tests", .serialized)
struct SqlWorkspaceTabsTests {
    private func getLocalConfig() -> ConnectionConfig {
        ConnectionConfig(
            host: "localhost",
            port: 5432,
            database: "postgres",
            user: NSUserName(),
            password: nil,
            sslMode: "disable",
            timeoutSeconds: 5
        )
    }

    private func makeTempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LucidSQLTests_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    @Test("Draft persistence across simulated restarts stores zero passwords/results and handles missing/deleted profiles")
    @MainActor
    func testDraftPersistenceAcrossRestartsAndProfileIsolation() async throws {
        let draftURL = makeTempURL("sql_drafts.json")
        let profileURL = makeTempURL("profiles.json")
        defer {
            try? FileManager.default.removeItem(at: draftURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent())
        }

        let draftStore = SqlDraftStore(fileURL: draftURL)
        let profileStore = ConnectionProfileStore(fileURL: profileURL)

        let profileA = ConnectionProfile(
            name: "Primary Dev",
            host: "localhost",
            port: 5432,
            database: "postgres",
            user: NSUserName()
        )
        let profileB = ConnectionProfile(
            name: "Analytics Mirror",
            host: "analytics.internal",
            port: 5433,
            database: "metrics",
            user: "analyst"
        )
        try profileStore.saveOrUpdateProfile(profileA)
        try profileStore.saveOrUpdateProfile(profileB)

        // Launch 1 on Profile A: create custom tabs, rename, set SQL & cursor selection
        let ws1 = SqlWorkspaceViewModel(draftStore: draftStore)
        ws1.activate(profileId: profileA.id)
        #expect(ws1.tabs.count == 1)
        #expect(ws1.activeSessionsInTabsCount == 0)

        let tab1 = ws1.tabs[0]
        ws1.renameTab(tab1.id, to: "Orders Check")
        tab1.sqlText = "SELECT 1 AS a;\nSELECT 2 AS b;"
        tab1.selectedRange = NSRange(location: 15, length: 14)

        let tab2 = ws1.createTab(title: "Temp Scratch", sqlText: "CREATE TEMP TABLE t1 (id int);")
        ws1.selectTab(tab2.id)
        ws1.flushDrafts()

        // Profile B gets its own independent drafts
        let wsB = SqlWorkspaceViewModel(draftStore: draftStore)
        wsB.activate(profileId: profileB.id)
        wsB.tabs[0].sqlText = "SELECT count(*) FROM events;"
        wsB.flushDrafts()

        // Confirm lazy behavior: neither tab opened a dedicated PG session
        #expect((try? await get_session_info(sessionId: tab1.sessionId)) == nil)
        #expect((try? await get_session_info(sessionId: tab2.sessionId)) == nil)
        #expect((try? await get_session_info(sessionId: wsB.tabs[0].sessionId)) == nil)

        // Ensure JSON files never contain passwords or query results
        let draftsRaw = try String(contentsOf: draftURL, encoding: .utf8)
        let profilesRaw = try String(contentsOf: profileURL, encoding: .utf8)
        #expect(!draftsRaw.localizedCaseInsensitiveContains("password"))
        #expect(!draftsRaw.localizedCaseInsensitiveContains("rows"))
        #expect(!profilesRaw.localizedCaseInsensitiveContains("password"))

        // Simulated restart (fresh store + fresh ViewModel for Profile A)
        let reopenedStore = SqlDraftStore(fileURL: draftURL)
        let wsRestarted = SqlWorkspaceViewModel(draftStore: reopenedStore)
        wsRestarted.activate(profileId: profileA.id)

        #expect(wsRestarted.tabs.count == 2)
        #expect(wsRestarted.activeTabID == tab2.id)
        #expect(wsRestarted.tabs[0].title == "Orders Check")
        #expect(wsRestarted.tabs[0].sqlText == "SELECT 1 AS a;\nSELECT 2 AS b;")
        #expect(wsRestarted.tabs[0].selectedRange == NSRange(location: 15, length: 14))
        #expect(wsRestarted.tabs[1].title == "Temp Scratch")
        #expect(wsRestarted.tabs[1].sqlText == "CREATE TEMP TABLE t1 (id int);")

        // Restored drafts MUST remain lazy and never auto-execute
        #expect(wsRestarted.activeSessionsInTabsCount == 0)
        #expect(wsRestarted.tabs[0].hasActiveSession == false)
        #expect(wsRestarted.tabs[1].hasActiveSession == false)
        #expect((try? await get_session_info(sessionId: wsRestarted.tabs[0].sessionId)) == nil)
        #expect((try? await get_session_info(sessionId: wsRestarted.tabs[1].sessionId)) == nil)
        #expect(wsRestarted.tabs[0].queryState == .idle)
        #expect(wsRestarted.tabs[1].queryState == .idle)
        #expect(wsRestarted.tabs[0].sessionBannerMessage != nil)

        // Missing profile degrades cleanly without leaking Profile A or B drafts
        let missingProfileId = UUID()
        #expect(reopenedStore.loadWorkspace(for: missingProfileId) == nil)
        let wsMissing = SqlWorkspaceViewModel(draftStore: reopenedStore)
        wsMissing.activate(profileId: missingProfileId)
        #expect(wsMissing.tabs.count == 1)
        #expect(wsMissing.tabs[0].sqlText == SqlEditorViewModel.defaultStarterSql)

        // Deleting Profile B cleans up its drafts while keeping Profile A intact
        try profileStore.deleteProfile(id: profileB.id, draftStore: reopenedStore)
        #expect(reopenedStore.loadWorkspace(for: profileB.id) == nil)
        #expect(reopenedStore.loadWorkspace(for: profileA.id) != nil)

        // Corrupt JSON handling degrades gracefully
        try "{not-valid-json".write(to: draftURL, atomically: true, encoding: .utf8)
        #expect(reopenedStore.loadWorkspace(for: profileA.id) == nil)
    }

    @Test("Independent SET/temp-table/transaction state across two tabs and switching preserves running queries and results")
    @MainActor
    func testIndependentSessionsAndTabSwitchingIsolation() async throws {
        let config = getLocalConfig()
        let draftStore = SqlDraftStore(fileURL: makeTempURL("drafts.json"))
        let ws = SqlWorkspaceViewModel(draftStore: draftStore)
        ws.activate(profileId: UUID())

        let tab1 = ws.tabs[0]
        let tab2 = ws.createTab(title: "Tab 2", sqlText: "")
        #expect(ws.activeSessionsInTabsCount == 0)

        // Setup isolated state in Tab 1
        ws.selectTab(tab1.id)
        tab1.sqlText = "SET TIME ZONE 'UTC'; CREATE TEMP TABLE t_tab_scope (tag text); INSERT INTO t_tab_scope VALUES ('from_tab_1'); BEGIN;"
        tab1.executeQuery(config: config)
        try await waitUntilIdle(tab1)

        // Switch to Tab 2 and setup completely different state
        ws.selectTab(tab2.id)
        tab2.sqlText = "SET TIME ZONE 'America/New_York'; CREATE TEMP TABLE t_tab_scope (tag text); INSERT INTO t_tab_scope VALUES ('from_tab_2');"
        tab2.executeQuery(config: config)
        try await waitUntilIdle(tab2)

        let info1 = try await get_session_info(sessionId: tab1.sessionId)
        let info2 = try await get_session_info(sessionId: tab2.sessionId)
        #expect(info1.backendPid != info2.backendPid)
        #expect(tab1.transactionStatus == .inTransaction)
        #expect(tab2.transactionStatus == .idle)

        // Query Tab 1 and verify UTC + temp table contents preserved after switching tabs
        ws.selectTab(tab1.id)
        tab1.sqlText = "SELECT current_setting('TIMEZONE'), (SELECT tag FROM t_tab_scope);"
        tab1.executeQuery(config: config)
        try await waitUntilIdle(tab1)

        guard case .success(let res1) = tab1.queryState else {
            Issue.record("Expected Tab 1 query success, got \(tab1.queryState)")
            return
        }
        #expect(res1.rows[0].cells[0] == .text("UTC"))
        #expect(res1.rows[0].cells[1] == .text("from_tab_1"))
        #expect(tab1.transactionStatus == .inTransaction)

        // Switching to Tab 1 while Tab 2 executes must not cancel or clear Tab 2
        ws.selectTab(tab2.id)
        tab2.sqlText = "SELECT current_setting('TIMEZONE'), (SELECT tag FROM t_tab_scope);"
        tab2.executeQuery(config: config)
        ws.selectTab(tab1.id)
        try await waitUntilIdle(tab2)

        guard case .success(let res2) = tab2.queryState else {
            Issue.record("Expected Tab 2 query success after switching away, got \(tab2.queryState)")
            return
        }
        #expect(res2.rows[0].cells[0] == .text("America/New_York"))
        #expect(res2.rows[0].cells[1] == .text("from_tab_2"))

        // Clean rollback & session close
        await ws.closeAllSessionsOnDisconnect()
    }

    @Test("Cancelling one tab targets only that tab while another tab completes normally")
    @MainActor
    func testTargetedTabCancellationIsolation() async throws {
        let config = getLocalConfig()
        let draftStore = SqlDraftStore(fileURL: makeTempURL("drafts.json"))
        let ws = SqlWorkspaceViewModel(draftStore: draftStore)
        ws.activate(profileId: UUID())

        let tab1 = ws.tabs[0]
        let tab2 = ws.createTab(title: "Fast & Parallel")

        tab1.sqlText = "SELECT pg_sleep(4);"
        tab1.executeQuery(config: config)

        // Switch immediately to Tab 2 while Tab 1 runs and start a second concurrent query
        ws.selectTab(tab2.id)
        tab2.sqlText = "SELECT pg_sleep(0.5), 123 AS val;"
        tab2.executeQuery(config: config)

        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(tab1.isRunning == true)
        #expect(tab2.isRunning == true)

        // Cancel ONLY Tab 1
        tab1.cancelQuery()
        #expect(tab1.isRunning == false)
        #expect(tab2.isRunning == true)

        try await waitUntilIdle(tab2, timeoutNs: 5_000_000_000)
        guard case .success(let res2) = tab2.queryState else {
            Issue.record("Tab 2 should finish undisturbed when Tab 1 is cancelled; got \(tab2.queryState)")
            return
        }
        #expect(res2.rows[0].cells[1] == .integer(123))

        await ws.closeAllSessionsOnDisconnect()
    }

    @Test("Closing running or open-transaction tab prompts confirmation and rolls back on confirm")
    @MainActor
    func testCloseConfirmationRollbackAndCleanup() async throws {
        let config = getLocalConfig()
        let tableName = "lucidsql_tab_close_tx_\(Int.random(in: 1000...99999))"
        _ = try await execute_query(
            config: config,
            sql: "CREATE TABLE \(tableName) (id int primary key);",
            queryId: UUID().uuidString
        )

        let draftStore = SqlDraftStore(fileURL: makeTempURL("drafts.json"))
        let ws = SqlWorkspaceViewModel(draftStore: draftStore)
        ws.activate(profileId: UUID())
        let tab1 = ws.tabs[0]
        _ = ws.createTab(title: "Safe Tab")

        tab1.sqlText = "BEGIN; INSERT INTO \(tableName) VALUES (777);"
        tab1.executeQuery(config: config)
        try await waitUntilIdle(tab1)
        #expect(tab1.transactionStatus == .inTransaction)

        // Attempting to close Tab 1 must require confirmation
        ws.requestCloseTab(tab1.id)
        #expect(ws.showingCloseTabConfirmation == true)
        #expect(ws.tabPendingClose?.id == tab1.id)
        #expect(ws.tabs.count == 2)

        // Cancelling keeps tab and transaction intact
        ws.cancelClosePendingTab()
        #expect(ws.showingCloseTabConfirmation == false)
        #expect(tab1.transactionStatus == .inTransaction)

        // Confirming closes session and rolls back uncommitted row 777
        ws.requestCloseTab(tab1.id)
        #expect(ws.showingCloseTabConfirmation == true)
        await ws.confirmClosePendingTab()
        #expect(ws.tabs.count == 1)

        let check = try await execute_query(
            config: config,
            sql: "SELECT count(*) FROM \(tableName);",
            queryId: UUID().uuidString
        )
        #expect(check.rows[0].cells[0] == .integer(0))

        _ = try? await execute_query(
            config: config,
            sql: "DROP TABLE IF EXISTS \(tableName);",
            queryId: UUID().uuidString
        )
        await ws.closeAllSessionsOnDisconnect()
    }

    @Test("Disconnect confirmation, session release, explicit connection loss, and draft restore without auto-exec")
    @MainActor
    func testDisconnectAndConnectionLossExplicitHandling() async throws {
        let draftURL = makeTempURL("ws_drafts.json")
        let profileURL = makeTempURL("ws_profiles.json")
        defer {
            try? FileManager.default.removeItem(at: draftURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: profileURL.deletingLastPathComponent())
        }

        let profileStore = ConnectionProfileStore(fileURL: profileURL)
        let draftStore = SqlDraftStore(fileURL: draftURL)
        let workspaceModel = WorkspaceModel(profileStore: profileStore, draftStore: draftStore)

        let profile = ConnectionProfile(
            name: "Local Test",
            host: "localhost",
            port: 5432,
            database: "postgres",
            user: NSUserName()
        )
        workspaceModel.connect(profile: profile, password: nil)

        guard let tab = workspaceModel.sqlWorkspace.activeTab else {
            Issue.record("Missing initial active tab")
            return
        }
        let config = profile.toRustConfig(password: nil)
        tab.sqlText = "CREATE TEMP TABLE t_lost (x int); BEGIN;"
        tab.executeQuery(config: config)
        try await waitUntilIdle(tab)
        #expect(tab.hasActiveSession == true)
        #expect(tab.transactionStatus == .inTransaction)

        // Simulate external server termination of this tab's backend PID
        let info = try await get_session_info(sessionId: tab.sessionId)
        _ = try await execute_query(
            config: config,
            sql: "SELECT pg_terminate_backend(\(info.backendPid));",
            queryId: UUID().uuidString
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        tab.sqlText = "SELECT 1;"
        tab.executeQuery(config: config)
        try await waitUntilIdle(tab)
        #expect(tab.hasActiveSession == false)
        #expect(tab.transactionStatus == .idle)
        #expect(tab.sessionBannerMessage != nil)
        if case .error(let errMsg) = tab.queryState {
            #expect(errMsg.lowercased().contains("lost") || errMsg.lowercased().contains("closed"))
        } else {
            Issue.record("Expected explicit connection loss error, got \(tab.queryState)")
        }

        // Open transaction on new session triggers disconnect confirmation
        tab.sqlText = "BEGIN; SELECT 42;"
        tab.executeQuery(config: config)
        try await waitUntilIdle(tab)
        #expect(tab.transactionStatus == .inTransaction)

        workspaceModel.disconnect()
        #expect(workspaceModel.showingDisconnectSessionWarning == true)
        #expect(workspaceModel.activeConfig != nil)

        await workspaceModel.performConfirmedDisconnect()
        #expect(workspaceModel.activeConfig == nil)
        #expect(workspaceModel.sqlWorkspace.tabs.isEmpty)

        // Reconnect: draft is restored lazily with explicit warning banner and zero active queries
        workspaceModel.connect(profile: profile, password: nil)
        #expect(workspaceModel.sqlWorkspace.tabs.count == 1)
        #expect(workspaceModel.sqlWorkspace.tabs[0].sqlText == "BEGIN; SELECT 42;")
        #expect(workspaceModel.sqlWorkspace.tabs[0].hasActiveSession == false)
        #expect(workspaceModel.sqlWorkspace.tabs[0].transactionStatus == .idle)
        #expect(workspaceModel.sqlWorkspace.tabs[0].queryState == .idle)
        #expect(workspaceModel.sqlWorkspace.tabs[0].sessionBannerMessage != nil)

        await workspaceModel.performConfirmedDisconnect()
    }

    @MainActor
    private func waitUntilIdle(_ tab: SqlEditorViewModel, timeoutNs: UInt64 = 5_000_000_000) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while tab.isRunning {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNs {
                Issue.record("Timed out waiting for tab query completion")
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}
