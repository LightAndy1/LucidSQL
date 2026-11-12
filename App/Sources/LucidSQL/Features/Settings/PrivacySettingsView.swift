import SwiftUI

@MainActor
private final class PrivacySettingsLocalState: ObservableObject {
    @Published var showingClearDraftsConfirmation: Bool = false
    @Published var statusBannerText: String? = nil
    @Published var statusIsError: Bool = false
}

public struct PrivacySettingsView: View {
    @ObservedObject var workspaceModel: WorkspaceModel
    @ObservedObject var preferences: PrivacyPreferencesStore
    @StateObject private var localState = PrivacySettingsLocalState()
    @Environment(\.dismiss) private var dismiss

    public init(workspaceModel: WorkspaceModel, preferences: PrivacyPreferencesStore) {
        self.workspaceModel = workspaceModel
        self.preferences = preferences
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "lock.doc")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings & Draft Privacy")
                        .font(.system(size: 16, weight: .bold))
                    Text("Control how SQL editor tabs and local drafts are stored on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                GroupBox("SQL Draft Persistence") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(
                            "Save SQL editor drafts locally across app restarts",
                            isOn: Binding(
                                get: { preferences.isSqlDraftPersistenceEnabled },
                                set: { newValue in
                                    do {
                                        try workspaceModel.sqlWorkspace.setDraftPersistenceEnabled(newValue)
                                        localState.statusIsError = false
                                        localState.statusBannerText = newValue
                                            ? "Local SQL draft persistence enabled."
                                            : "Local SQL draft persistence disabled and previously saved SQL drafts removed from disk."
                                    } catch {
                                        localState.statusIsError = true
                                        localState.statusBannerText = "Failed to update draft persistence: \(error.localizedDescription)"
                                    }
                                }
                            )
                        )
                        .font(.system(size: 13, weight: .medium))

                        Text("SQL text may contain sensitive tokens, literals, or customer identifiers. When enabled, LucidSQL stores tab names, SQL draft text, and cursor selections in Application Support. Passwords (Keychain) and query results are never written to draft storage. Disabling deletes any saved drafts immediately and keeps open tabs working strictly in memory.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Saved SQL Drafts on Disk")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Removes persisted SQL drafts for all connection profiles without closing active tabs.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Clear Saved SQL Drafts...", role: .destructive) {
                                localState.showingClearDraftsConfirmation = true
                            }
                            .controlSize(.regular)
                        }
                    }
                    .padding(10)
                }

                if let statusBannerText = localState.statusBannerText {
                    HStack(spacing: 8) {
                        Image(systemName: localState.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(localState.statusIsError ? .red : .green)
                            .font(.system(size: 12))
                        Text(statusBannerText)
                            .font(.system(size: 11))
                            .foregroundStyle(localState.statusIsError ? .red : .primary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill((localState.statusIsError ? Color.red : Color.green).opacity(0.09))
                    )
                }
            }
            .padding(20)

            Spacer(minLength: 0)

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 370)
        .alert("Clear Saved SQL Drafts?", isPresented: $localState.showingClearDraftsConfirmation) {
            Button("Clear Saved Drafts", role: .destructive) {
                do {
                    try workspaceModel.sqlWorkspace.clearSavedDrafts()
                    localState.statusIsError = false
                    localState.statusBannerText = "Cleared all saved SQL drafts from local disk."
                } catch {
                    localState.statusIsError = true
                    localState.statusBannerText = "Failed to clear saved SQL drafts: \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all saved SQL draft files from disk for every connection profile. Your currently open SQL tabs remain editable in memory.")
        }
    }
}
