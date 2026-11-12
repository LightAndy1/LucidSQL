import Foundation
import Observation
import LucidSQLBridge

@Observable
public final class SqlEditorViewModel: Identifiable, @unchecked Sendable {
    public static let defaultStarterSql: String = """
    -- Write your PostgreSQL query here
    -- Press ⌘⏎ to execute the query or selection
    SELECT table_schema, table_name, table_type 
    FROM information_schema.tables 
    LIMIT 20;
    """

    public let id: UUID
    public var title: String
    public var sqlText: String {
        didSet {
            if sqlText != oldValue {
                onDraftChanged?()
            }
        }
    }
    public var selectedRange: NSRange = NSRange(location: 0, length: 0) {
        didSet {
            if selectedRange != oldValue {
                onDraftChanged?()
            }
        }
    }

    public enum QueryState: Equatable {
        case idle
        case running(queryId: String, startedAt: Date)
        case success(QueryResult)
        case error(String)
    }

    public var queryState: QueryState = .idle
    public var activeQueryId: String? = nil
    public var isRunning: Bool {
        if case .running = queryState { return true }
        return false
    }

    public var selectedSql: String? = nil
    public var maxRows: UInt32 = 1000

    public var sessionId: String
    public var hasActiveSession: Bool = false
    public var transactionStatus: TransactionStatus = .idle
    public var isReadOnly: Bool = false
    public var sessionBannerMessage: String? = nil
    public var onReadOnlyChanged: ((Bool) -> Void)? = nil
    public var onDraftChanged: (() -> Void)? = nil

    private var executionTask: Task<Void, Never>? = nil

    public init(
        id: UUID = UUID(),
        title: String = "Query 1",
        sqlText: String = SqlEditorViewModel.defaultStarterSql,
        selectedRange: NSRange = NSRange(location: 0, length: 0),
        isReadOnly: Bool = false,
        sessionBannerMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sqlText = sqlText
        self.selectedRange = selectedRange
        self.sessionId = "tab_\(id.uuidString)"
        self.isReadOnly = isReadOnly
        self.sessionBannerMessage = sessionBannerMessage
    }

    @MainActor
    public func executeQuery(config: ConnectionConfig, selectionOnly: String? = nil) {
        // Cancel any already running query in this tab before starting a new one
        cancelQuery()

        let rawTarget = selectionOnly ?? selectedSql ?? sqlText
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            self.queryState = .error("Query is empty. Enter a SQL statement to execute.")
            return
        }

        let queryId = UUID().uuidString
        self.activeQueryId = queryId
        self.queryState = .running(queryId: queryId, startedAt: Date())

        let currentSessionId = self.sessionId
        let currentReadOnly = self.isReadOnly
        let hadLiveSessionBeforeExecution = self.hasActiveSession

        executionTask = Task { [weak self, config, currentSessionId, queryId, maxRows, currentReadOnly, hadLiveSessionBeforeExecution] in
            do {
                let result = try await execute_session_query(
                    config: config,
                    sessionId: currentSessionId,
                    sql: trimmed,
                    queryId: queryId,
                    maxRows: maxRows,
                    readOnly: currentReadOnly
                )

                await MainActor.run {
                    guard let self = self, self.activeQueryId == queryId else { return }
                    self.hasActiveSession = true
                    self.sessionBannerMessage = nil
                    self.queryState = .success(result)
                    self.transactionStatus = result.transactionStatus
                    self.activeQueryId = nil
                }
            } catch let error as LucidError {
                await MainActor.run {
                    guard let self = self, self.activeQueryId == queryId else { return }
                    self.activeQueryId = nil

                    switch error {
                    case .QueryCancelled:
                        if self.transactionStatus == .inTransaction {
                            self.transactionStatus = .failedTransaction
                        }
                        self.queryState = .error("Query was cancelled by user.")
                    case .QueryTimedOut(let durationMs):
                        if self.transactionStatus == .inTransaction {
                            self.transactionStatus = .failedTransaction
                        }
                        self.queryState = .error("Query timed out after \(durationMs) ms.")
                    case .DatabaseError(let code, let message, _):
                        self.hasActiveSession = true
                        self.sessionBannerMessage = nil
                        if code == "25P02" || self.transactionStatus == .inTransaction {
                            self.transactionStatus = .failedTransaction
                        }
                        self.queryState = .error("[\(code)] \(message)")
                    case .AuthenticationFailed(let message):
                        self.hasActiveSession = false
                        self.transactionStatus = .idle
                        self.queryState = .error("Authentication failed: \(message)")
                    case .ConnectionFailed(let reason):
                        self.hasActiveSession = false
                        self.transactionStatus = .idle
                        if hadLiveSessionBeforeExecution || reason.lowercased().contains("lost") || reason.lowercased().contains("closed") {
                            self.sessionBannerMessage = "Session connection was lost. Temporary tables, session settings, and any uncommitted transactions from the prior connection were discarded."
                        }
                        self.queryState = .error("Connection failed: \(reason)")
                    case .ReadOnlyViolation(let op):
                        self.queryState = .error("Read-Only Mode: \(op)")
                    default:
                        self.queryState = .error(error.userFacingMessage)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self = self, self.activeQueryId == queryId else { return }
                    self.activeQueryId = nil
                    self.queryState = .error(error.userFacingMessage)
                }
            }
        }
    }

    @MainActor
    public func cancelQuery() {
        guard let queryId = activeQueryId else { return }
        self.activeQueryId = nil
        self.executionTask?.cancel()
        self.executionTask = nil
        if transactionStatus == .inTransaction {
            self.transactionStatus = .failedTransaction
        }
        self.queryState = .error("Query was cancelled.")

        Task {
            _ = try? await cancel_query(queryId: queryId)
        }
    }

    @MainActor
    public func toggleReadOnly(config: ConnectionConfig) {
        if transactionStatus == .inTransaction {
            self.queryState = .error("Cannot toggle read-only mode while inside an active transaction. Commit or rollback first.")
            return
        }

        let newSetting = !isReadOnly
        guard hasActiveSession else {
            self.isReadOnly = newSetting
            self.onReadOnlyChanged?(newSetting)
            self.onDraftChanged?()
            return
        }

        let currentSessionId = self.sessionId

        Task {
            do {
                _ = try await set_session_read_only(sessionId: currentSessionId, readOnly: newSetting)
                await MainActor.run {
                    self.isReadOnly = newSetting
                    self.onReadOnlyChanged?(newSetting)
                    self.onDraftChanged?()
                }
            } catch {
                await MainActor.run {
                    self.hasActiveSession = false
                    self.isReadOnly = newSetting
                    self.onReadOnlyChanged?(newSetting)
                    self.onDraftChanged?()
                }
            }
        }
    }

    @MainActor
    public func rollback(config: ConnectionConfig) {
        executeQuery(config: config, selectionOnly: "ROLLBACK;")
    }

    @MainActor
    public func reset() {
        let oldSessionId = sessionId
        let shouldClose = hasActiveSession || activeQueryId != nil
        cancelQuery()
        self.sessionId = "tab_\(id.uuidString)_\(UUID().uuidString.prefix(8))"
        self.hasActiveSession = false
        self.transactionStatus = .idle
        self.queryState = .idle
        self.activeQueryId = nil
        self.sessionBannerMessage = nil

        if shouldClose {
            Task {
                try? await close_session(sessionId: oldSessionId)
            }
        }
    }

    @MainActor
    public func cancelAndCloseSession(bannerMessage: String? = nil) async {
        let oldSessionId = sessionId
        let pendingQueryId = activeQueryId
        let shouldClose = hasActiveSession || pendingQueryId != nil

        if let queryId = pendingQueryId {
            self.activeQueryId = nil
            self.executionTask?.cancel()
            self.executionTask = nil
            self.queryState = .error("Query was cancelled.")
            _ = try? await cancel_query(queryId: queryId)
        }

        if shouldClose {
            try? await close_session(sessionId: oldSessionId)
        }

        self.sessionId = "tab_\(id.uuidString)_\(UUID().uuidString.prefix(8))"
        self.hasActiveSession = false
        self.transactionStatus = .idle
        self.activeQueryId = nil
        if let bannerMessage {
            self.sessionBannerMessage = bannerMessage
        }
    }
}
