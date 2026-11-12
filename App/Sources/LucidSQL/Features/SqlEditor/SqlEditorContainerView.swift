import AppKit
import SwiftUI
import LucidSQLBridge

public struct SqlEditorContainerView: View {
    @Bindable public var workspace: SqlWorkspaceViewModel
    public let config: ConnectionConfig

    public init(workspace: SqlWorkspaceViewModel, config: ConnectionConfig) {
        self.workspace = workspace
        self.config = config
    }

    public init(viewModel: SqlEditorViewModel, config: ConnectionConfig) {
        let singleWorkspace = SqlWorkspaceViewModel()
        singleWorkspace.activateSingleTab(viewModel)
        self.workspace = singleWorkspace
        self.config = config
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabStripBar
            Divider()

            if let activeTab = workspace.activeTab {
                SqlTabContentView(viewModel: activeTab, config: config)
                    .id(activeTab.id)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Text("No SQL tabs open")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    SecondaryActionButton(title: "New SQL Tab", icon: "plus", size: .regular) {
                        workspace.createTab()
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(
            "Close Active SQL Tab?",
            isPresented: $workspace.showingCloseTabConfirmation,
            presenting: workspace.tabPendingClose
        ) { pendingTab in
            Button("Close & Rollback", role: .destructive) {
                Task { @MainActor in
                    await workspace.confirmClosePendingTab()
                }
            }
            Button("Keep Tab", role: .cancel) {
                workspace.cancelClosePendingTab()
            }
        } message: { pendingTab in
            Text(closeWarningMessage(for: pendingTab))
        }
    }

    private var tabStripBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        tabPill(for: tab)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()
                .frame(height: 16)

            Button {
                workspace.createTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New SQL Tab")
            .help("New SQL Tab (⌘T)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func tabPill(for tab: SqlEditorViewModel) -> some View {
        let isActive = workspace.activeTab?.id == tab.id

        HStack(spacing: 6) {
            tabStatusIndicator(for: tab)

            if workspace.renamingTabID == tab.id {
                TabRenameTextField(
                    text: $workspace.renameDraft,
                    onCommit: { committed in
                        workspace.renameTab(tab.id, to: committed)
                    },
                    onCancel: {
                        workspace.cancelRenaming()
                    }
                )
                .frame(width: 110, height: 18)
            } else {
                Text(tab.title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        beginRenaming(tab)
                    }
                    .onTapGesture(count: 1) {
                        workspace.selectTab(tab.id)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        workspace.selectTab(tab.id)
                    }
            }

            Button {
                workspace.requestCloseTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
            .help("Close \(tab.title)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color(NSColor.controlBackgroundColor) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    Color(NSColor.separatorColor).opacity(isActive ? 0.55 : 0.25),
                    lineWidth: isActive ? 0.75 : 0.5
                )
        )
        .contextMenu {
            Button("Rename Tab...") {
                beginRenaming(tab)
            }
            Button("New Tab") {
                workspace.createTab()
            }
            if tab.hasActiveSession && !tab.isRunning {
                Divider()
                Button("Reset Session") {
                    tab.reset()
                }
            }
            Divider()
            Button("Close Tab", role: .destructive) {
                workspace.requestCloseTab(tab.id)
            }
        }
    }

    @ViewBuilder
    private func tabStatusIndicator(for tab: SqlEditorViewModel) -> some View {
        if tab.isRunning {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.65)
                .frame(width: 10, height: 10)
                .help("Query running")
        } else if tab.transactionStatus == .inTransaction {
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .help("Active transaction (uncommitted)")
        } else if tab.transactionStatus == .failedTransaction {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .help("Transaction aborted (ROLLBACK required)")
        } else if tab.hasActiveSession {
            Circle()
                .fill(Color.green.opacity(0.8))
                .frame(width: 5, height: 5)
                .help("Dedicated session connected")
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
                .frame(width: 5, height: 5)
                .help("Lazy session (connects on first Run)")
        }
    }

    private func beginRenaming(_ tab: SqlEditorViewModel) {
        workspace.beginRenaming(tab.id)
    }

    private func closeWarningMessage(for tab: SqlEditorViewModel) -> String {
        var reasons: [String] = []
        if tab.isRunning {
            reasons.append("cancel its running query")
        }
        if tab.transactionStatus == .inTransaction || tab.transactionStatus == .failedTransaction {
            reasons.append("ROLLBACK its uncommitted transaction")
        }
        let summary = reasons.isEmpty ? "close its dedicated session" : reasons.joined(separator: " and ")
        return "Closing \"\(tab.title)\" will \(summary). Uncommitted changes in temporary tables or transactions will be discarded."
    }
}

private struct SqlTabContentView: View {
    @Bindable var viewModel: SqlEditorViewModel
    let config: ConnectionConfig

    var body: some View {
        VSplitView {
            // Top Section: SQL Editor & Action Bar
            VStack(spacing: 0) {
                // Editor Action Bar
                HStack(spacing: 10) {
                    if viewModel.isRunning {
                        SecondaryActionButton(
                            title: "Cancel",
                            icon: "xmark.circle.fill",
                            size: .regular
                        ) {
                            viewModel.cancelQuery()
                        }
                        .keyboardShortcut(".", modifiers: [.command])

                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, 4)

                        Text("Executing...")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        PrimaryActionButton(
                            title: "Run",
                            icon: "play.fill",
                            size: .regular
                        ) {
                            viewModel.executeQuery(config: config)
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .help("Execute SQL Query or Selection (⌘⏎)")

                        if let selected = viewModel.selectedSql, !selected.isEmpty {
                            Text("Selection (\(selected.count) chars)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }

                    Spacer()

                    // Dedicated Session Status Indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.hasActiveSession ? Color.green.opacity(0.85) : Color.secondary.opacity(0.35))
                            .frame(width: 5, height: 5)
                        Text(viewModel.hasActiveSession ? "Session Live" : "Lazy Session")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
                    .help(viewModel.hasActiveSession
                        ? "This tab holds a dedicated PostgreSQL session"
                        : "Dedicated PostgreSQL session will connect lazily when you execute SQL")

                    // Transaction Status Indicator
                    HStack(spacing: 5) {
                        Circle()
                            .fill(transactionStatusColor)
                            .frame(width: 6, height: 6)

                        Text(transactionStatusText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(transactionStatusColor)

                        if viewModel.transactionStatus == .failedTransaction {
                            Button("Rollback") {
                                viewModel.rollback(config: config)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(.red)
                            .help("Issue ROLLBACK to unblock the aborted transaction")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(transactionStatusColor.opacity(0.12), in: Capsule())

                    // Read-Only Guardrail Toggle
                    Button {
                        viewModel.toggleReadOnly(config: config)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: viewModel.isReadOnly ? "lock.fill" : "lock.open")
                                .font(.system(size: 10))
                            Text(viewModel.isReadOnly ? "Read-Only" : "Read-Write")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(viewModel.isReadOnly ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.1), in: Capsule())
                        .foregroundStyle(viewModel.isReadOnly ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.isReadOnly
                        ? "Read-only guardrail is active: writes and DDL are blocked. Click to switch to Read-Write."
                        : "Click to enable read-only guardrail (prevents accidental writes/DDL in this session)")

                    // Safety row limit badge
                    Text("Limit: \(viewModel.maxRows) rows")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())

                    Button {
                        viewModel.sqlText = ""
                        viewModel.selectedSql = nil
                        viewModel.selectedRange = NSRange(location: 0, length: 0)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear SQL Editor")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)

                if let banner = viewModel.sessionBannerMessage {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text(banner)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            viewModel.sessionBannerMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss notice")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.08))
                }

                Divider()

                // Syntax Text View
                SqlEditorTextView(
                    text: $viewModel.sqlText,
                    selectedRange: $viewModel.selectedRange,
                    onSelectionChanged: { selection in
                        viewModel.selectedSql = selection
                    },
                    onExecute: { sqlToRun in
                        viewModel.executeQuery(config: config, selectionOnly: sqlToRun)
                    }
                )
                .id(viewModel.id)
                .frame(minHeight: 120)
                .background(Color(NSColor.textBackgroundColor))
            }
            .frame(minHeight: 150)

            // Bottom Section: Results & Status Area
            VStack(spacing: 0) {
                Divider()

                switch viewModel.queryState {
                case .idle:
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "terminal")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("Enter SQL above and press ⌘⏎ to execute")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))

                case .running(_, let startedAt):
                    VStack(spacing: 14) {
                        Spacer()
                        ProgressView()
                            .controlSize(.regular)
                        Text("Query in progress on \(config.host):\(config.port)...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        TimelineView(.periodic(from: startedAt, by: 0.1)) { timeline in
                            let elapsed = timeline.date.timeIntervalSince(startedAt)
                            Text(String(format: "Elapsed: %.1fs", elapsed))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))

                case .error(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.system(size: 16))
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Execution Failed")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.red)

                                Text(message)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)

                                if viewModel.transactionStatus == .failedTransaction {
                                    HStack(spacing: 8) {
                                        Text("Transaction aborted: commands are ignored until ROLLBACK.")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)

                                        Spacer()

                                        SecondaryActionButton(
                                            title: "Rollback Transaction",
                                            icon: "arrow.uturn.backward",
                                            size: .small
                                        ) {
                                            viewModel.rollback(config: config)
                                        }
                                    }
                                    .padding(.top, 6)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
                        )
                        .padding(16)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))

                case .success(let result):
                    if !result.columns.isEmpty {
                        // Tabular query result (SELECT, SHOW, EXPLAIN, RETURNING)
                        VStack(spacing: 0) {
                            QueryResultsGridView(result: result)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(NSColor.textBackgroundColor))

                            Divider()

                            // Footer Status Bar
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)

                                Text(result.statusMessage)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                if result.isTruncated {
                                    Text("LIMIT REACHED")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.orange.opacity(0.12), in: Capsule())
                                }

                                Spacer()

                                Text("\(result.columns.count) columns")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                        }
                    } else {
                        // Command complete result (INSERT, UPDATE, DELETE, DDL)
                        VStack(spacing: 14) {
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.12))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.green)
                            }

                            Text(result.statusMessage)
                                .font(.system(size: 13, weight: .medium))

                            if let affected = result.affectedRows {
                                Text("\(affected) rows modified")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Text("Finished in \(result.executionDurationMs) ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)

                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.textBackgroundColor))
                    }
                }
            }
            .frame(minHeight: 180)
        }
    }

    private var transactionStatusColor: Color {
        switch viewModel.transactionStatus {
        case .idle:
            return Color.secondary
        case .inTransaction:
            return Color.orange
        case .failedTransaction:
            return Color.red
        }
    }

    private var transactionStatusText: String {
        switch viewModel.transactionStatus {
        case .idle:
            return "Idle"
        case .inTransaction:
            return "In Transaction"
        case .failedTransaction:
            return "Tx Aborted"
        }
    }
}

private struct TabRenameTextField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        field.focusRingType = .none
        field.delegate = context.coordinator
        let coord = context.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak field, weak coord] in
            guard let field, let coord, let window = field.window else { return }
            if window.makeFirstResponder(field) {
                field.selectText(nil)
                coord.didAcquireFocus = true
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text && nsView.currentEditor() == nil {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TabRenameTextField
        var didAcquireFocus = false
        private var finished = false

        init(_ parent: TabRenameTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            didAcquireFocus = true
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard didAcquireFocus, !finished, let field = obj.object as? NSTextField else { return }
            finished = true
            parent.onCommit(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finished = true
                parent.onCommit(control.stringValue)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finished = true
                parent.onCancel()
                return true
            }
            return false
        }
    }
}
