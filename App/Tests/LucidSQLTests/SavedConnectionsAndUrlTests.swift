import Foundation
import Testing
@testable import LucidSQL
import LucidSQLBridge

private final class InMemoryPasswordStore: PasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func savePassword(profileId: UUID, password: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[profileId] = password
    }

    func getPassword(profileId: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[profileId]
    }

    func deletePassword(profileId: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: profileId)
    }

    var allStoredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
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
}
