import SwiftUI
import LucidSQLBridge

public struct SqlEditorContainerView: View {
    @Bindable public var viewModel: SqlEditorViewModel
    public let config: ConnectionConfig

    public init(viewModel: SqlEditorViewModel, config: ConnectionConfig) {
        self.viewModel = viewModel
        self.config = config
    }

    public var body: some View {
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

                Divider()

                // Syntax Text View
                SqlEditorTextView(
                    text: $viewModel.sqlText,
                    onSelectionChanged: { selection in
                        viewModel.selectedSql = selection
                    },
                    onExecute: { sqlToRun in
                        viewModel.executeQuery(config: config, selectionOnly: sqlToRun)
                    }
                )
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
