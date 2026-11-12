import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LucidSQLBridge

@MainActor
final class ConnectionDialogModel: ObservableObject {
    @Published var savedProfiles: [ConnectionProfile] = []
    @Published var selectedSidebarProfileId: UUID? = nil
    @Published var isEditingSavedProfile: Bool = false

    @Published var profileName: String = "Local PostgreSQL"
    @Published var host: String = "localhost"
    @Published var port: String = "5432"
    @Published var database: String = "postgres"
    @Published var user: String = "postgres"
    @Published var password: String = ""
    @Published var rememberPassword: Bool = true
    @Published var sslMode: String = "prefer"
    @Published var sslRootCertPath: String = ""
    @Published var timeoutSeconds: Int = 10

    @Published var connectionUrlInput: String = ""
    @Published var urlImportMessage: String? = nil
    @Published var urlImportIsError: Bool = false

    @Published var isTesting: Bool = false
    @Published var testResultMessage: String? = nil
    @Published var testResultIsError: Bool = false

    @Published var profilePendingDelete: ConnectionProfile? = nil
    @Published var showingDeleteConfirmation: Bool = false

    private let profileStore: ConnectionProfileStore
    private let draftStore: SqlDraftStore
    private let passwordStore: any PasswordStoring
    private let activeConnectedProfileId: UUID?
    private let onProfilesChanged: (() -> Void)?

    private var editingProfileId: UUID

    init(
        profile: ConnectionProfile,
        initialNotice: String? = nil,
        activeConnectedProfileId: UUID? = nil,
        profileStore: ConnectionProfileStore = ConnectionProfileStore(),
        draftStore: SqlDraftStore = SqlDraftStore(),
        passwordStore: any PasswordStoring = KeychainPasswordStore.shared,
        onProfilesChanged: (() -> Void)? = nil
    ) {
        self.profileStore = profileStore
        self.draftStore = draftStore
        self.passwordStore = passwordStore
        self.activeConnectedProfileId = activeConnectedProfileId
        self.onProfilesChanged = onProfilesChanged

        let allProfiles = profileStore.loadProfiles()
        self.savedProfiles = allProfiles
        let matchedSaved = allProfiles.first(where: { $0.id == profile.id })
        self.editingProfileId = profile.id
        self.isEditingSavedProfile = matchedSaved != nil
        self.selectedSidebarProfileId = matchedSaved?.id

        self.applyProfileToForm(matchedSaved ?? profile)

        if let initialNotice, !initialNotice.isEmpty {
            self.testResultMessage = initialNotice
            self.testResultIsError = false
        }
    }

    private func applyProfileToForm(_ profile: ConnectionProfile) {
        self.editingProfileId = profile.id
        self.profileName = profile.name
        self.host = profile.host
        self.port = String(profile.port)
        self.database = profile.database
        self.user = profile.user
        self.rememberPassword = profile.rememberPassword
        if profile.rememberPassword {
            self.password = (try? passwordStore.getPassword(profileId: profile.id)) ?? ""
        } else {
            self.password = ""
        }
        self.sslMode = profile.sslMode
        self.sslRootCertPath = profile.sslRootCert ?? ""
        self.timeoutSeconds = Int(max(1, min(300, profile.timeoutSeconds)))
    }

    var requiresCaVerification: Bool {
        sslMode == "verify-ca" || sslMode == "verify-full"
    }

    var sslModeSummary: String {
        switch sslMode {
        case "disable":
            return "Plaintext connection (unencrypted). Fails if server requires TLS."
        case "prefer":
            return "Encrypts with TLS if supported, otherwise falls back to plaintext. Certificate and hostname are not verified."
        case "require":
            return "Requires TLS encryption and rejects plaintext, but skips CA and hostname verification (accepts self-signed certificates)."
        case "verify-ca":
            return "Requires TLS and verifies the server certificate chain against system roots or your custom CA file. Hostname mismatch is still permitted."
        case "verify-full":
            return "Requires TLS and verifies both CA certificate trust and exact server hostname match."
        default:
            return "Strict SSL mode configuration."
        }
    }

    func reloadSavedProfiles() {
        savedProfiles = profileStore.loadProfiles()
        onProfilesChanged?()
    }

    func selectSavedProfile(_ id: UUID?) {
        guard let id else { return }
        guard let profile = savedProfiles.first(where: { $0.id == id }) ?? profileStore.profile(for: id) else {
            return
        }
        selectedSidebarProfileId = profile.id
        isEditingSavedProfile = true
        applyProfileToForm(profile)
        connectionUrlInput = ""
        urlImportMessage = nil
        urlImportIsError = false
        testResultMessage = nil
        testResultIsError = false
        try? profileStore.selectProfile(id: profile.id)
        onProfilesChanged?()
    }

    func startNewConnection() {
        let fresh = ConnectionProfile(
            id: UUID(),
            name: "New PostgreSQL",
            host: "localhost",
            port: 5432,
            database: "postgres",
            user: "postgres",
            sslMode: "prefer",
            sslRootCert: nil,
            timeoutSeconds: 10,
            rememberPassword: true
        )
        selectedSidebarProfileId = nil
        isEditingSavedProfile = false
        applyProfileToForm(fresh)
        connectionUrlInput = ""
        urlImportMessage = nil
        urlImportIsError = false
        testResultMessage = nil
        testResultIsError = false
    }

    func duplicateProfile(_ id: UUID) {
        do {
            if let copy = try profileStore.duplicateProfile(id: id, passwordStore: passwordStore) {
                reloadSavedProfiles()
                selectedSidebarProfileId = copy.id
                isEditingSavedProfile = true
                applyProfileToForm(copy)
                connectionUrlInput = ""
                urlImportMessage = nil
                testResultMessage = "Duplicated connection as \"\(copy.name)\"."
                testResultIsError = false
            }
        } catch {
            testResultMessage = "Failed to duplicate profile: \(error.localizedDescription)"
            testResultIsError = true
        }
    }

    func canDeleteProfile(_ id: UUID) -> Bool {
        activeConnectedProfileId != id && savedProfiles.contains(where: { $0.id == id })
    }

    func requestDeleteProfile(_ id: UUID) {
        guard canDeleteProfile(id),
              let profile = savedProfiles.first(where: { $0.id == id }) else {
            return
        }
        profilePendingDelete = profile
        showingDeleteConfirmation = true
    }

    func confirmDeleteProfile() {
        guard let profile = profilePendingDelete else { return }
        profilePendingDelete = nil
        showingDeleteConfirmation = false

        do {
            try profileStore.deleteProfile(id: profile.id, draftStore: draftStore, passwordStore: passwordStore)
            reloadSavedProfiles()
            if editingProfileId == profile.id {
                if let next = profileStore.mostRecentProfile() ?? savedProfiles.first {
                    selectSavedProfile(next.id)
                } else {
                    startNewConnection()
                }
            }
        } catch {
            testResultMessage = "Failed to delete profile: \(error.localizedDescription)"
            testResultIsError = true
        }
    }

    func cancelDeleteProfile() {
        profilePendingDelete = nil
        showingDeleteConfirmation = false
    }

    func chooseRootCertificateFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Custom CA Root Certificate"
        panel.message = "Select a PEM (.pem, .crt, .cer) CA certificate for TLS verification."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = []
        if let pem = UTType(filenameExtension: "pem") { types.append(pem) }
        if let crt = UTType(filenameExtension: "crt") { types.append(crt) }
        if let cer = UTType(filenameExtension: "cer") { types.append(cer) }
        types.append(.x509Certificate)
        panel.allowedContentTypes = types

        if panel.runModal() == .OK, let url = panel.url {
            sslRootCertPath = url.path
        }
    }

    func importConnectionUrl() {
        do {
            let parsed = try PostgresUrlParser.parse(connectionUrlInput)
            host = parsed.host
            port = String(parsed.port)
            database = parsed.database
            user = parsed.user
            password = parsed.password ?? ""
            sslMode = parsed.sslMode ?? "prefer"
            sslRootCertPath = parsed.sslRootCert ?? ""
            timeoutSeconds = Int(max(1, min(300, parsed.timeoutSeconds ?? 10)))

            let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty
                || trimmedName == "Local PostgreSQL"
                || trimmedName == "New PostgreSQL"
                || trimmedName == "PostgreSQL" {
                profileName = "\(parsed.database) @ \(parsed.host)"
            }

            // Clear credential-bearing URI immediately after successful parse
            connectionUrlInput = ""
            urlImportMessage = "Imported URL settings into fields below (URI cleared)."
            urlImportIsError = false
            testResultMessage = nil
            testResultIsError = false
        } catch {
            urlImportMessage = error.localizedDescription
            urlImportIsError = true
        }
    }

    func clearSensitiveTransientInputs() {
        connectionUrlInput = ""
    }

    func buildUpdatedProfile() -> ConnectionProfile {
        let trimmedCert = sslRootCertPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5432
        let clampedTimeout = UInt32(max(1, min(300, timeoutSeconds)))
        return ConnectionProfile(
            id: editingProfileId,
            name: profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "PostgreSQL" : profileName.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: parsedPort,
            database: database.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            sslMode: sslMode,
            sslRootCert: trimmedCert.isEmpty ? nil : trimmedCert,
            timeoutSeconds: clampedTimeout,
            rememberPassword: rememberPassword
        )
    }

    @discardableResult
    func persistCurrentProfile(markAsConnected: Bool) -> ConnectionProfile {
        let updated = buildUpdatedProfile()
        try? profileStore.saveOrUpdateProfile(
            updated,
            markAsConnected: markAsConnected,
            markSelected: true
        )
        if updated.rememberPassword {
            if !password.isEmpty {
                try? passwordStore.savePassword(profileId: updated.id, password: password)
            } else {
                try? passwordStore.deletePassword(profileId: updated.id)
            }
        } else {
            try? passwordStore.deletePassword(profileId: updated.id)
        }
        isEditingSavedProfile = true
        selectedSidebarProfileId = updated.id
        reloadSavedProfiles()
        return updated
    }

    func saveProfileOnly() {
        let saved = persistCurrentProfile(markAsConnected: false)
        testResultMessage = "Saved profile \"\(saved.name)\"."
        testResultIsError = false
    }

    func runConnectionTest() async {
        isTesting = true
        testResultMessage = nil
        testResultIsError = false

        let profile = buildUpdatedProfile()
        let config = profile.toRustConfig(password: password.isEmpty ? nil : password)

        do {
            let version = try await test_database_connection(config: config)
            testResultMessage = "Connected successfully: \(version)"
            testResultIsError = false
        } catch let error as LucidError {
            testResultMessage = error.userFacingMessage
            testResultIsError = true
        } catch {
            testResultMessage = error.userFacingMessage
            testResultIsError = true
        }

        isTesting = false
    }

    func passwordForSavedProfile(_ profile: ConnectionProfile) -> String? {
        guard profile.rememberPassword else { return nil }
        let value = try? passwordStore.getPassword(profileId: profile.id)
        return (value?.isEmpty == false) ? value : nil
    }

    func markProfileConnected(_ profile: ConnectionProfile) {
        try? profileStore.saveOrUpdateProfile(profile, markAsConnected: true, markSelected: true)
        reloadSavedProfiles()
    }
}

public struct ConnectionDialogView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ConnectionDialogModel
    private let onConnect: (ConnectionProfile, String?) -> Void

    public init(
        profile: ConnectionProfile = ConnectionProfile(),
        initialNotice: String? = nil,
        activeConnectedProfileId: UUID? = nil,
        profileStore: ConnectionProfileStore = ConnectionProfileStore(),
        draftStore: SqlDraftStore = SqlDraftStore(),
        passwordStore: any PasswordStoring = KeychainPasswordStore.shared,
        onProfilesChanged: (() -> Void)? = nil,
        onConnect: @escaping (ConnectionProfile, String?) -> Void
    ) {
        _model = StateObject(
            wrappedValue: ConnectionDialogModel(
                profile: profile,
                initialNotice: initialNotice,
                activeConnectedProfileId: activeConnectedProfileId,
                profileStore: profileStore,
                draftStore: draftStore,
                passwordStore: passwordStore,
                onProfilesChanged: onProfilesChanged
            )
        )
        self.onConnect = onConnect
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "server.rack")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("PostgreSQL Connections")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Select a saved profile, import a postgres:// URL, or configure credentials")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)

            Divider()

            HStack(spacing: 0) {
                // Saved Connections Picker Sidebar
                VStack(spacing: 0) {
                    HStack {
                        Text("SAVED PROFILES")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.startNewConnection()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("New Connection Profile")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    Divider()

                    if model.savedProfiles.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Text("No Saved Profiles")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Save or connect a profile to reuse it here.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 14)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: Binding(
                            get: { model.selectedSidebarProfileId },
                            set: { newId in
                                if let newId {
                                    model.selectSavedProfile(newId)
                                }
                            }
                        )) {
                            ForEach(model.savedProfiles) { profile in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                        Text("\(profile.user)@\(profile.host):\(profile.port)/\(profile.database)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    if !profile.rememberPassword {
                                        Image(systemName: "key.slash")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .help("Password is not stored in Keychain")
                                    }
                                }
                                .padding(.vertical, 3)
                                .tag(profile.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    quickConnectFromSidebar(profile)
                                }
                                .contextMenu {
                                    Button("Quick Connect") {
                                        quickConnectFromSidebar(profile)
                                    }
                                    Button("Duplicate") {
                                        model.duplicateProfile(profile.id)
                                    }
                                    Divider()
                                    Button("Delete...", role: .destructive) {
                                        model.requestDeleteProfile(profile.id)
                                    }
                                    .disabled(!model.canDeleteProfile(profile.id))
                                }
                            }
                        }
                        .listStyle(.sidebar)
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Button {
                            model.startNewConnection()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("New Profile")

                        Button {
                            if let id = model.selectedSidebarProfileId {
                                model.duplicateProfile(id)
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.selectedSidebarProfileId == nil)
                        .help("Duplicate Selected Profile")

                        Button {
                            if let id = model.selectedSidebarProfileId {
                                model.requestDeleteProfile(id)
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.selectedSidebarProfileId.map { !model.canDeleteProfile($0) } ?? true)
                        .help("Delete Selected Profile")

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(width: 245)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.45))

                Divider()

                // Detail Form Column
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            // URL Import Section
                            VStack(alignment: .leading, spacing: 6) {
                                Text("IMPORT CONNECTION URL")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 8) {
                                    SecureField("postgres://user:password@host:5432/database?sslmode=verify-full", text: $model.connectionUrlInput)
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.regular)
                                        .onSubmit {
                                            model.importConnectionUrl()
                                        }

                                    Button("Import URL") {
                                        model.importConnectionUrl()
                                    }
                                    .controlSize(.regular)
                                    .disabled(model.connectionUrlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }

                                if let urlMsg = model.urlImportMessage {
                                    Text(urlMsg)
                                        .font(.system(size: 11))
                                        .foregroundStyle(model.urlImportIsError ? .red : .green)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Supports postgres:// and postgresql://. Parsed locally, never logged or saved, and cleared on import.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5)
                            )

                            // Profile Section
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Profile")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)

                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                                    GridRow {
                                        Text("Name:")
                                            .gridColumnAlignment(.trailing)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                        TextField("Local PostgreSQL", text: $model.profileName)
                                            .textFieldStyle(.roundedBorder)
                                            .controlSize(.regular)
                                    }
                                }
                            }

                            // Server Section
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Database Server")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)

                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                                    GridRow {
                                        Text("Host:")
                                            .gridColumnAlignment(.trailing)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                        TextField("localhost", text: $model.host)
                                            .textFieldStyle(.roundedBorder)
                                            .controlSize(.regular)
                                    }

                                    GridRow {
                                        Text("Port:")
                                            .gridColumnAlignment(.trailing)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                        TextField("5432", text: $model.port)
                                            .textFieldStyle(.roundedBorder)
                                            .controlSize(.regular)
                                            .frame(width: 100)
                                    }

                                    GridRow {
                                        Text("Database:")
                                            .gridColumnAlignment(.trailing)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                        TextField("postgres", text: $model.database)
                                            .textFieldStyle(.roundedBorder)
                                            .controlSize(.regular)
                                    }
                                }
                            }

                            // Authentication Section
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Authentication")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)

                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                                    GridRow {
                                        Text("User:")
                                            .gridColumnAlignment(.trailing)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                        TextField("postgres", text: $model.user)
                                            .textFieldStyle(.roundedBorder)
                                            .controlSize(.regular)
                                    }

                                    GridRow {
                                        Text("Password:")
                                            .gridColumnAlignment(.trailing)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 6) {
                                            SecureField("Required if authentication enabled", text: $model.password)
                                                .textFieldStyle(.roundedBorder)
                                                .controlSize(.regular)
                                            Toggle("Remember password in macOS Keychain", isOn: $model.rememberPassword)
                                                .toggleStyle(.checkbox)
                                                .font(.system(size: 12))
                                            if !model.rememberPassword {
                                                Text("Password stays in memory only for this session and is removed from Keychain on Save/Connect.")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                }
                            }

                            // Network & Security Section
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Network & Security")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)

                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                                    GridRow {
                                        Text("SSL Mode:")
                                            .gridColumnAlignment(.trailing)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Picker("", selection: $model.sslMode) {
                                                    Text("Disable").tag("disable")
                                                    Text("Prefer").tag("prefer")
                                                    Text("Require").tag("require")
                                                    Text("Verify CA").tag("verify-ca")
                                                    Text("Verify Full").tag("verify-full")
                                                }
                                                .labelsHidden()
                                                .pickerStyle(.menu)
                                                .frame(width: 150)
                                                Spacer(minLength: 0)
                                            }
                                            Text(model.sslModeSummary)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }

                                    if model.requiresCaVerification {
                                        GridRow {
                                            Text("Root CA Cert:")
                                                .gridColumnAlignment(.trailing)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                            HStack(spacing: 6) {
                                                TextField("System root certificates (optional PEM path)", text: $model.sslRootCertPath)
                                                    .textFieldStyle(.roundedBorder)
                                                    .controlSize(.regular)
                                                Button("Browse...") {
                                                    model.chooseRootCertificateFile()
                                                }
                                                .controlSize(.small)
                                                if !model.sslRootCertPath.isEmpty {
                                                    Button("Clear") {
                                                        model.sslRootCertPath = ""
                                                    }
                                                    .controlSize(.small)
                                                }
                                            }
                                        }
                                    }

                                    GridRow {
                                        Text("Timeout:")
                                            .gridColumnAlignment(.trailing)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                        Stepper("\(model.timeoutSeconds)s", value: $model.timeoutSeconds, in: 1...300)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                    }

                    // Test / Save Callout
                    if let message = model.testResultMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: model.testResultIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(model.testResultIsError ? .red : .green)
                                .font(.system(size: 14))
                                .padding(.top, 1)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(model.testResultIsError ? Color.red.opacity(0.08) : Color.green.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(model.testResultIsError ? Color.red.opacity(0.25) : Color.green.opacity(0.25), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 22)
                        .padding(.bottom, 10)
                    }

                    Divider()

                    // Actions Footer
                    HStack(spacing: 10) {
                        SecondaryActionButton(
                            title: model.isTesting ? "Testing..." : "Test Connection",
                            icon: model.isTesting ? "" : "bolt.badge.checkmark",
                            size: .large
                        ) {
                            Task { @MainActor in
                                await model.runConnectionTest()
                            }
                        }
                        .disabled(model.isTesting || isRequiredFieldMissing)

                        SecondaryActionButton(
                            title: "Save",
                            icon: "square.and.arrow.down",
                            size: .large
                        ) {
                            model.saveProfileOnly()
                        }
                        .disabled(isRequiredFieldMissing)

                        Spacer()

                        SecondaryActionButton(
                            title: "Cancel",
                            size: .large
                        ) {
                            model.clearSensitiveTransientInputs()
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)

                        PrimaryActionButton(
                            title: "Connect",
                            icon: "checkmark",
                            size: .large
                        ) {
                            saveAndConnect()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isRequiredFieldMissing)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                }
            }
        }
        .frame(width: 800, height: 700)
        .background(VisualEffectBackground(material: .sheet, blendingMode: .behindWindow))
        .onDisappear {
            model.clearSensitiveTransientInputs()
        }
        .alert(
            "Delete Saved Connection?",
            isPresented: $model.showingDeleteConfirmation
        ) {
            Button("Delete Profile", role: .destructive) {
                model.confirmDeleteProfile()
            }
            Button("Cancel", role: .cancel) {
                model.cancelDeleteProfile()
            }
        } message: {
            if let profile = model.profilePendingDelete {
                Text("Delete \"\(profile.name)\" (\(profile.host):\(profile.port))? This removes the profile, its Keychain password, and any saved SQL drafts for it.")
            }
        }
    }

    private var isRequiredFieldMissing: Bool {
        model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveAndConnect() {
        let saved = model.persistCurrentProfile(markAsConnected: true)
        let sessionPassword = model.password.isEmpty ? nil : model.password
        model.clearSensitiveTransientInputs()
        onConnect(saved, sessionPassword)
        dismiss()
    }

    private func quickConnectFromSidebar(_ profile: ConnectionProfile) {
        model.selectSavedProfile(profile.id)
        if !profile.rememberPassword && model.password.isEmpty {
            model.testResultMessage = "Password is not stored in Keychain for \"\(profile.name)\". Enter your password and click Connect (or Connect without password)."
            model.testResultIsError = false
            return
        }
        let pw = model.password.isEmpty ? model.passwordForSavedProfile(profile) : model.password
        model.markProfileConnected(profile)
        model.clearSensitiveTransientInputs()
        onConnect(profile, pw)
        dismiss()
    }
}
