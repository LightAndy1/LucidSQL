import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LucidSQLBridge

@MainActor
final class ConnectionDialogModel: ObservableObject {
    @Published var profileName: String
    @Published var host: String
    @Published var port: String
    @Published var database: String
    @Published var user: String
    @Published var password: String
    @Published var sslMode: String
    @Published var sslRootCertPath: String
    @Published var timeoutSeconds: Int

    @Published var isTesting: Bool = false
    @Published var testResultMessage: String? = nil
    @Published var testResultIsError: Bool = false

    fileprivate let initialProfile: ConnectionProfile

    init(profile: ConnectionProfile) {
        self.initialProfile = profile
        self.profileName = profile.name
        self.host = profile.host
        self.port = String(profile.port)
        self.database = profile.database
        self.user = profile.user
        self.password = (try? KeychainService.getPassword(profileId: profile.id)) ?? ""
        self.sslMode = profile.sslMode
        self.sslRootCertPath = profile.sslRootCert ?? ""
        self.timeoutSeconds = Int(profile.timeoutSeconds)
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

    func buildUpdatedProfile() -> ConnectionProfile {
        let trimmedCert = sslRootCertPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectionProfile(
            id: initialProfile.id,
            name: profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "PostgreSQL" : profileName,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: UInt16(port) ?? 5432,
            database: database.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            sslMode: sslMode,
            sslRootCert: trimmedCert.isEmpty ? nil : trimmedCert,
            timeoutSeconds: UInt32(timeoutSeconds)
        )
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
}

public struct ConnectionDialogView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ConnectionDialogModel
    private let profileStore: ConnectionProfileStore
    private let onConnect: (ConnectionProfile, String?) -> Void

    public init(
        profile: ConnectionProfile = ConnectionProfile(),
        profileStore: ConnectionProfileStore = ConnectionProfileStore(),
        onConnect: @escaping (ConnectionProfile, String?) -> Void
    ) {
        _model = StateObject(wrappedValue: ConnectionDialogModel(profile: profile))
        self.profileStore = profileStore
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
                    Text("PostgreSQL Connection")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Enter database connection settings and credentials")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)

            Divider()

            // Native Form with clearly identifiable native editable TextFields
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                                SecureField("Required if authentication enabled", text: $model.password)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.regular)
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
                                Stepper("\(model.timeoutSeconds)s", value: $model.timeoutSeconds, in: 2...60)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            // Test Result Callout
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
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            Divider()

            // Actions Footer with Untinted Native Glass Capsule Actions
            HStack(spacing: 12) {
                SecondaryActionButton(
                    title: model.isTesting ? "Testing..." : "Test Connection",
                    icon: model.isTesting ? "" : "bolt.badge.checkmark",
                    size: .large
                ) {
                    Task { @MainActor in
                        await model.runConnectionTest()
                    }
                }
                .disabled(model.isTesting || model.host.isEmpty || model.database.isEmpty || model.user.isEmpty)

                Spacer()

                SecondaryActionButton(
                    title: "Cancel",
                    size: .large
                ) {
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
                .disabled(model.host.isEmpty || model.database.isEmpty || model.user.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 560, height: 650)
        .background(VisualEffectBackground(material: .sheet, blendingMode: .behindWindow))
    }

    private func saveAndConnect() {
        let editedProfile = model.buildUpdatedProfile()
        let resolvedProfile = profileStore.resolveProfileForConnect(
            initialProfile: model.initialProfile,
            editedProfile: editedProfile
        )
        try? profileStore.saveOrUpdateProfile(resolvedProfile)
        if !model.password.isEmpty {
            try? KeychainService.savePassword(profileId: resolvedProfile.id, password: model.password)
        }

        onConnect(resolvedProfile, model.password.isEmpty ? nil : model.password)
        dismiss()
    }
}
