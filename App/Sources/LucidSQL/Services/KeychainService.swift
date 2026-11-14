import Foundation
import Security

public enum PasswordLookupResult: Equatable, Sendable {
    case found(String)
    case notFound
    case accessDenied
    case failed(String)
}

public protocol PasswordStoring: Sendable {
    func savePassword(profileId: UUID, password: String) throws
    func hasStoredPassword(profileId: UUID) -> Bool
    func lookupPassword(profileId: UUID) -> PasswordLookupResult
    func getPassword(profileId: UUID) throws -> String?
    func deletePassword(profileId: UUID) throws
}

public extension PasswordStoring {
    func hasStoredPassword(profileId: UUID) -> Bool {
        if case .found(let value) = lookupPassword(profileId: profileId), !value.isEmpty {
            return true
        }
        return false
    }

    func lookupPassword(profileId: UUID) -> PasswordLookupResult {
        do {
            if let value = try getPassword(profileId: profileId), !value.isEmpty {
                return .found(value)
            }
            return .notFound
        } catch let KeychainService.KeychainError.secError(status) {
            if KeychainService.isAccessDeniedStatus(status) {
                return .accessDenied
            }
            return .failed(KeychainService.KeychainError.secError(status).localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

public struct KeychainPasswordStore: PasswordStoring, Sendable {
    public static let shared = KeychainPasswordStore()

    public init() {}

    public func savePassword(profileId: UUID, password: String) throws {
        try KeychainService.savePassword(profileId: profileId, password: password)
    }

    public func hasStoredPassword(profileId: UUID) -> Bool {
        KeychainService.hasStoredPassword(profileId: profileId)
    }

    public func lookupPassword(profileId: UUID) -> PasswordLookupResult {
        KeychainService.lookupPassword(profileId: profileId)
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

    public static func isAccessDeniedStatus(_ status: OSStatus) -> Bool {
        status == errSecUserCanceled
            || status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
    }

    /// Checks whether a credential entry exists without requesting confidential secret data (`kSecReturnData`),
    /// avoiding macOS Keychain authorization prompts when inspecting or editing non-secret profile metadata.
    public static func hasStoredPassword(profileId: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: profileId.uuidString,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    public static func lookupPassword(profileId: UUID) -> PasswordLookupResult {
        do {
            if let value = try getPassword(profileId: profileId), !value.isEmpty {
                return .found(value)
            }
            return .notFound
        } catch KeychainError.secError(let status) where isAccessDeniedStatus(status) {
            return .accessDenied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public static func savePassword(profileId: UUID, password: String) throws {
        let account = profileId.uuidString
        let data = Data(password.utf8)
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            // Fall back to replacing only if update itself failed for a recoverable item state.
            SecItemDelete(matchQuery as CFDictionary)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.secError(addStatus) }
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
