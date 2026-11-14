import Foundation
import Testing
@testable import LucidSQL
import LucidSQLBridge

@Suite("CSV Export & Streaming Isolation Tests", .serialized)
struct CsvExportTests {
    private struct ParsedCsvField: Equatable {
        let value: String
        let wasQuoted: Bool
    }

    private func getLocalConfig() -> ConnectionConfig {
        ConnectionConfig(
            host: "localhost",
            port: 5432,
            database: "postgres",
            user: NSUserName(),
            password: nil,
            sslMode: "disable",
            sslRootCert: nil,
            timeoutSeconds: 5
        )
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LucidSQLCsvTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Independent RFC 4180 CSV parser preserving whether each field was explicitly quoted,
    /// allowing exact distinction between SQL NULL (unquoted empty) and empty string ("").
    private func parseCsvWithQuoteTracking(_ text: String) -> [[ParsedCsvField]] {
        var rows: [[ParsedCsvField]] = []
        var currentRow: [ParsedCsvField] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var atFieldStart = true

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                if atFieldStart && ch == "\"" {
                    inQuotes = true
                    fieldWasQuoted = true
                    atFieldStart = false
                } else if ch == "," {
                    currentRow.append(ParsedCsvField(value: field, wasQuoted: fieldWasQuoted))
                    field = ""
                    fieldWasQuoted = false
                    atFieldStart = true
                } else if ch == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" {
                    currentRow.append(ParsedCsvField(value: field, wasQuoted: fieldWasQuoted))
                    rows.append(currentRow)
                    currentRow = []
                    field = ""
                    fieldWasQuoted = false
                    atFieldStart = true
                    i += 2
                    continue
                } else if ch == "\n" {
                    currentRow.append(ParsedCsvField(value: field, wasQuoted: fieldWasQuoted))
                    rows.append(currentRow)
                    currentRow = []
                    field = ""
                    fieldWasQuoted = false
                    atFieldStart = true
                } else {
                    field.append(ch)
                    atFieldStart = false
                }
            }
            i += 1
        }

        if !atFieldStart || !currentRow.isEmpty {
            currentRow.append(ParsedCsvField(value: field, wasQuoted: fieldWasQuoted))
            rows.append(currentRow)
        }

        return rows
    }

    @Test("SQL fetched results export warns on truncation and rejects unsupported placeholder columns")
    @MainActor
    func testSqlFetchedExportTruncationAndUnsupportedHandling() async throws {
        let config = getLocalConfig()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tab = SqlEditorViewModel(title: "Sales Summary")
        tab.maxRows = 5
        tab.executeQuery(
            config: config,
            selectionOnly: """
            SELECT g AS id,
                   CASE WHEN g = 1 THEN 'hello, "world"' || chr(10) || 'café 🚀' ELSE 'row ' || g END AS note,
                   CASE WHEN g = 1 THEN '' WHEN g = 2 THEN NULL ELSE 'NULL' END AS nullable_col,
                   -98765432109876543210.1234567890::numeric AS precise_num
            FROM generate_series(1, 12) AS g;
            """
        )

        for _ in 0..<80 {
            if !tab.isRunning { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let sqlExportVM = tab.prepareFetchedResultsExport()
        #expect(sqlExportVM != nil)
        #expect(sqlExportVM?.isSqlTarget == true)
        #expect(sqlExportVM?.isTruncatedSqlResult == true)
        #expect(sqlExportVM?.fetchedRowCount == 5)
        #expect(sqlExportVM?.canStartExport == true)

        let outURL = dir.appendingPathComponent("sql_fetched.csv")
        let result = await sqlExportVM?.exportToDestination(outURL)
        #expect(result?.rowsExported == 5)
        #expect(sqlExportVM?.statusMessage?.contains("partial fetched set") == true)

        let raw = try String(contentsOf: outURL, encoding: .utf8)
        let parsed = parseCsvWithQuoteTracking(raw)
        // Header + 5 fetched rows (NOT 12)
        #expect(parsed.count == 6)
        #expect(parsed[0].map(\.value) == ["id", "note", "nullable_col", "precise_num"])

        // Row 1: quotes, comma, newline, Unicode, empty string (""), exact negative decimal
        #expect(parsed[1][0] == ParsedCsvField(value: "1", wasQuoted: false))
        #expect(parsed[1][1] == ParsedCsvField(value: "hello, \"world\"\ncafé 🚀", wasQuoted: true))
        #expect(parsed[1][2] == ParsedCsvField(value: "", wasQuoted: true))
        #expect(parsed[1][3] == ParsedCsvField(value: "-98765432109876543210.1234567890", wasQuoted: false))

        // Row 2: SQL NULL is unquoted empty
        #expect(parsed[2][2] == ParsedCsvField(value: "", wasQuoted: false))
        // Row 3: literal text "NULL" stays unquoted literal "NULL"
        #expect(parsed[3][2] == ParsedCsvField(value: "NULL", wasQuoted: false))

        // Now verify unsupported column in fetched SQL result refuses placeholder export
        let unsupTab = SqlEditorViewModel(title: "Unsupported Type Check")
        unsupTab.executeQuery(config: config, selectionOnly: "SELECT 1 AS id, '10 20 30'::int2vector AS vec;")
        for _ in 0..<80 {
            if !unsupTab.isRunning { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let unsupVM = unsupTab.prepareFetchedResultsExport()
        #expect(unsupVM != nil)
        #expect(unsupVM?.canStartExport == false)
        #expect(unsupVM?.unsupportedFetchedColumnDetails == ["vec (int2vector)"])

        // Even calling exportToDestination programmatically rejects without clobbering existing destination
        let protectedURL = dir.appendingPathComponent("protected.csv")
        try "stay-safe\n".write(to: protectedURL, atomically: true, encoding: .utf8)
        let blockedRes = await unsupVM?.exportToDestination(protectedURL)
        #expect(blockedRes == nil)
        #expect(unsupVM?.errorMessage?.contains("int2vector") == true)
        #expect(try String(contentsOf: protectedURL, encoding: .utf8) == "stay-safe\n")

        _ = try? await close_session(sessionId: tab.sessionId)
        _ = try? await close_session(sessionId: unsupTab.sessionId)
    }

    @Test("Table export distinguishes current page vs >100 streaming all-rows, excludes staged edits, and keeps SQL session intact")
    @MainActor
    func testTableCurrentPageVsStreamingFullExportAndStagedExclusion() async throws {
        let config = getLocalConfig()
        let dir = try makeTempDir()
        let schemaName = "lucidsql_swift_export_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
        let sessionId = "tab_keep_alive_\(UUID().uuidString)"

        defer {
            Task {
                _ = try? await close_session(sessionId: sessionId)
                _ = try? await execute_query(
                    config: config,
                    sql: "DROP SCHEMA IF EXISTS \"\(schemaName)\" CASCADE;",
                    queryId: UUID().uuidString
                )
            }
            try? FileManager.default.removeItem(at: dir)
        }

        let setupSql = """
        CREATE SCHEMA "\(schemaName)";
        CREATE TABLE "\(schemaName)".records (
            id INT PRIMARY KEY,
            label TEXT,
            blank_or_null TEXT,
            exact_amount NUMERIC(28, 8),
            span INTERVAL
        );
        INSERT INTO "\(schemaName)".records
        SELECT
            g,
            CASE
                WHEN g = 1 THEN E'First, "quoted"\nline2 — Unicode ✓'
                WHEN g = 2 THEN 'NULL'
                ELSE 'Row #' || g
            END,
            CASE
                WHEN g = 1 THEN ''
                WHEN g = 2 THEN NULL
                ELSE 'v' || g
            END,
            CASE
                WHEN g = 3 THEN -999999999999999999.87654321::numeric
                ELSE (g::numeric + 0.12345678::numeric)
            END,
            (g || ' days')::interval
        FROM generate_series(1, 140) AS g;
        """

        _ = try await execute_query(
            config: config,
            sql: setupSql,
            queryId: UUID().uuidString
        )

        // Open an active transaction in the SQL tab to ensure export does not disturb it
        let txStart = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "BEGIN; INSERT INTO \"\(schemaName)\".records VALUES (9999, 'UNCOMMITTED_SQL_TAB', '', 0, '0 days');",
            queryId: UUID().uuidString,
            maxRows: 100,
            readOnly: false
        )
        #expect(txStart.transactionStatus == .inTransaction)

        // Load table in TableDataViewModel (page size 100 of 140) and stage local grid mutations
        let tableVM = TableDataViewModel()
        tableVM.limit = 100
        await tableVM.loadTable(config: config, schema: schemaName, table: "records")
        tableVM.sortColumn = "id"
        tableVM.sortDescending = false
        await tableVM.fetchPage(config: config)

        #expect(tableVM.rows.count == 100)
        #expect(tableVM.hasMore == true)

        tableVM.stageTextEdit(row: 0, column: 1, text: "STAGED_LOCAL_EDIT_MUST_NOT_EXPORT")
        tableVM.stageDeleteRow(row: 1)
        tableVM.addDraftRow()
        tableVM.stageTextEdit(row: 100, column: 0, text: "8888")
        tableVM.stageTextEdit(row: 100, column: 1, text: "STAGED_DRAFT_MUST_NOT_EXPORT")
        #expect(tableVM.totalStagedOperationsCount == 3)

        // Check staged-changes warning + scope choices on export view model
        let exportVM = tableVM.prepareCsvExport(config: config, initialScope: .currentPage)
        #expect(exportVM != nil)
        #expect(exportVM?.hasPendingStagedTableChanges == true)
        #expect(exportVM?.pendingStagedSummary.contains("3 unapplied staged changes") == true)

        // 1) Current fetched page: must warn/block if `span (interval)` is Unsupported in fetched page,
        //    so let's also verify a separate page-exportable query AND verify full streaming `All Rows` exports `interval`!
        #expect(exportVM?.tableScope == .currentPage)
        #expect(exportVM?.unsupportedFetchedColumnDetails == ["span (interval)"])
        #expect(exportVM?.canStartExport == false)

        // Switch to All Rows in Table (streams PostgreSQL ::text for `interval`)
        exportVM?.tableScope = .allRows
        #expect(exportVM?.canStartExport == true)

        let fullOutURL = dir.appendingPathComponent("records_all.csv")
        let fullRes = await exportVM?.exportToDestination(fullOutURL)
        #expect(fullRes?.rowsExported == 140)
        #expect(fullRes?.snapshotIsolation == "REPEATABLE READ READ ONLY")

        let fullCsv = try String(contentsOf: fullOutURL, encoding: .utf8)
        let fullParsed = parseCsvWithQuoteTracking(fullCsv)
        #expect(fullParsed.count == 141) // Header + 140 rows
        #expect(fullParsed[0].map(\.value) == ["id", "label", "blank_or_null", "exact_amount", "span"])
        #expect(!fullCsv.contains("_lucid_xmin"))
        #expect(!fullCsv.contains("STAGED_LOCAL_EDIT_MUST_NOT_EXPORT"))
        #expect(!fullCsv.contains("STAGED_DRAFT_MUST_NOT_EXPORT"))
        #expect(!fullCsv.contains("UNCOMMITTED_SQL_TAB"))
        #expect(!fullCsv.contains("Unsupported"))

        // Verify row 1..3 parsed fields and PostgreSQL ::text for interval + NULL vs ""
        #expect(fullParsed[1][1] == ParsedCsvField(value: "First, \"quoted\"\nline2 — Unicode ✓", wasQuoted: true))
        #expect(fullParsed[1][2] == ParsedCsvField(value: "", wasQuoted: true))
        #expect(fullParsed[1][4] == ParsedCsvField(value: "1 day", wasQuoted: false))
        #expect(fullParsed[2][1] == ParsedCsvField(value: "NULL", wasQuoted: false))
        #expect(fullParsed[2][2] == ParsedCsvField(value: "", wasQuoted: false))
        #expect(fullParsed[3][3] == ParsedCsvField(value: "-999999999999999999.87654321", wasQuoted: false))
        #expect(fullParsed[140][0] == ParsedCsvField(value: "140", wasQuoted: false))

        // Verify page export count on a table without unmapped interval type (create 115-row simple table)
        _ = try await execute_query(
            config: config,
            sql: """
            CREATE TABLE "\(schemaName)".paged_only AS
            SELECT g AS id, 'row_' || g AS name FROM generate_series(1, 115) AS g;
            ALTER TABLE "\(schemaName)".paged_only ADD PRIMARY KEY (id);
            """,
            queryId: UUID().uuidString
        )

        let pageVM = TableDataViewModel()
        pageVM.limit = 100
        await pageVM.loadTable(config: config, schema: schemaName, table: "paged_only")
        #expect(pageVM.rows.count == 100)
        pageVM.stageTextEdit(row: 0, column: 1, text: "LOCAL_EDIT_EXCLUDED")

        let pagedExportVM = pageVM.prepareCsvExport(config: config, initialScope: .currentPage)
        let pageURL = dir.appendingPathComponent("paged_only_page.csv")
        let pageRes = await pagedExportVM?.exportToDestination(pageURL)
        #expect(pageRes?.rowsExported == 100)

        let pageCsv = try String(contentsOf: pageURL, encoding: .utf8)
        let pageParsed = parseCsvWithQuoteTracking(pageCsv)
        #expect(pageParsed.count == 101) // Header + 100 fetched page rows only
        #expect(!pageCsv.contains("_lucid_xmin"))
        #expect(!pageCsv.contains("LOCAL_EDIT_EXCLUDED"))

        // Verify SQL-tab open transaction stayed intact the entire time
        let sessionInfo = try await get_session_info(sessionId: sessionId)
        #expect(sessionInfo.transactionStatus == .inTransaction)

        // Verify clean temp directory (only the 2 finalized CSVs)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(Set(files) == ["paged_only_page.csv", "records_all.csv"])

        // Cleanup open transaction, session, and schema synchronously
        _ = try await execute_session_query(
            config: config,
            sessionId: sessionId,
            sql: "ROLLBACK;",
            queryId: UUID().uuidString,
            maxRows: 10,
            readOnly: false
        )
        _ = try? await close_session(sessionId: sessionId)
        _ = try? await execute_query(
            config: config,
            sql: "DROP SCHEMA IF EXISTS \"\(schemaName)\" CASCADE;",
            queryId: UUID().uuidString
        )
    }

    @Test("Export cancellation cleans temporary files and preserves pre-existing destination")
    @MainActor
    func testSwiftViewModelCancellationCleanupAndOverwriteSafety() async throws {
        let config = getLocalConfig()
        let dir = try makeTempDir()
        let schemaName = "lucidsql_swift_expcancel_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"

        defer {
            Task {
                _ = try? await execute_query(
                    config: config,
                    sql: "DROP SCHEMA IF EXISTS \"\(schemaName)\" CASCADE;",
                    queryId: UUID().uuidString
                )
            }
            try? FileManager.default.removeItem(at: dir)
        }

        _ = try await execute_query(
            config: config,
            sql: """
            CREATE SCHEMA "\(schemaName)";
            CREATE VIEW "\(schemaName)".slow_export AS
            SELECT g AS id,
                   CASE WHEN g = 150 THEN pg_sleep(15)::text ELSE 'item_' || g END AS val
            FROM generate_series(1, 300) AS g;
            """,
            queryId: UUID().uuidString
        )

        let existingDest = dir.appendingPathComponent("keep_me.csv")
        try "existing,data\n1,safe\n".write(to: existingDest, atomically: true, encoding: .utf8)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: schemaName, table: "slow_export")

        let exportVM = vm.prepareCsvExport(config: config, initialScope: .allRows)!
        exportVM.startExport(to: existingDest)

        for _ in 0..<40 {
            if exportVM.rowsExportedSoFar > 0 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(exportVM.isExporting == true)

        exportVM.cancelExport()

        for _ in 0..<80 {
            if !exportVM.isExporting { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(exportVM.isExporting == false)
        #expect(exportVM.lastResult == nil)
        #expect(exportVM.statusMessage?.contains("cancelled") == true)
        #expect(try String(contentsOf: existingDest, encoding: .utf8) == "existing,data\n1,safe\n")

        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remainingFiles == ["keep_me.csv"])

        _ = try? await execute_query(
            config: config,
            sql: "DROP SCHEMA IF EXISTS \"\(schemaName)\" CASCADE;",
            queryId: UUID().uuidString
        )
    }
}
