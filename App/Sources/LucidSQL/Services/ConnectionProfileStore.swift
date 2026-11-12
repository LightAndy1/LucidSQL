import Foundation

private struct PersistedProfilesPayload: Codable {
    var version: Int = 1
    var lastConnectedProfileId: UUID? = nil
    var lastSelectedProfileId: UUID? = nil
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

    public func lastSelectedProfileId() -> UUID? {
        queue.sync {
            let payload = loadPayloadLocked()
            if let selected = payload.lastSelectedProfileId,
               payload.profiles.contains(where: { $0.id == selected }) {
                return selected
            }
            if let connected = payload.lastConnectedProfileId,
               payload.profiles.contains(where: { $0.id == connected }) {
                return connected
            }
            return payload.profiles.first?.id
        }
    }

    public func mostRecentProfile() -> ConnectionProfile? {
        queue.sync {
            let payload = loadPayloadLocked()
            if let selectedId = payload.lastSelectedProfileId,
               let match = payload.profiles.first(where: { $0.id == selectedId }) {
                return match
            }
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

    public func selectProfile(id: UUID?) throws {
        try queue.sync {
            var payload = loadPayloadLocked()
            if let id {
                guard payload.profiles.contains(where: { $0.id == id }) else {
                    return
                }
                payload.lastSelectedProfileId = id
            } else {
                payload.lastSelectedProfileId = nil
            }
            try writePayloadLocked(payload)
        }
    }

    /// Resolves which profile ID to use when saving/connecting while preserving stable profile IDs
    /// for existing saved profiles even if host, port, database, or user are edited.
    public func resolveProfileForConnect(
        initialProfile: ConnectionProfile,
        editedProfile: ConnectionProfile,
        preserveInitialIdIfSaved: Bool = true
    ) -> ConnectionProfile {
        queue.sync {
            let payload = loadPayloadLocked()
            if preserveInitialIdIfSaved,
               payload.profiles.contains(where: { $0.id == initialProfile.id }) {
                var updated = editedProfile
                updated.id = initialProfile.id
                return updated
            }
            if payload.profiles.contains(where: { $0.id == editedProfile.id }) {
                return editedProfile
            }
            return editedProfile
        }
    }

    /// Inserts a new profile or updates an existing profile in place while preserving its UUID and list position.
    public func saveOrUpdateProfile(
        _ profile: ConnectionProfile,
        markAsConnected: Bool = true,
        markSelected: Bool = true
    ) throws {
        try queue.sync {
            var payload = loadPayloadLocked()
            if let existingIndex = payload.profiles.firstIndex(where: { $0.id == profile.id }) {
                payload.profiles[existingIndex] = profile
            } else {
                payload.profiles.insert(profile, at: 0)
            }
            if markAsConnected {
                payload.lastConnectedProfileId = profile.id
            }
            if markSelected || markAsConnected {
                payload.lastSelectedProfileId = profile.id
            }
            try writePayloadLocked(payload)
        }
    }

    /// Duplicates an existing saved profile under a fresh UUID and optional Keychain password copy.
    public func duplicateProfile(
        id: UUID,
        passwordStore: (any PasswordStoring)? = nil
    ) throws -> ConnectionProfile? {
        let duplicated: ConnectionProfile? = try queue.sync {
            var payload = loadPayloadLocked()
            guard let sourceIndex = payload.profiles.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            let source = payload.profiles[sourceIndex]
            let existingNames = Set(payload.profiles.map(\.name))
            let newName = uniqueCopyName(baseName: source.name, existingNames: existingNames)
            let copy = ConnectionProfile(
                id: UUID(),
                name: newName,
                host: source.host,
                port: source.port,
                database: source.database,
                user: source.user,
                sslMode: source.sslMode,
                sslRootCert: source.sslRootCert,
                timeoutSeconds: source.timeoutSeconds,
                rememberPassword: source.rememberPassword
            )
            payload.profiles.insert(copy, at: sourceIndex + 1)
            payload.lastSelectedProfileId = copy.id
            try writePayloadLocked(payload)
            return copy
        }

        if let duplicated, duplicated.rememberPassword, let passwordStore,
           let existingPassword = try? passwordStore.getPassword(profileId: id),
           !existingPassword.isEmpty {
            try? passwordStore.savePassword(profileId: duplicated.id, password: existingPassword)
        }

        return duplicated
    }

    public func deleteProfile(
        id: UUID,
        draftStore: SqlDraftStore? = nil,
        passwordStore: (any PasswordStoring)? = nil
    ) throws {
        try queue.sync {
            var payload = loadPayloadLocked()
            payload.profiles.removeAll { $0.id == id }
            if payload.lastConnectedProfileId == id {
                payload.lastConnectedProfileId = payload.profiles.first?.id
            }
            if payload.lastSelectedProfileId == id {
                payload.lastSelectedProfileId = payload.lastConnectedProfileId ?? payload.profiles.first?.id
            }
            try writePayloadLocked(payload)
        }
        try? passwordStore?.deletePassword(profileId: id)
        try draftStore?.deleteWorkspace(for: id)
    }

    private func uniqueCopyName(baseName: String, existingNames: Set<String>) -> String {
        let candidate = "\(baseName) Copy"
        if !existingNames.contains(candidate) {
            return candidate
        }
        var counter = 2
        while existingNames.contains("\(baseName) Copy \(counter)") {
            counter += 1
        }
        return "\(baseName) Copy \(counter)"
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
