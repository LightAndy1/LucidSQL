import Foundation

public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var database: String
    public var user: String
    public var sslMode: String
    public var sslRootCert: String?
    public var timeoutSeconds: UInt32
    public var rememberPassword: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case database
        case user
        case sslMode
        case sslRootCert
        case timeoutSeconds
        case rememberPassword = "useKeychain"
    }

    public init(
        id: UUID = UUID(),
        name: String = "Local PostgreSQL",
        host: String = "localhost",
        port: UInt16 = 5432,
        database: String = "postgres",
        user: String = "postgres",
        sslMode: String = "prefer",
        sslRootCert: String? = nil,
        timeoutSeconds: UInt32 = 10,
        rememberPassword: Bool = true
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.sslMode = sslMode
        self.sslRootCert = sslRootCert
        self.timeoutSeconds = timeoutSeconds
        self.rememberPassword = rememberPassword
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decode(UInt16.self, forKey: .port)
        self.database = try container.decode(String.self, forKey: .database)
        self.user = try container.decode(String.self, forKey: .user)
        self.sslMode = try container.decode(String.self, forKey: .sslMode)
        self.sslRootCert = try container.decodeIfPresent(String.self, forKey: .sslRootCert)
        self.timeoutSeconds = try container.decode(UInt32.self, forKey: .timeoutSeconds)
        self.rememberPassword = try container.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? true
    }

    /// Converts connection profile and an optional resolved password to the Rust ConnectionConfig
    public func toRustConfig(password: String? = nil) -> ConnectionConfig {
        let trimmedCert = sslRootCert?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectionConfig(
            host: host,
            port: port,
            database: database,
            user: user,
            password: password,
            sslMode: sslMode,
            sslRootCert: (trimmedCert?.isEmpty == false) ? trimmedCert : nil,
            timeoutSeconds: timeoutSeconds
        )
    }
}
