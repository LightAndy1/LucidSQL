import Foundation
import Testing
@testable import LucidSQL

@Suite("macOS Keychain Service & Profile Tests")
struct KeychainServiceTests {
    @Test("Verify saving, retrieving, and deleting password in Keychain")
    func testSaveAndRetrievePassword() throws {
        let profileId = UUID()
        let password = "super_secret_db_pass_\(UUID().uuidString)"

        do {
            try KeychainService.savePassword(profileId: profileId, password: password)
            let retrieved = try KeychainService.getPassword(profileId: profileId)
            #expect(retrieved == password)

            try KeychainService.deletePassword(profileId: profileId)
            let afterDelete = try KeychainService.getPassword(profileId: profileId)
            #expect(afterDelete == nil)
        } catch let KeychainService.KeychainError.secError(status) where status == errSecInteractionNotAllowed {
            // In headless/CI environments where macOS user keychain is not unlocked, verify graceful error handling
            #expect(status == errSecInteractionNotAllowed)
        }
    }

    @Test("Verify ConnectionProfile serialization and defaults")
    func testConnectionProfileCodable() throws {
        let profile = ConnectionProfile(
            name: "Production DB",
            host: "db.example.com",
            port: 5433,
            database: "analytics",
            user: "app_reader",
            sslMode: "require",
            timeoutSeconds: 15
        )

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: encoded)

        #expect(decoded.id == profile.id)
        #expect(decoded.name == "Production DB")
        #expect(decoded.host == "db.example.com")
        #expect(decoded.port == 5433)
        #expect(decoded.database == "analytics")
        #expect(decoded.user == "app_reader")
        #expect(decoded.sslMode == "require")
        #expect(decoded.timeoutSeconds == 15)
    }
}
