import Foundation
import Security

public protocol PasswordStoring: Sendable {
    func savePassword(profileId: UUID, password: String) throws
    func getPassword(profileId: UUID) throws -> String?
    func deletePassword(profileId: UUID) throws
}

public struct KeychainPasswordStore: PasswordStoring, Sendable {
    public static let shared = KeychainPasswordStore()

    public init() {}

    public func savePassword(profileId: UUID, password: String) throws {
        try KeychainService.savePassword(profileId: profileId, password: password)
    }

    public func getPassword(profileId: UUID) throws -> String? {
        try KeychainService.getPassword(profileId: profileId)
    }

    public func deletePassword(profileId: UUID) throws {
        try KeychainService.deletePassword(profileId: profileId)
    }
}

public enum KeychainService {
    private static let serviceName = "com.lucidsql.connection-passwords"

    public static func savePassword(profileId: UUID, password: String) throws {
        let account = profileId.uuidString
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.secError(status) }
    }

    public static func getPassword(profileId: UUID) throws -> String? {
        let account = profileId.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.secError(status) }
        return String(data: data, encoding: .utf8)
    }

    public static func deletePassword(profileId: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: profileId.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    public enum KeychainError: Error, LocalizedError {
        case secError(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .secError(let status):
                if let msg = SecCopyErrorMessageString(status, nil) as String? {
                    return "Keychain error (\(status)): \(msg)"
                }
                return "Keychain error with status \(status)"
            }
        }
    }
}
