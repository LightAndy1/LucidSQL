import Foundation

public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var database: String
    public var user: String
    public var sslMode: String
    public var timeoutSeconds: UInt32

    public init(
        id: UUID = UUID(),
        name: String = "Local PostgreSQL",
        host: String = "localhost",
        port: UInt16 = 5432,
        database: String = "postgres",
        user: String = "postgres",
        sslMode: String = "prefer",
        timeoutSeconds: UInt32 = 10
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.sslMode = sslMode
        self.timeoutSeconds = timeoutSeconds
    }

    /// Converts connection profile and an optional resolved password to the Rust ConnectionConfig
    public func toRustConfig(password: String? = nil) -> ConnectionConfig {
        ConnectionConfig(
            host: host,
            port: port,
            database: database,
            user: user,
            password: password,
            sslMode: sslMode,
            timeoutSeconds: timeoutSeconds
        )
    }
}
