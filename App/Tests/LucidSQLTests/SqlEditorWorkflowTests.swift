import Foundation
import Testing
@testable import LucidSQL
import LucidSQLBridge

@Suite("SQL Editor & Query Execution Workflow Tests")
struct SqlEditorWorkflowTests {
    private func getLocalConfig() -> ConnectionConfig {
        let user = NSUserName()
        return ConnectionConfig(
            host: "localhost",
            port: 5432,
            database: "postgres",
            user: user,
            password: nil,
            sslMode: "disable",
            timeoutSeconds: 5
        )
    }

    @Test("Verify SqlEditorViewModel initial state and target selection")
    @MainActor
    func testViewModelInitialState() {
        let vm = SqlEditorViewModel()
        #expect(!vm.sqlText.isEmpty)
        #expect(vm.queryState == .idle)
        #expect(vm.isRunning == false)
        #expect(vm.activeQueryId == nil)
        #expect(vm.maxRows == 1000)
    }

    @Test("Verify execute_query returns tabular rows for SELECT statements")
    func testExecuteQuerySelect() async throws {
        let config = getLocalConfig()
        let queryId = UUID().uuidString
        let sql = "SELECT 42 as num, 'LucidSQL' as app_name, true as is_fast;"

        let result = try await execute_query(config: config, sql: sql, queryId: queryId)

        #expect(result.columns.count == 3)
        #expect(result.columns[0].name == "num")
        #expect(result.columns[1].name == "app_name")
        #expect(result.columns[2].name == "is_fast")

        #expect(result.rows.count == 1)
        #expect(result.rows[0].cells[0] == .integer(42))
        #expect(result.rows[0].cells[1] == .text("LucidSQL"))
        #expect(result.rows[0].cells[2] == .boolean(true))
        #expect(result.affectedRows == nil)
        #expect(!result.isTruncated)
    }

    @Test("Verify execute_query returns affected row count for DDL/DML statements")
    func testExecuteQueryDdlDml() async throws {
        let config = getLocalConfig()

        let tableName = "lucidsql_test_dml_\(Int.random(in: 1000...9999))"

        let createSql = "CREATE TABLE \(tableName) (id int, val text);"
        let createRes = try await execute_query(config: config, sql: createSql, queryId: UUID().uuidString)
        #expect(createRes.columns.isEmpty)
        #expect(createRes.rows.isEmpty)

        // Insert rows
        let insertSql = "INSERT INTO \(tableName) VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');"
        let insertRes = try await execute_query(config: config, sql: insertSql, queryId: UUID().uuidString)
        #expect(insertRes.columns.isEmpty)
        #expect(insertRes.affectedRows == 3)

        // Update rows
        let updateSql = "UPDATE \(tableName) SET val = 'updated' WHERE id > 1;"
        let updateRes = try await execute_query(config: config, sql: updateSql, queryId: UUID().uuidString)
        #expect(updateRes.affectedRows == 2)

        // Cleanup
        _ = try? await execute_query(config: config, sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
    }

    @Test("Verify readable PostgreSQL error reporting on syntax error")
    func testSyntaxErrorReporting() async throws {
        let config = getLocalConfig()
        let queryId = UUID().uuidString
        let invalidSql = "SELECT FROM WHERE;"

        do {
            _ = try await execute_query(config: config, sql: invalidSql, queryId: queryId)
            #expect(Bool(false), "Expected syntax error")
        } catch let LucidError.DatabaseError(code, message, _) {
            #expect(code == "42601") // PostgreSQL syntax error SQLSTATE
            #expect(!message.isEmpty)
        } catch {
            #expect(Bool(false), "Expected LucidError.DatabaseError, got: \(error)")
        }
    }

    @Test("Verify query row limit and truncation flag")
    func testRowLimitTruncation() async throws {
        let config = getLocalConfig()
        let queryId = UUID().uuidString
        // Query returning 20 rows with a 5 row limit
        let sql = "SELECT generate_series(1, 20) as n;"

        let result = try await execute_query(config: config, sql: sql, queryId: queryId, maxRows: 5)
        #expect(result.rows.count == 5)
        #expect(result.isTruncated == true)
        #expect(result.statusMessage.contains("truncated"))
    }

    @Test("Verify live query cancellation via cancel_query")
    func testQueryCancellation() async throws {
        let config = getLocalConfig()
        let queryId = UUID().uuidString

        // Start a 3-second sleep query in the background
        let queryTask = Task { () -> Result<QueryResult, Error> in
            do {
                let res = try await execute_query(
                    config: config,
                    sql: "SELECT pg_sleep(3);",
                    queryId: queryId
                )
                return .success(res)
            } catch {
                return .failure(error)
            }
        }

        // Give the query 200ms to reach PostgreSQL
        try await Task.sleep(nanoseconds: 200_000_000)

        // Issue cancellation
        let cancelled = try await cancel_query(queryId: queryId)
        #expect(cancelled == true)

        let result = await queryTask.value
        switch result {
        case .failure(let error):
            if case LucidError.QueryCancelled = error {
                #expect(true)
            } else {
                #expect(Bool(false), "Expected LucidError.QueryCancelled, got \(error)")
            }
        case .success:
            #expect(Bool(false), "Query should have been cancelled before completing")
        }
    }

    @Test("Verify dedicated session state persistence (SET timezone)")
    func testSessionStatePersistence() async throws {
        let config = getLocalConfig()
        let sessionId = "swift_test_session_state_\(UUID().uuidString)"

        // Query 1: Set timezone
        let res1 = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "SET timezone = 'America/New_York';",
            queryId: UUID().uuidString
        )
        #expect(res1.transactionStatus == .idle)

        // Query 2: Check timezone on the same session
        let res2 = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "SHOW timezone;",
            queryId: UUID().uuidString
        )
        #expect(res2.rows.count == 1)
        #expect(res2.rows[0].cells[0] == .text("America/New_York"))

        try await close_session(sessionId: sessionId)
    }

    @Test("Verify dedicated session temp table persistence across queries")
    func testSessionTempTablePersistence() async throws {
        let config = getLocalConfig()
        let sessionId = "swift_test_temp_table_\(UUID().uuidString)"

        // Query 1: Create temp table and insert rows
        let setupSql = "CREATE TEMP TABLE t_swift_items (id int, name text); INSERT INTO t_swift_items VALUES (1, 'Mango'), (2, 'Papaya');"
        let res1 = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: setupSql,
            queryId: UUID().uuidString
        )
        #expect(res1.affectedRows == 2)

        // Query 2: Query the temporary table
        let querySql = "SELECT id, name FROM t_swift_items ORDER BY id;"
        let res2 = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: querySql,
            queryId: UUID().uuidString
        )
        #expect(res2.rows.count == 2)
        #expect(res2.rows[0].cells[1] == .text("Mango"))
        #expect(res2.rows[1].cells[1] == .text("Papaya"))

        try await close_session(sessionId: sessionId)
    }

    @Test("Verify transaction lifecycle: BEGIN -> InTransaction, ROLLBACK -> Idle")
    func testTransactionCommitAndRollback() async throws {
        let config = getLocalConfig()
        let sessionId = "swift_test_tx_\(UUID().uuidString)"

        // 1. BEGIN
        let beginRes = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "BEGIN;",
            queryId: UUID().uuidString
        )
        #expect(beginRes.transactionStatus == .inTransaction)

        // 2. ROLLBACK
        let rollbackRes = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "ROLLBACK;",
            queryId: UUID().uuidString
        )
        #expect(rollbackRes.transactionStatus == .idle)

        try await close_session(sessionId: sessionId)
    }

    @Test("Verify aborted transaction handling and recovery via ROLLBACK")
    func testAbortedTransactionAndRecovery() async throws {
        let config = getLocalConfig()
        let sessionId = "swift_test_abort_\(UUID().uuidString)"

        // 1. BEGIN
        let beginRes = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "BEGIN;",
            queryId: UUID().uuidString
        )
        #expect(beginRes.transactionStatus == .inTransaction)

        // 2. Failing statement inside transaction
        do {
            _ = try await execute_session_query(
                config: config,
                sessionId: sessionId,
                sql: "SELECT 1/0;",
                queryId: UUID().uuidString
            )
            #expect(Bool(false), "Expected division by zero error")
        } catch {
            #expect(true)
        }

        // Verify session status is FailedTransaction
        let info = try await get_session_info(sessionId: sessionId)
        #expect(info.transactionStatus == .failedTransaction)

        // 3. Normal statement fails with 25P02
        do {
            _ = try await execute_session_query(
                config: config,
                sessionId: sessionId,
                sql: "SELECT 1;",
                queryId: UUID().uuidString
            )
            #expect(Bool(false), "Expected 25P02 error")
        } catch let LucidError.DatabaseError(code, _, _) {
            #expect(code == "25P02")
        } catch {
            #expect(Bool(false), "Expected DatabaseError with 25P02, got: \(error)")
        }

        // 4. ROLLBACK restores Idle
        let rollbackRes = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "ROLLBACK;",
            queryId: UUID().uuidString
        )
        #expect(rollbackRes.transactionStatus == .idle)

        // 5. Subsequent statement succeeds
        let successRes = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "SELECT 100 as test_val;",
            queryId: UUID().uuidString
        )
        #expect(successRes.rows.count == 1)

        try await close_session(sessionId: sessionId)
    }

    @Test("Verify multi-statement script execution with strings containing semicolons and comments")
    func testMultiStatementScript() async throws {
        let config = getLocalConfig()
        let sessionId = "swift_test_multi_\(UUID().uuidString)"

        let script = """
        -- Setup table
        CREATE TEMP TABLE t_swift_multi (id int, comment text);
        /* Insert with semicolon in string */
        INSERT INTO t_swift_multi VALUES (1, 'data; with semicolon; inside');
        SELECT comment FROM t_swift_multi WHERE id = 1;
        """

        let result = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: script,
            queryId: UUID().uuidString
        )

        #expect(result.rows.count == 1)
        #expect(result.rows[0].cells[0] == .text("data; with semicolon; inside"))
        #expect(result.statusMessage.contains("3 statements executed"))

        try await close_session(sessionId: sessionId)
    }

    @Test("Verify accidental-write read-only mode enforcement")
    func testAccidentalWriteReadOnlyMode() async throws {
        let config = getLocalConfig()
        let sessionId = "swift_test_ro_\(UUID().uuidString)"

        // 1. Establish session in read-only mode
        let initRes = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "SELECT 777 as safe_val;",
            queryId: UUID().uuidString,
            readOnly: true
        )
        #expect(initRes.rows.count == 1)

        // Verify session metadata reflects read-only
        let info = try await get_session_info(sessionId: sessionId)
        #expect(info.isReadOnly == true)

        // 2. Direct mutation should be rejected by ReadOnlyViolation
        do {
            _ = try await execute_session_query(
                config: config,
                sessionId: sessionId,
                sql: "INSERT INTO dummy_tbl VALUES (1);",
                queryId: UUID().uuidString,
                readOnly: true
            )
            #expect(Bool(false), "Expected ReadOnlyViolation")
        } catch let LucidError.ReadOnlyViolation(op) {
            #expect(!op.isEmpty)
        } catch {
            #expect(Bool(false), "Expected ReadOnlyViolation, got: \(error)")
        }

        // 3. Attempting to disable read-only via SQL should be rejected
        do {
            _ = try await execute_session_query(
                config: config,
                sessionId: sessionId,
                sql: "SET default_transaction_read_only = off;",
                queryId: UUID().uuidString,
                readOnly: true
            )
            #expect(Bool(false), "Expected ReadOnlyViolation")
        } catch let LucidError.ReadOnlyViolation(op) {
            #expect(!op.isEmpty)
        } catch {
            #expect(Bool(false), "Expected ReadOnlyViolation, got: \(error)")
        }

        // 4. Read query succeeds
        let readRes = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "SELECT 888 as safe_val;",
            queryId: UUID().uuidString,
            readOnly: true
        )
        #expect(readRes.rows.count == 1)

        // 5. Test dynamic toggle to read-write
        let updatedInfo = try await set_session_read_only(sessionId: sessionId, readOnly: false)
        #expect(updatedInfo.isReadOnly == false)

        try await close_session(sessionId: sessionId)
    }
}
