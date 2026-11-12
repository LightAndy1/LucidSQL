import Foundation

@MainActor
public final class PrivacyPreferencesStore: ObservableObject {
    public static let shared = PrivacyPreferencesStore()
    public static let sqlDraftPersistenceKey = "lucidsql.privacy.persistSqlDrafts"

    private let defaults: UserDefaults

    @Published public private(set) var isSqlDraftPersistenceEnabled: Bool

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        if userDefaults.object(forKey: Self.sqlDraftPersistenceKey) == nil {
            self.isSqlDraftPersistenceEnabled = true
        } else {
            self.isSqlDraftPersistenceEnabled = userDefaults.bool(forKey: Self.sqlDraftPersistenceKey)
        }
    }

    public func setSqlDraftPersistenceEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.sqlDraftPersistenceKey)
        isSqlDraftPersistenceEnabled = enabled
    }
}
