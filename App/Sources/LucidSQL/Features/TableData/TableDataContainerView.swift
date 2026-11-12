import SwiftUI
import LucidSQLBridge

public struct TableDataContainerView: View {
    public let viewModel: TableDataViewModel
    public let config: ConnectionConfig

    public init(viewModel: TableDataViewModel, config: ConnectionConfig) {
        self.viewModel = viewModel
        self.config = config
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 10) {
                // Table Identity
                HStack(spacing: 6) {
                    Image(systemName: "tablecells.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)

                    Text(viewModel.currentTable)
                        .font(.system(size: 13, weight: .semibold))

                    Text(viewModel.currentSchema)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())

                    if viewModel.columns.contains(where: { $0.isPrimaryKey }) {
                        HStack(spacing: 3) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                            Text("PK")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }

                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }

                // Compact Pagination Controls
                HStack(spacing: 5) {
                    Button {
                        Task { await viewModel.previousPage(config: config) }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.offset == 0 || viewModel.isLoading)
                    .help("Previous Page")

                    Text(rowCountText)
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    Button {
                        Task { await viewModel.nextPage(config: config) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!viewModel.hasMore || viewModel.isLoading)
                    .help("Next Page")

                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, 2)

                    Button {
                        Task { await viewModel.fetchPage(config: config) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isLoading)
                    .help("Reload Table")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            // Error Banner if present
            if let error = viewModel.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                Divider()
            }

            // Grid View or Empty State - stable readable surface
            if viewModel.rows.isEmpty && !viewModel.isLoading {
                VStack(spacing: 12) {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                            .frame(width: 54, height: 54)
                        Image(systemName: "tablecells")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                    }
                    Text("No records found in \(viewModel.currentTable)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
            } else {
                DataTableView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
            }

            Divider()

            // Footer Status Bar
            HStack {
                Text("\(viewModel.rows.count) rows fetched in \(viewModel.executionDurationMs) ms (\(viewModel.columns.count) columns)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                if !viewModel.stagedEdits.isEmpty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("\(viewModel.stagedEdits.count) staged changes")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
        }
    }

    private var rowCountText: String {
        if viewModel.rows.isEmpty {
            return "0 rows"
        }
        return "\(viewModel.offset + 1)–\(viewModel.offset + UInt64(viewModel.rows.count))"
    }
}
