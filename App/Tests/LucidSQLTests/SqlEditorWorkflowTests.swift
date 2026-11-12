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
}
