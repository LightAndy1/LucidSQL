import Foundation
import Testing
@testable import LucidSQL
import LucidSQLBridge

@Suite("MVP Reliability & Security Regression Tests", .serialized)
struct MvpReliabilitySecurityTests {
    private func getLocalConfig() -> ConnectionConfig {
        ConnectionConfig(
            host: "localhost",
            port: 5432,
            database: "postgres",
            user: NSUserName(),
            password: nil,
            sslMode: "disable",
            sslRootCert: nil,
            timeoutSeconds: 5
        )
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LucidSQLReliabilityTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Legacy profiles decode without sslRootCert and invalid SSL modes reject without downgrade")
    func testConnectionProfileSslCompatibilityAndStrictModeValidation() async throws {
        // 1. Legacy JSON without sslRootCert must decode cleanly
        let legacyJson = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy Server",
            "host": "db.internal",
            "port": 5432,
            "database": "app",
            "user": "alice",
            "sslMode": "require",
            "timeoutSeconds": 10
        }
        """
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: Data(legacyJson.utf8))
        #expect(decoded.sslMode == "require")
        #expect(decoded.sslRootCert == nil)

        // 2. Empty or whitespace sslRootCert normalizes to nil in toRustConfig()
        let profileWithBlankCert = ConnectionProfile(
            name: "TLS Full",
            host: "localhost",
            sslMode: "verify-full",
            sslRootCert: "   \n "
        )
        let rustBlank = profileWithBlankCert.toRustConfig(password: nil)
        #expect(rustBlank.sslMode == "verify-full")
        #expect(rustBlank.sslRootCert == nil)

        // 3. Unsupported SSL mode across UniFFI fails explicitly (never falls back)
        let invalidCfg = ConnectionConfig(
            host: "localhost",
            port: 5432,
            database: "postgres",
            user: NSUserName(),
            password: nil,
            sslMode: "broken-mode",
            sslRootCert: nil,
            timeoutSeconds: 3
        )
        var didThrowConnectionFailed = false
        do {
            _ = try await test_database_connection(config: invalidCfg)
        } catch let err as LucidError {
            if case .ConnectionFailed = err {
                didThrowConnectionFailed = true
            }
        }
        #expect(didThrowConnectionFailed)
    }

    @Test("Disabling SQL draft persistence removes saved drafts and blocks writes while keeping in-memory editing")
    @MainActor
    func testDraftPrivacyDisableAndClearBehavior() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let draftURL = dir.appendingPathComponent("sql_drafts.json")
        let suiteName = "com.lucidsql.tests.privacy.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let draftStore = SqlDraftStore(fileURL: draftURL)
        let privacyPrefs = PrivacyPreferencesStore(userDefaults: userDefaults)
        #expect(privacyPrefs.isSqlDraftPersistenceEnabled == true)

        let profileId = UUID()
        let workspace = SqlWorkspaceViewModel(draftStore: draftStore, privacyPreferences: privacyPrefs)
        workspace.activate(profileId: profileId)
        workspace.tabs[0].sqlText = "SELECT 'top-secret-token-123';"
        workspace.flushDrafts()
        #expect(FileManager.default.fileExists(atPath: draftURL.path))

        // Disable persistence: must remove file from disk AND keep in-memory SQL editing intact
        try workspace.setDraftPersistenceEnabled(false)
        #expect(privacyPrefs.isSqlDraftPersistenceEnabled == false)
        #expect(!FileManager.default.fileExists(atPath: draftURL.path))
        #expect(workspace.tabs[0].sqlText == "SELECT 'top-secret-token-123';")

        // Further edits, tab creation, rename, and disconnect flush must NOT recreate sql_drafts.json
        let second = workspace.createTab(title: "Secret Tab")
        second.sqlText = "SELECT 'another-secret';"
        workspace.renameTab(second.id, to: "Renamed Secret")
        workspace.flushDrafts()
        await workspace.closeAllSessionsOnDisconnect()
        #expect(!FileManager.default.fileExists(atPath: draftURL.path))

        // Restarting / re-activating while disabled must not load stale drafts
        let restarted = SqlWorkspaceViewModel(draftStore: draftStore, privacyPreferences: privacyPrefs)
        restarted.activate(profileId: profileId)
        #expect(restarted.tabs.count == 1)
        #expect(!restarted.tabs[0].sqlText.contains("top-secret-token-123"))

        // Re-enable persistence, save a draft, then verify confirmed Clear Saved Drafts removes file cleanly
        try restarted.setDraftPersistenceEnabled(true)
        restarted.tabs[0].sqlText = "SELECT 42;"
        restarted.flushDrafts()
        #expect(FileManager.default.fileExists(atPath: draftURL.path))

        try restarted.clearSavedDrafts()
        #expect(!FileManager.default.fileExists(atPath: draftURL.path))
        #expect(restarted.tabs[0].sqlText == "SELECT 42;")
    }

    @Test("Workspace lifecycle coordinates staged edits, SQL transactions, active exports, and bounded teardown")
    @MainActor
    func testWorkspaceLifecycleCoordinationAndBoundedTeardown() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteName = "com.lucidsql.tests.lifecycle.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let privacyPrefs = PrivacyPreferencesStore(userDefaults: userDefaults)
        privacyPrefs.setSqlDraftPersistenceEnabled(false)

        let model = WorkspaceModel(
            profileStore: ConnectionProfileStore(fileURL: dir.appendingPathComponent("profiles.json")),
            draftStore: SqlDraftStore(fileURL: dir.appendingPathComponent("sql_drafts.json")),
            privacyPreferences: privacyPrefs
        )
        model.sweepGlobalSessionsOnDisconnect = false

        let profile = ConnectionProfile(name: "Local Test", host: "localhost", port: 5432, database: "postgres", user: NSUserName(), sslMode: "disable")
        model.connect(profile: profile, password: nil)

        // Populate TableDataViewModel with editable row + staged edit + simulated active export + SQL transaction
        model.tableViewModel.currentSchema = "public"
        model.tableViewModel.currentTable = "items"
        model.tableViewModel.columns = [
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "name", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
        ]
        model.tableViewModel.rows = [
            RowData(cells: [.text("100"), .integer(1), .text("alpha")])
        ]
        model.tableViewModel.stageTextEdit(row: 0, column: 1, text: "beta")

        let exportVM = CsvExportViewModel(
            target: .tableData(
                config: getLocalConfig(),
                schema: "public",
                table: "items",
                columns: model.tableViewModel.columns,
                fetchedRows: model.tableViewModel.rows,
                offset: 0,
                hasPrimaryKey: true,
                sortCol: nil,
                sortDesc: false,
                pendingChangesCount: 1,
                stagedSummary: "1 edit"
            )
        )
        exportVM.isExporting = true
        model.tableViewModel.exportViewModel = exportVM

        model.sqlWorkspace.activeTab?.transactionStatus = .inTransaction
        model.currentMode = .sqlEditor

        // Single coordinated lifecycle summary across all active work even while in SQL mode
        let summary = model.lifecycleSummary
        #expect(!summary.isEmpty)
        #expect(summary.pendingTableChangesCount == 1)
        #expect(summary.activeExportsCount == 1)
        #expect(summary.activeSqlTabDetails.count == 1)

        let warningText = model.formattedLifecycleWarning(actionVerb: "disconnect")
        #expect(warningText.contains("staged change"))
        #expect(warningText.contains("CSV export"))
        #expect(warningText.contains("uncommitted transaction"))
        #expect(warningText.contains("draft saving is disabled"))

        // Navigation from SQL mode while table has staged edits must trigger WorkspaceView's alert (not hidden TableDataContainerView)
        await model.loadTable(schema: "public", table: "other_table")
        #expect(model.showingTableNavigationAlert == true)
        model.cancelTableNavigation()
        #expect(model.showingTableNavigationAlert == false)

        // Disconnect prompts once on WorkspaceModel
        model.disconnect()
        #expect(model.showingDisconnectSessionWarning == true)

        // Bounded teardown finishes well within budget
        let start = Date()
        await model.performConfirmedDisconnect()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 3.0)
        #expect(model.activeConfig == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sql_drafts.json").path))
    }

    @Test("UncertainCommitOutcome blocks blind re-apply and offers explicit Reload & Reconcile")
    @MainActor
    func testUncertainCommitBlocksReapplyUntilReconciled() async throws {
        let config = getLocalConfig()
        let schema = "lucidsql_reconcile_\(UInt32.random(in: 10000...99999))"

        do {
            _ = try await execute_session_query(
                config: config,
                sessionId: "reconcile-setup-\(schema)",
                sql: "CREATE SCHEMA \(schema); CREATE TABLE \(schema).orders (id serial PRIMARY KEY, note text NOT NULL);",
                queryId: "q-setup",
                maxRows: nil,
                readOnly: false
            )
            _ = try await execute_session_query(
                config: config,
                sessionId: "reconcile-setup-\(schema)",
                sql: "INSERT INTO \(schema).orders (note) VALUES ('initial');",
                queryId: "q-seed",
                maxRows: nil,
                readOnly: false
            )
        } catch {
            return
        }

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: schema, table: "orders")
        #expect(vm.rows.count == 1)

        vm.stageTextEdit(row: 0, column: 1, text: "edited")
        #expect(vm.hasPendingChanges)

        // Simulate UncertainCommitOutcome state
        vm.recordUncertainCommitOutcome(message: "connection closed while waiting for COMMIT response")
        #expect(vm.hasUncertainCommitOutcome == true)
        #expect(vm.isEditable == false)
        #expect(vm.errorMessage?.contains("Do not blindly re-apply") == true)

        // Attempting applyStagedEdits must refuse blind re-apply cleanly and leave DB unchanged
        await vm.applyStagedEdits(config: config)
        #expect(vm.errorMessage?.contains("blind re-apply is blocked") == true)

        // Explicit Reload & Reconcile clears uncertain lock and refreshes live DB row
        await vm.reconcileUncertainCommit(config: config)
        #expect(vm.hasUncertainCommitOutcome == false)
        #expect(!vm.hasPendingChanges)
        #expect(vm.isEditable == true)
        #expect(vm.rows.count == 1)
        #expect(vm.rows[0].cells[2].displayString == "initial")
        #expect(vm.statusMessage?.contains("reconcile") == true)

        _ = try? await execute_session_query(
            config: config,
            sessionId: "reconcile-setup-\(schema)",
            sql: "DROP SCHEMA IF EXISTS \(schema) CASCADE;",
            queryId: "q-drop",
            maxRows: nil,
            readOnly: false
        )
        try? await close_session(sessionId: "reconcile-setup-\(schema)")
    }
}
