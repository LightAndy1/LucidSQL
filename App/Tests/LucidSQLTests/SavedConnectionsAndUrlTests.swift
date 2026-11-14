import Foundation
import Testing
@testable import LucidSQL
import LucidSQLBridge

private final class InMemoryPasswordStore: PasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]
    private(set) var hasStoredCalls: Int = 0
    private(set) var secretLookupCalls: Int = 0
    private(set) var saveCalls: Int = 0
    private(set) var deleteCalls: Int = 0
    var simulateAccessDenied: Bool = false

    func resetCounters() {
        lock.lock()
        defer { lock.unlock() }
        hasStoredCalls = 0
        secretLookupCalls = 0
        saveCalls = 0
        deleteCalls = 0
    }

    func savePassword(profileId: UUID, password: String) throws {
        lock.lock()
        defer { lock.unlock() }
        saveCalls += 1
        storage[profileId] = password
    }

    func hasStoredPassword(profileId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        hasStoredCalls += 1
        return storage[profileId]?.isEmpty == false
    }

    func lookupPassword(profileId: UUID) -> PasswordLookupResult {
        lock.lock()
        defer { lock.unlock() }
        secretLookupCalls += 1
        if simulateAccessDenied {
            return .accessDenied
        }
        if let value = storage[profileId], !value.isEmpty {
            return .found(value)
        }
        return .notFound
    }

    func getPassword(profileId: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        secretLookupCalls += 1
        if simulateAccessDenied {
            throw KeychainService.KeychainError.secError(errSecUserCanceled)
        }
        return storage[profileId]
    }

    func deletePassword(profileId: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        deleteCalls += 1
        storage.removeValue(forKey: profileId)
    }

    var allStoredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var counts: (hasStored: Int, secretLookup: Int, save: Int, delete: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hasStoredCalls, secretLookupCalls, saveCalls, deleteCalls)
    }
}

@Suite("Saved Connections, URL Import & Switching Safeguards", .serialized)
struct SavedConnectionsAndUrlTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LucidSQLConnectionsTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("PostgresUrlParser handles schemes, percent-encoding, IPv6, TLS options, and rejects unsafe/unsupported inputs")
    func testPostgresUrlParserCases() throws {
        // 1. postgres:// with percent-encoded user/pass/db and TLS verify-full + sslrootcert + connect_timeout
        let full = try PostgresUrlParser.parse(
            "postgres://app%2Euser:p%40ss%3Aw%2Ford%231@db.example.com:5433/prod%5Fdb?sslmode=verify-full&sslrootcert=%2Fetc%2Fssl%2Fca.pem&connect_timeout=25"
        )
        #expect(full.host == "db.example.com")
        #expect(full.port == 5433)
        #expect(full.user == "app.user")
        #expect(full.password == "p@ss:w/ord#1")
        #expect(full.database == "prod_db")
        #expect(full.sslMode == "verify-full")
        #expect(full.sslRootCert == "/etc/ssl/ca.pem")
        #expect(full.timeoutSeconds == 25)

        // 2. postgresql:// with bracketed IPv6 + sslrootcert=system + defaults
        let ipv6 = try PostgresUrlParser.parse("postgresql://alice@[2001:db8::1]:5439/analytics?sslmode=verify-ca&sslrootcert=system")
        #expect(ipv6.host == "2001:db8::1")
        #expect(ipv6.port == 5439)
        #expect(ipv6.user == "alice")
        #expect(ipv6.password == nil)
        #expect(ipv6.database == "analytics")
        #expect(ipv6.sslMode == "verify-ca")
        #expect(ipv6.sslRootCert == nil)

        let ipv6DefaultPort = try PostgresUrlParser.parse("postgres://[::1]")
        #expect(ipv6DefaultPort.host == "::1")
        #expect(ipv6DefaultPort.port == 5432)
        #expect(ipv6DefaultPort.database == "postgres")
        #expect(ipv6DefaultPort.user == "postgres")

        // 3. Reject malformed URLs, multi-host, unsupported params, unsupported sslmode, without echoing secrets
        let secretToken = "SuperSecretToken999"
        let rejectedInputs: [String] = [
            "",
            "mysql://user:\(secretToken)@localhost:3306/db",
            "localhost:5432/postgres",
            "postgres://user:\(secretToken)@host1:5432,host2:5433/db",
            "postgres://user:\(secretToken)@host1/db?host=host1,host2",
            "postgres://user:\(secretToken)@::1:5432/db",
            "postgres://[::1",
            "postgres:///local_socket_db",
            "postgres://user:pa@ss@localhost:5432/db",
            "postgres://user:\(secretToken)@localhost:99999/db",
            "postgres://user:\(secretToken)@localhost/db?sslmode=allow",
            "postgres://user:\(secretToken)@localhost/db?sslmode=disable&sslrootcert=/ca.crt",
            "postgres://user:\(secretToken)@localhost/db?target_session_attrs=read-write&application_name=cli",
            "postgres://user:\(secretToken)@localhost/db#frag",
            "postgres://user:bad%ZZpass@localhost/db",
        ]

        for input in rejectedInputs {
            do {
                _ = try PostgresUrlParser.parse(input)
                Issue.record("Expected PostgresUrlParser to reject: \(input)")
            } catch {
                let message = error.localizedDescription
                #expect(!message.isEmpty)
                #expect(!message.contains(secretToken))
            }
        }
    }

    @Test("Saved profile CRUD preserves stable IDs, SQL draft associations, Remember Password policy, and launch selection")
    @MainActor
    func testSavedProfileLifecycleAndKeychainPolicy() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let profilesURL = dir.appendingPathComponent("profiles.json")
        let draftsURL = dir.appendingPathComponent("sql_drafts.json")
        let profileStore = ConnectionProfileStore(fileURL: profilesURL)
        let draftStore = SqlDraftStore(fileURL: draftsURL)
        let passwordStore = InMemoryPasswordStore()

        // 1. Create via ConnectionDialogModel with URL import & verify URI clears cleanly and password isn't written to profiles.json
        let initialDraft = ConnectionProfile(name: "Local PostgreSQL")
        let dialogModel = ConnectionDialogModel(
            profile: initialDraft,
            profileStore: profileStore,
            draftStore: draftStore,
            passwordStore: passwordStore
        )
        dialogModel.connectionUrlInput = "postgresql://svc_user:s3cr3t%21@127.0.0.1:5439/app_db?sslmode=require"
        dialogModel.importConnectionUrl()
        #expect(dialogModel.connectionUrlInput.isEmpty)
        #expect(dialogModel.urlImportIsError == false)
        #expect(dialogModel.host == "127.0.0.1")
        #expect(dialogModel.port == "5439")
        #expect(dialogModel.database == "app_db")
        #expect(dialogModel.user == "svc_user")
        #expect(dialogModel.password == "s3cr3t!")
        #expect(dialogModel.sslMode == "require")

        let savedProfile = dialogModel.persistCurrentProfile(markAsConnected: true)
        #expect(savedProfile.id == initialDraft.id)
        #expect(try passwordStore.getPassword(profileId: savedProfile.id) == "s3cr3t!")

        let profilesJson = try String(contentsOf: profilesURL, encoding: .utf8)
        #expect(!profilesJson.contains("s3cr3t!"))
        #expect(!profilesJson.contains("postgresql://"))

        // Attach a SQL draft to this profile ID
        let sqlWorkspace = SqlWorkspaceViewModel(draftStore: draftStore)
        sqlWorkspace.activate(profileId: savedProfile.id)
        sqlWorkspace.tabs[0].sqlText = "SELECT 'keep-my-draft';"
        sqlWorkspace.flushDrafts()

        // 2. Edit host, user, database and disable Remember Password -> preserves UUID & draft workspace and deletes stored password
        dialogModel.selectSavedProfile(savedProfile.id)
        dialogModel.host = "pg.internal"
        dialogModel.database = "app_db_v2"
        dialogModel.user = "rotated_user"
        dialogModel.rememberPassword = false
        dialogModel.password = "ephemeral-only"
        let updatedProfile = dialogModel.persistCurrentProfile(markAsConnected: false)
        #expect(updatedProfile.id == savedProfile.id)
        #expect(updatedProfile.rememberPassword == false)
        #expect(try passwordStore.getPassword(profileId: savedProfile.id) == nil)
        #expect(draftStore.loadWorkspace(for: updatedProfile.id)?.tabs.first?.sqlText == "SELECT 'keep-my-draft';")

        // 3. Duplicate creates distinct ID without sharing draft association
        dialogModel.duplicateProfile(updatedProfile.id)
        #expect(dialogModel.savedProfiles.count == 2)
        let copyId = try #require(dialogModel.selectedSidebarProfileId)
        #expect(copyId != updatedProfile.id)
        #expect(draftStore.loadWorkspace(for: copyId) == nil)

        // 4. Launch restoration selects last selected profile without auto-connecting or running queries
        let relaunchedWorkspace = WorkspaceModel(
            profileStore: profileStore,
            draftStore: draftStore,
            passwordStore: passwordStore
        )
        #expect(relaunchedWorkspace.savedProfiles.count == 2)
        #expect(relaunchedWorkspace.selectedProfileId == copyId)
        #expect(relaunchedWorkspace.activeConfig == nil)
        #expect(relaunchedWorkspace.activeProfile == nil)

        // 5. Delete original profile removes profile, Keychain entry, and its SQL draft
        try profileStore.deleteProfile(id: updatedProfile.id, draftStore: draftStore, passwordStore: passwordStore)
        #expect(profileStore.profile(for: updatedProfile.id) == nil)
        #expect(draftStore.loadWorkspace(for: updatedProfile.id) == nil)
    }

    @Test("Switching connections preserves active-session and pending-edit safeguards")
    @MainActor
    func testSwitchingConnectionsSafeguard() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteName = "com.lucidsql.tests.switch.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let privacy = PrivacyPreferencesStore(userDefaults: userDefaults)
        privacy.setSqlDraftPersistenceEnabled(false)

        let model = WorkspaceModel(
            profileStore: ConnectionProfileStore(fileURL: dir.appendingPathComponent("profiles.json")),
            draftStore: SqlDraftStore(fileURL: dir.appendingPathComponent("sql_drafts.json")),
            passwordStore: InMemoryPasswordStore(),
            privacyPreferences: privacy
        )
        model.sweepGlobalSessionsOnDisconnect = false

        let profileA = ConnectionProfile(name: "Server A", host: "localhost", port: 5432, database: "db_a", user: "alice")
        let profileB = ConnectionProfile(name: "Server B", host: "localhost", port: 5433, database: "db_b", user: "bob")

        model.requestConnection(profileA, password: nil)
        #expect(model.activeProfile?.id == profileA.id)

        // Dirty staged table edit + uncommitted SQL transaction
        model.tableViewModel.currentSchema = "public"
        model.tableViewModel.currentTable = "items"
        model.tableViewModel.columns = [
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "label", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
        ]
        model.tableViewModel.rows = [RowData(cells: [.text("1"), .integer(1), .text("orig")])]
        model.tableViewModel.stageTextEdit(row: 0, column: 1, text: "modified")
        model.sqlWorkspace.activeTab?.transactionStatus = .inTransaction

        // Attempting to switch must pause behind confirmation alert
        model.requestConnection(profileB, password: "pwB")
        #expect(model.showingSwitchConnectionAlert == true)
        #expect(model.activeProfile?.id == profileA.id)
        #expect(model.switchConnectionWarningMessage.contains("switch connections"))

        // Cancel preserves connection A & staged work
        model.cancelConnectionSwitch()
        #expect(model.showingSwitchConnectionAlert == false)
        #expect(model.activeProfile?.id == profileA.id)
        #expect(model.tableViewModel.hasPendingChanges == true)

        // Confirm cleans up and switches to B
        model.requestConnection(profileB, password: "pwB")
        #expect(model.showingSwitchConnectionAlert == true)
        await model.performConfirmedConnectionSwitch(to: profileB, password: "pwB")
        #expect(model.activeProfile?.id == profileB.id)
        #expect(model.activeConfig?.database == "db_b")
        #expect(model.tableViewModel.hasPendingChanges == false)
    }

    @Test("Connection URL Paste button reads clipboard only on click, clears URI, never auto-connects/saves, and handles invalid/empty safely")
    @MainActor
    func testConnectionUrlPasteButtonBehavior() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let profilesURL = dir.appendingPathComponent("profiles.json")
        let profileStore = ConnectionProfileStore(fileURL: profilesURL)
        let draftStore = SqlDraftStore(fileURL: dir.appendingPathComponent("drafts.json"))
        let passwordStore = InMemoryPasswordStore()

        var clipboardValue: String? = "postgresql://paste_user:MySecretPw%21@db.paste.internal:5438/analytics?sslmode=verify-full"
        var readCount = 0

        let dialogModel = ConnectionDialogModel(
            profile: ConnectionProfile(name: "Local PostgreSQL"),
            profileStore: profileStore,
            draftStore: draftStore,
            passwordStore: passwordStore,
            clipboardReader: {
                readCount += 1
                return clipboardValue
            }
        )

        // Clipboard must NOT be read on initialization
        #expect(readCount == 0)

        // Clicking Paste reads clipboard once, populates fields, clears URI, and does NOT save or connect
        dialogModel.pasteAndImportConnectionUrl()
        #expect(readCount == 1)
        #expect(dialogModel.urlImportIsError == false)
        #expect(dialogModel.connectionUrlInput.isEmpty)
        #expect(dialogModel.host == "db.paste.internal")
        #expect(dialogModel.port == "5438")
        #expect(dialogModel.database == "analytics")
        #expect(dialogModel.user == "paste_user")
        #expect(dialogModel.password == "MySecretPw!")
        #expect(dialogModel.sslMode == "verify-full")
        #expect(profileStore.loadProfiles().isEmpty)
        #expect(passwordStore.allStoredCount == 0)

        // Empty clipboard gives concise feedback and preserves existing fields
        clipboardValue = "   \n  "
        dialogModel.pasteAndImportConnectionUrl()
        #expect(readCount == 2)
        #expect(dialogModel.urlImportIsError == true)
        #expect(dialogModel.urlImportMessage == "Clipboard is empty.")
        #expect(dialogModel.host == "db.paste.internal")
        #expect(dialogModel.password == "MySecretPw!")

        // Invalid clipboard content with secret never leaks secret and preserves existing fields
        let secret = "TopSecretClipboardToken987"
        clipboardValue = "mysql://admin:\(secret)@bad.example.com:3306/db"
        dialogModel.pasteAndImportConnectionUrl()
        #expect(readCount == 3)
        #expect(dialogModel.urlImportIsError == true)
        #expect(dialogModel.connectionUrlInput.isEmpty)
        #expect(!(dialogModel.urlImportMessage ?? "").contains(secret))
        #expect(dialogModel.host == "db.paste.internal")
    }

    @Test("Quick-connect protects against repeated clicks, reports errors cleanly, and enforces safeguards when switching")
    @MainActor
    func testQuickConnectProgressRepeatProtectionAndSafeguards() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let suiteName = "com.lucidsql.tests.quickconnect.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let privacy = PrivacyPreferencesStore(userDefaults: userDefaults)
        privacy.setSqlDraftPersistenceEnabled(false)

        let profileStore = ConnectionProfileStore(fileURL: dir.appendingPathComponent("profiles.json"))
        let passwordStore = InMemoryPasswordStore()
        let profileA = ConnectionProfile(name: "Primary", host: "db-a.local", port: 5432, database: "app_a", user: "alice")
        let profileB = ConnectionProfile(name: "Replica", host: "db-b.local", port: 5433, database: "app_b", user: "bob")
        try profileStore.saveOrUpdateProfile(profileA, markAsConnected: false, markSelected: false)
        try profileStore.saveOrUpdateProfile(profileB, markAsConnected: false, markSelected: false)

        let model = WorkspaceModel(
            profileStore: profileStore,
            draftStore: SqlDraftStore(fileURL: dir.appendingPathComponent("drafts.json")),
            passwordStore: passwordStore,
            privacyPreferences: privacy
        )
        model.sweepGlobalSessionsOnDisconnect = false

        final class MockConnectionProbe: @unchecked Sendable {
            private let lock = NSLock()
            var testCalls = 0
            var shouldFail = false

            func recordCallAndCheckShouldFail() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                testCalls += 1
                return shouldFail
            }

            func setShouldFail(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                shouldFail = value
            }

            var callsCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return testCalls
            }
        }

        let probe = MockConnectionProbe()
        model.connectionTester = { _ in
            let fail = probe.recordCallAndCheckShouldFail()
            try await Task.sleep(for: .milliseconds(80))
            if fail {
                throw LucidError.ConnectionFailed(reason: "connection refused")
            }
            return "PostgreSQL 16.0"
        }

        @MainActor
        func waitUntilIdle() async throws {
            for _ in 0..<250 {
                if model.connectingProfileId == nil {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        // Rapid double click on A must only trigger one connection attempt
        model.quickConnect(profile: profileA)
        #expect(model.connectingProfileId == profileA.id)
        model.quickConnect(profile: profileA)
        model.quickConnect(profile: profileB)
        #expect(model.connectingProfileId == profileA.id)

        try await waitUntilIdle()
        #expect(probe.callsCount == 1)
        #expect(model.connectingProfileId == nil)
        #expect(model.activeProfile?.id == profileA.id)
        #expect(model.currentMode == .tableData)
        #expect(model.sqlWorkspace.tabs.isEmpty == false)

        // Switching to SQL mode after Table Data restores selected query tab without adding extra tabs
        let initialTab = try #require(model.sqlWorkspace.activeTab)
        let secondTab = model.sqlWorkspace.createTab(title: "Analytics")
        #expect(model.sqlWorkspace.tabs.count == 2)
        #expect(model.sqlWorkspace.activeTab?.id == secondTab.id)
        model.currentMode = .tableData
        model.currentMode = .sqlEditor
        #expect(model.sqlWorkspace.tabs.count == 2)
        #expect(model.sqlWorkspace.activeTab?.id == secondTab.id)
        #expect(initialTab.id != secondTab.id)

        // Failing quick-connect keeps existing connection intact and records concise error
        probe.setShouldFail(true)
        model.quickConnect(profile: profileB)
        #expect(model.connectingProfileId == profileB.id)
        try await waitUntilIdle()
        #expect(model.connectingProfileId == nil)
        #expect(model.activeProfile?.id == profileA.id)
        #expect(model.quickConnectErrorProfileId == profileB.id)
        #expect(model.quickConnectErrorMessage?.contains("connection refused") == true)
        #expect(model.showingQuickConnectErrorAlert == true)
        model.clearQuickConnectError()

        // With staged edits, quickConnect must trigger switch-connection safeguard immediately
        probe.setShouldFail(false)
        model.tableViewModel.currentSchema = "public"
        model.tableViewModel.currentTable = "items"
        model.tableViewModel.columns = [
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "name", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
        ]
        model.tableViewModel.rows = [RowData(cells: [.text("1"), .integer(1), .text("a")])]
        model.tableViewModel.stageTextEdit(row: 0, column: 1, text: "b")
        model.quickConnect(profile: profileB)
        #expect(model.showingSwitchConnectionAlert == true)
        #expect(model.connectingProfileId == nil)
        model.cancelConnectionSwitch()
    }

    @Test("Lazy Keychain access: metadata edits never fetch secrets, Replace/Forget preserve safety, and access denial handles cleanly without loops")
    @MainActor
    func testLazyKeychainAccessAndCredentialLifecycle() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let profileStore = ConnectionProfileStore(fileURL: dir.appendingPathComponent("profiles.json"))
        let draftStore = SqlDraftStore(fileURL: dir.appendingPathComponent("sql_drafts.json"))
        let passwordStore = InMemoryPasswordStore()

        let profileA = ConnectionProfile(name: "Primary", host: "10.0.0.10", database: "app", user: "alice", rememberPassword: true)
        let profileB = ConnectionProfile(name: "Analytics", host: "10.0.0.20", database: "dw", user: "bob", rememberPassword: true)
        try profileStore.saveOrUpdateProfile(profileA, markAsConnected: false, markSelected: true)
        try profileStore.saveOrUpdateProfile(profileB, markAsConnected: false, markSelected: false)
        try passwordStore.savePassword(profileId: profileA.id, password: "secret-A")
        try passwordStore.savePassword(profileId: profileB.id, password: "secret-B")
        passwordStore.resetCounters()

        // 1. Launching WorkspaceModel & opening/browsing ConnectionDialog performs zero secret reads
        let workspace = WorkspaceModel(
            profileStore: profileStore,
            draftStore: draftStore,
            passwordStore: passwordStore
        )
        workspace.sweepGlobalSessionsOnDisconnect = false
        #expect(passwordStore.counts.secretLookup == 0)

        let dialog = ConnectionDialogModel(
            profile: profileA,
            profileStore: profileStore,
            draftStore: draftStore,
            passwordStore: passwordStore
        )
        #expect(dialog.credentialState == .savedInKeychain)
        #expect(dialog.password.isEmpty)
        #expect(passwordStore.counts.secretLookup == 0)

        dialog.selectSavedProfile(profileB.id)
        #expect(dialog.credentialState == .savedInKeychain)
        #expect(dialog.password.isEmpty)
        #expect(passwordStore.counts.secretLookup == 0)

        // 2. Editing non-secret metadata and saving preserves existing Keychain password without reading or deleting it
        dialog.profileName = "Analytics Renamed"
        dialog.timeoutSeconds = 25
        dialog.saveProfileOnly()
        #expect(passwordStore.counts.secretLookup == 0)
        #expect(passwordStore.counts.delete == 0)
        #expect(dialog.credentialState == .savedInKeychain)
        #expect(try passwordStore.getPassword(profileId: profileB.id) == "secret-B")
        passwordStore.resetCounters()

        // 3. Explicit Replace and Forget flows
        dialog.beginReplacingPassword()
        #expect(dialog.credentialState == .replacing)
        dialog.cancelReplacingPassword()
        #expect(dialog.credentialState == .savedInKeychain)

        dialog.markForgetSavedPassword()
        #expect(dialog.credentialState == .forgetPending)
        dialog.undoForgetSavedPassword()
        #expect(dialog.credentialState == .savedInKeychain)
        #expect(passwordStore.counts.delete == 0)

        dialog.markForgetSavedPassword()
        dialog.saveProfileOnly()
        #expect(passwordStore.counts.delete == 1)
        #expect(dialog.credentialState == .none)
        #expect(profileStore.profile(for: profileB.id)?.rememberPassword == false)

        // Replace password on A cleanly
        dialog.selectSavedProfile(profileA.id)
        dialog.beginReplacingPassword()
        dialog.password = "rotated-A"
        dialog.saveProfileOnly()
        #expect(try passwordStore.getPassword(profileId: profileA.id) == "rotated-A")
        passwordStore.resetCounters()

        // 4. Keychain denial during explicit Test Connection fails once concisely without prompting loop
        passwordStore.simulateAccessDenied = true
        let freshDialogForA = ConnectionDialogModel(
            profile: profileStore.profile(for: profileA.id)!,
            profileStore: profileStore,
            draftStore: draftStore,
            passwordStore: passwordStore
        )
        #expect(passwordStore.counts.secretLookup == 0)
        await freshDialogForA.runConnectionTest()
        #expect(passwordStore.counts.secretLookup == 1)
        #expect(freshDialogForA.testResultIsError == true)
        #expect(freshDialogForA.testResultMessage?.contains("denied or cancelled") == true)
        #expect(freshDialogForA.isTesting == false)

        // 5. Keychain denial during quickConnect stops once gracefully without connecting or looping
        passwordStore.resetCounters()
        workspace.quickConnect(profile: profileA)
        #expect(passwordStore.counts.secretLookup == 1)
        #expect(workspace.connectingProfileId == nil)
        #expect(workspace.activeConfig == nil)
        #expect(workspace.quickConnectErrorProfileId == profileA.id)
        #expect(workspace.quickConnectErrorMessage?.contains("denied or cancelled") == true)

        // 6. Successful quickConnect reads Keychain once, connects into Table Data, and restores drafts silently
        passwordStore.simulateAccessDenied = false
        passwordStore.resetCounters()
        workspace.connectionTester = { config in
            #expect(config.password == "rotated-A")
            return "PostgreSQL 16.0"
        }

        let sqlTabWorkspace = SqlWorkspaceViewModel(draftStore: draftStore)
        sqlTabWorkspace.activate(profileId: profileA.id)
        sqlTabWorkspace.tabs[0].sqlText = "SELECT 'background-draft';"
        sqlTabWorkspace.flushDrafts()

        workspace.quickConnect(profile: profileA)
        for _ in 0..<250 {
            if workspace.connectingProfileId == nil && workspace.activeConfig != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(passwordStore.counts.secretLookup == 1)
        #expect(workspace.activeConfig?.password == "rotated-A")
        #expect(workspace.currentMode == .tableData)
        #expect(workspace.sqlWorkspace.tabs.first?.sqlText == "SELECT 'background-draft';")
    }

    @Test("Connection selector display omits duplicate host/IP when already in profile name")
    func testConnectionDisplayFormattingDeduplicatesEndpoint() {
        let distinctName = ConnectionProfile(
            name: "Local Playground",
            host: "127.0.0.1",
            port: 5432,
            database: "postgres",
            user: "postgres"
        )
        #expect(ConnectionDisplayFormatting.hostSummary(for: distinctName) == "127.0.0.1")
        #expect(ConnectionDisplayFormatting.shouldAppendEndpoint(for: distinctName) == true)
        #expect(ConnectionDisplayFormatting.menuLabel(for: distinctName) == "Local Playground — 127.0.0.1")

        let hostAsName = ConnectionProfile(
            name: "127.0.0.1",
            host: "127.0.0.1",
            port: 5432,
            database: "postgres",
            user: "postgres"
        )
        #expect(ConnectionDisplayFormatting.shouldAppendEndpoint(for: hostAsName) == false)
        #expect(ConnectionDisplayFormatting.menuLabel(for: hostAsName) == "127.0.0.1")

        let embeddedHostWithPort = ConnectionProfile(
            name: "Staging (db.internal:5433)",
            host: "db.internal",
            port: 5433,
            database: "app",
            user: "app"
        )
        #expect(ConnectionDisplayFormatting.hostSummary(for: embeddedHostWithPort) == "db.internal:5433")
        #expect(ConnectionDisplayFormatting.shouldAppendEndpoint(for: embeddedHostWithPort) == false)
        #expect(ConnectionDisplayFormatting.menuLabel(for: embeddedHostWithPort) == "Staging (db.internal:5433)")
    }
}
