import Foundation
import Observation
import LucidSQLBridge

@Observable
public final class SqlEditorViewModel: @unchecked Sendable {
    public var sqlText: String = """
    -- Write your PostgreSQL query here
    -- Press ⌘⏎ to execute the query or selection
    SELECT table_schema, table_name, table_type 
    FROM information_schema.tables 
    LIMIT 20;
    """

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

    public var sessionId: String = UUID().uuidString
    public var transactionStatus: TransactionStatus = .idle
    public var isReadOnly: Bool = false

    private var executionTask: Task<Void, Never>? = nil

    public init() {}

    @MainActor
    public func executeQuery(config: ConnectionConfig, selectionOnly: String? = nil) {
        // Cancel any already running query before starting a new one
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

        executionTask = Task { [weak self, config, currentSessionId, queryId, maxRows, currentReadOnly] in
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
                    self.queryState = .success(result)
                    self.transactionStatus = result.transactionStatus
                    self.activeQueryId = nil
                }
            } catch let error as LucidError {
                await MainActor.run {
                    guard let self = self, self.activeQueryId == queryId else { return }
                    self.activeQueryId = nil

                    if case .DatabaseError(let code, _, _) = error, code == "25P02" {
                        self.transactionStatus = .failedTransaction
                    } else if case .QueryCancelled = error, self.transactionStatus == .inTransaction {
                        self.transactionStatus = .failedTransaction
                    }

                    switch error {
                    case .QueryCancelled:
                        self.queryState = .error("Query was cancelled by user.")
                    case .QueryTimedOut(let durationMs):
                        self.queryState = .error("Query timed out after \(durationMs) ms.")
                    case .DatabaseError(let code, let message, _):
                        self.queryState = .error("[\(code)] \(message)")
                    case .AuthenticationFailed(let message):
                        self.queryState = .error("Authentication failed: \(message)")
                    case .ConnectionFailed(let reason):
                        self.queryState = .error("Connection failed: \(reason)")
                    case .ReadOnlyViolation(let op):
                        self.queryState = .error("Read-Only Mode: \(op)")
                    default:
                        self.queryState = .error(error.localizedDescription)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self = self, self.activeQueryId == queryId else { return }
                    self.activeQueryId = nil
                    self.queryState = .error(error.localizedDescription)
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
        let currentSessionId = self.sessionId

        Task {
            do {
                _ = try await set_session_read_only(sessionId: currentSessionId, readOnly: newSetting)
                await MainActor.run {
                    self.isReadOnly = newSetting
                }
            } catch {
                // If session is not yet established, update locally so the next query initializes read-only
                await MainActor.run {
                    self.isReadOnly = newSetting
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
        cancelQuery()
        self.sessionId = UUID().uuidString
        self.transactionStatus = .idle
        self.queryState = .idle
        self.activeQueryId = nil

        Task {
            try? await close_session(sessionId: oldSessionId)
        }
    }
}
