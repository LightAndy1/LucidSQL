import Foundation

private struct PersistedProfilesPayload: Codable {
    var version: Int = 1
    var lastConnectedProfileId: UUID? = nil
    var profiles: [ConnectionProfile] = []
}

public final class ConnectionProfileStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.lucidsql.profilestore")

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("LucidSQL", isDirectory: true)
            .appendingPathComponent("profiles.json", isDirectory: false)
    }

    public init(fileURL: URL = ConnectionProfileStore.defaultFileURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func loadProfiles() -> [ConnectionProfile] {
        queue.sync {
            loadPayloadLocked().profiles
        }
    }

    public func mostRecentProfile() -> ConnectionProfile? {
        queue.sync {
            let payload = loadPayloadLocked()
            if let lastId = payload.lastConnectedProfileId,
               let match = payload.profiles.first(where: { $0.id == lastId }) {
                return match
            }
            return payload.profiles.first
        }
    }

    public func profile(for id: UUID) -> ConnectionProfile? {
        queue.sync {
            loadPayloadLocked().profiles.first(where: { $0.id == id })
        }
    }

    public func resolveProfileForConnect(
        initialProfile: ConnectionProfile,
        editedProfile: ConnectionProfile
    ) -> ConnectionProfile {
        queue.sync {
            let payload = loadPayloadLocked()
            if sameEndpoint(initialProfile, editedProfile),
               payload.profiles.contains(where: { $0.id == initialProfile.id }) {
                return editedProfile
            }
            if let existing = payload.profiles.first(where: { sameEndpoint($0, editedProfile) }) {
                var resolved = editedProfile
                resolved.id = existing.id
                return resolved
            }
            var fresh = editedProfile
            if payload.profiles.contains(where: { $0.id == fresh.id }) {
                fresh.id = UUID()
            }
            return fresh
        }
    }

    public func saveOrUpdateProfile(_ profile: ConnectionProfile) throws {
        try queue.sync {
            var payload = loadPayloadLocked()
            payload.profiles.removeAll { $0.id == profile.id }
            payload.profiles.insert(profile, at: 0)
            payload.lastConnectedProfileId = profile.id
            try writePayloadLocked(payload)
        }
    }

    public func deleteProfile(id: UUID, draftStore: SqlDraftStore? = nil) throws {
        try queue.sync {
            var payload = loadPayloadLocked()
            payload.profiles.removeAll { $0.id == id }
            if payload.lastConnectedProfileId == id {
                payload.lastConnectedProfileId = payload.profiles.first?.id
            }
            try writePayloadLocked(payload)
        }
        try draftStore?.deleteWorkspace(for: id)
    }

    private func sameEndpoint(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame &&
        lhs.port == rhs.port &&
        lhs.database == rhs.database &&
        lhs.user == rhs.user
    }

    private func loadPayloadLocked() -> PersistedProfilesPayload {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(PersistedProfilesPayload.self, from: data) else {
            return PersistedProfilesPayload()
        }
        return payload
    }

    private func writePayloadLocked(_ payload: PersistedProfilesPayload) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: [.atomic])
    }
}
