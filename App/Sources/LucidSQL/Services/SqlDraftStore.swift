import Foundation

public struct SqlDraftTabSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var sqlText: String
    public var selectionLocation: Int
    public var selectionLength: Int
    public var isReadOnly: Bool

    public init(
        id: UUID,
        title: String,
        sqlText: String,
        selectionLocation: Int = 0,
        selectionLength: Int = 0,
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.title = title
        self.sqlText = sqlText
        self.selectionLocation = max(0, selectionLocation)
        self.selectionLength = max(0, selectionLength)
        self.isReadOnly = isReadOnly
    }
}

public struct ProfileSqlWorkspaceSnapshot: Codable, Equatable, Sendable {
    public var profileId: UUID
    public var activeTabId: UUID?
    public var tabs: [SqlDraftTabSnapshot]
    public var updatedAt: Date

    public init(
        profileId: UUID,
        activeTabId: UUID?,
        tabs: [SqlDraftTabSnapshot],
        updatedAt: Date = Date()
    ) {
        self.profileId = profileId
        self.activeTabId = activeTabId
        self.tabs = tabs
        self.updatedAt = updatedAt
    }
}

private struct SqlDraftCatalog: Codable {
    var version: Int = 1
    var workspaces: [String: ProfileSqlWorkspaceSnapshot] = [:]
}

public final class SqlDraftStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.lucidsql.draftstore")

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("LucidSQL", isDirectory: true)
            .appendingPathComponent("sql_drafts.json", isDirectory: false)
    }

    public init(fileURL: URL = SqlDraftStore.defaultFileURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func loadWorkspace(for profileId: UUID) -> ProfileSqlWorkspaceSnapshot? {
        queue.sync {
            let catalog = loadCatalogLocked()
            return catalog.workspaces[profileId.uuidString]
        }
    }

    public func saveWorkspace(_ snapshot: ProfileSqlWorkspaceSnapshot) throws {
        try queue.sync {
            var catalog = loadCatalogLocked()
            catalog.workspaces[snapshot.profileId.uuidString] = snapshot
            try writeCatalogLocked(catalog)
        }
    }

    public func deleteWorkspace(for profileId: UUID) throws {
        try queue.sync {
            var catalog = loadCatalogLocked()
            guard catalog.workspaces.removeValue(forKey: profileId.uuidString) != nil else { return }
            try writeCatalogLocked(catalog)
        }
    }

    public func deleteAllWorkspaces() throws {
        try queue.sync {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    public func pruneOrphanedWorkspaces(validProfileIds: Set<UUID>) throws {
        try queue.sync {
            var catalog = loadCatalogLocked()
            let validKeys = Set(validProfileIds.map { $0.uuidString })
            let originalCount = catalog.workspaces.count
            catalog.workspaces = catalog.workspaces.filter { validKeys.contains($0.key) }
            if catalog.workspaces.count != originalCount {
                try writeCatalogLocked(catalog)
            }
        }
    }

    public func storedProfileIds() -> [UUID] {
        queue.sync {
            let catalog = loadCatalogLocked()
            return catalog.workspaces.keys.compactMap { UUID(uuidString: $0) }
        }
    }

    private func loadCatalogLocked() -> SqlDraftCatalog {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return SqlDraftCatalog()
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return SqlDraftCatalog()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let catalog = try? decoder.decode(SqlDraftCatalog.self, from: data) {
            return catalog
        }
        return SqlDraftCatalog()
    }

    private func writeCatalogLocked(_ catalog: SqlDraftCatalog) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)
        try data.write(to: fileURL, options: [.atomic])
    }
}
