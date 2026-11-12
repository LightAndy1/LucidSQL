import Foundation
import Testing
@testable import LucidSQL
import LucidSQLBridge

@Suite("Table Data View Model & Cell Value Tests")
struct TableDataViewModelTests {
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

    @Test("Verify initial view model state")
    func testInitialState() {
        let vm = TableDataViewModel()
        #expect(vm.columns.isEmpty)
        #expect(vm.rows.isEmpty)
        #expect(vm.offset == 0)
        #expect(vm.limit == 100)
        #expect(vm.hasMore == false)
        #expect(vm.isLoading == false)
        #expect(vm.stagedEdits.isEmpty)
    }

    @Test("Verify staging cell edits and discarding changes")
    func testStagedEdits() {
        let vm = TableDataViewModel()
        let coord = TableDataViewModel.GridCoordinate(row: 2, column: 3)

        // Mock column so isEditable passes
        vm.columns = [
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false),
            ColumnMetadata(name: "col1", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false),
            ColumnMetadata(name: "col2", ordinalPosition: 3, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false),
            ColumnMetadata(name: "col3", ordinalPosition: 4, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false),
        ]

        vm.setCellValue(row: 2, column: 3, value: .text("updated_value"))
        #expect(vm.stagedEdits[coord] == .text("updated_value"))
        #expect(vm.stagedEdits.count == 1)

        vm.discardChanges()
        #expect(vm.stagedEdits.isEmpty)
    }

    @Test("Verify CellValue display string and null checks")
    func testCellValueDisplay() {
        #expect(CellValue.null.isNull == true)
        #expect(CellValue.null.displayString == "NULL")

        #expect(CellValue.text("hello").isNull == false)
        #expect(CellValue.text("hello").displayString == "hello")

        #expect(CellValue.integer(42).displayString == "42")
        #expect(CellValue.boolean(true).displayString == "true")
        #expect(CellValue.boolean(false).displayString == "false")
        #expect(CellValue.decimal("123456789.987654321").displayString == "123456789.987654321")
        #expect(CellValue.uuid("550e8400-e29b-41d4-a716-446655440000").displayString == "550e8400-e29b-41d4-a716-446655440000")
        #expect(CellValue.binaryHex("\\x010203").displayString == "\\x010203")
    }

    @Test("Verify single primary key in-grid editing and atomic apply")
    func testSinglePrimaryKeyEditingAndSuccess() async throws {
        let config = getLocalConfig()
        let tableName = "t_swift_single_pk_\(Int.random(in: 1000...9999))"

        let setupSql = """
        DROP TABLE IF EXISTS \(tableName);
        CREATE TABLE \(tableName) (id serial PRIMARY KEY, title text, price numeric(12, 4), note text);
        INSERT INTO \(tableName) (title, price, note) VALUES ('Notebook', 12.5000, 'initial');
        """
        _ = try await execute_session_query(config: config, sessionId: "setup", sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        #expect(vm.hasPrimaryKey == true)
        #expect(vm.isEditable == true)
        #expect(vm.rows.count == 1)

        // Stage edit for price (index 2) and note (index 3)
        // columns: [id (0), title (1), price (2), note (3)]
        vm.stageTextEdit(row: 0, column: 2, text: "14.9950")
        vm.stageNullEdit(row: 0, column: 3)

        #expect(vm.stagedEdits.count == 2)
        let diffs = vm.stagedDiffs
        #expect(diffs.count == 2)
        #expect(diffs[0].columnName == "price")
        #expect(diffs[0].newValue == .decimal("14.9950"))
        #expect(diffs[1].columnName == "note")
        #expect(diffs[1].newValue == .null)

        // Apply edits
        await vm.applyStagedEdits(config: config)
        #expect(vm.errorMessage == nil)
        #expect(vm.stagedEdits.isEmpty)
        #expect(vm.statusMessage?.contains("Successfully applied") == true)

        // Verify DB value
        let verifySql = "SELECT price::text, note FROM \(tableName) WHERE id = 1;"
        let res = try await execute_session_query(config: config, sessionId: "verify", sql: verifySql, queryId: UUID().uuidString)
        #expect(res.rows.count == 1)
        #expect(res.rows[0].cells[0] == .text("14.9950"))
        #expect(res.rows[0].cells[1] == .null)

        // Cleanup
        _ = try? await execute_session_query(config: config, sessionId: "cleanup", sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
    }

    @Test("Verify composite primary key editing and parameterization")
    func testCompositePrimaryKeyEditing() async throws {
        let config = getLocalConfig()
        let tableName = "t_swift_composite_pk_\(Int.random(in: 1000...9999))"

        let setupSql = """
        DROP TABLE IF EXISTS \(tableName);
        CREATE TABLE \(tableName) (dept_id int, emp_id int, name text, active bool, PRIMARY KEY (dept_id, emp_id));
        INSERT INTO \(tableName) VALUES (1, 101, 'Carol', false);
        """
        _ = try await execute_session_query(config: config, sessionId: "setup", sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        let pkCols = vm.columns.filter(\.isPrimaryKey)
        #expect(pkCols.count == 2)
        #expect(vm.isEditable == true)

        // Stage edit on name (col 2) and active (col 3)
        vm.stageTextEdit(row: 0, column: 2, text: "Carol Danvers")
        vm.stageTextEdit(row: 0, column: 3, text: "true")

        await vm.applyStagedEdits(config: config)
        #expect(vm.errorMessage == nil)
        #expect(vm.stagedEdits.isEmpty)

        // Verify in DB
        let verifySql = "SELECT name, active FROM \(tableName) WHERE dept_id = 1 AND emp_id = 101;"
        let res = try await execute_session_query(config: config, sessionId: "verify", sql: verifySql, queryId: UUID().uuidString)
        #expect(res.rows.count == 1)
        #expect(res.rows[0].cells[0] == .text("Carol Danvers"))
        #expect(res.rows[0].cells[1] == .boolean(true))

        _ = try? await execute_session_query(config: config, sessionId: "cleanup", sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
    }

    @Test("Verify distinction between NULL and empty string")
    func testNullVsEmptyStringEditing() async throws {
        let config = getLocalConfig()
        let tableName = "t_swift_null_empty_\(Int.random(in: 1000...9999))"

        let setupSql = """
        DROP TABLE IF EXISTS \(tableName);
        CREATE TABLE \(tableName) (id int PRIMARY KEY, col_null text, col_empty text);
        INSERT INTO \(tableName) VALUES (1, 'initial_a', 'initial_b');
        """
        _ = try await execute_session_query(config: config, sessionId: "setup", sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        // Stage NULL for col_null (col 1), empty string for col_empty (col 2)
        vm.stageNullEdit(row: 0, column: 1)
        vm.stageTextEdit(row: 0, column: 2, text: "")

        #expect(vm.stagedEdits[TableDataViewModel.GridCoordinate(row: 0, column: 1)] == .null)
        #expect(vm.stagedEdits[TableDataViewModel.GridCoordinate(row: 0, column: 2)] == .text(""))

        await vm.applyStagedEdits(config: config)
        #expect(vm.errorMessage == nil)

        // Check DB
        let verifySql = "SELECT col_null, col_empty, (col_null IS NULL) as is_null, (col_empty = '') as is_empty FROM \(tableName) WHERE id = 1;"
        let res = try await execute_session_query(config: config, sessionId: "verify", sql: verifySql, queryId: UUID().uuidString)
        #expect(res.rows[0].cells[0] == .null)
        #expect(res.rows[0].cells[1] == .text(""))
        #expect(res.rows[0].cells[2] == .boolean(true))
        #expect(res.rows[0].cells[3] == .boolean(true))

        _ = try? await execute_session_query(config: config, sessionId: "cleanup", sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
    }

    @Test("Verify concurrent modification conflict detection with xmin rollback")
    func testConcurrentModificationConflictDetection() async throws {
        let config = getLocalConfig()
        let tableName = "t_swift_conflict_\(Int.random(in: 1000...9999))"

        let setupSql = """
        DROP TABLE IF EXISTS \(tableName);
        CREATE TABLE \(tableName) (id int PRIMARY KEY, count int);
        INSERT INTO \(tableName) VALUES (1, 100);
        """
        _ = try await execute_session_query(config: config, sessionId: "setup", sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        // Stage edit in Swift memory
        vm.stageTextEdit(row: 0, column: 1, text: "150")

        // Concurrent update in background advancing row xmin
        _ = try await execute_session_query(
            config: config,
            sessionId: "concurrent_updater",
            sql: "UPDATE \(tableName) SET count = 200 WHERE id = 1;",
            queryId: UUID().uuidString
        )

        // Now try applying staged edits in ViewModel
        await vm.applyStagedEdits(config: config)

        // Must report conflict and preserve staged edits in memory
        #expect(vm.errorMessage?.contains("Conflict detected") == true)
        #expect(!vm.stagedEdits.isEmpty)

        // Verify DB still holds concurrent value 200 (not overwritten)
        let checkRes = try await execute_session_query(config: config, sessionId: "check", sql: "SELECT count FROM \(tableName) WHERE id = 1;", queryId: UUID().uuidString)
        #expect(checkRes.rows[0].cells[0] == .integer(200))

        _ = try? await execute_session_query(config: config, sessionId: "cleanup", sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
    }

    @Test("Verify atomic batch rollback when one row update fails")
    func testAtomicBatchRollbackOnFailure() async throws {
        let config = getLocalConfig()
        let tableName = "t_swift_atomic_\(Int.random(in: 1000...9999))"

        let setupSql = """
        DROP TABLE IF EXISTS \(tableName);
        CREATE TABLE \(tableName) (id int PRIMARY KEY, score int CHECK (score >= 0));
        INSERT INTO \(tableName) VALUES (1, 50), (2, 80);
        """
        _ = try await execute_session_query(config: config, sessionId: "setup", sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        // Edit row 1: valid score 60
        vm.stageTextEdit(row: 0, column: 1, text: "60")
        // Edit row 2: invalid score -10 (violates check constraint)
        vm.stageTextEdit(row: 1, column: 1, text: "-10")

        await vm.applyStagedEdits(config: config)
        #expect(vm.errorMessage != nil)

        // Verify row 1 was NOT modified (atomic rollback preserved original 50)
        let checkRes = try await execute_session_query(config: config, sessionId: "check", sql: "SELECT score FROM \(tableName) ORDER BY id;", queryId: UUID().uuidString)
        #expect(checkRes.rows[0].cells[0] == .integer(50))
        #expect(checkRes.rows[1].cells[0] == .integer(80))

        _ = try? await execute_session_query(config: config, sessionId: "cleanup", sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
    }

    @Test("Verify read-only guardrail rejection in table mutation")
    func testReadOnlyRejection() async throws {
        let config = getLocalConfig()
        let tableName = "t_swift_ro_\(Int.random(in: 1000...9999))"

        let setupSql = """
        DROP TABLE IF EXISTS \(tableName);
        CREATE TABLE \(tableName) (id int PRIMARY KEY, name text);
        INSERT INTO \(tableName) VALUES (1, 'Initial');
        """
        _ = try await execute_session_query(config: config, sessionId: "setup", sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        // Turn on read-only
        vm.isReadOnly = true
        #expect(vm.isEditable == false)
        #expect(vm.nonEditableReason?.contains("Read-only") == true)

        // Attempting to stage or apply in read-only mode
        vm.stageTextEdit(row: 0, column: 1, text: "Attempted Edit")
        #expect(vm.stagedEdits.isEmpty) // Blocked by isEditable guard

        _ = try? await execute_session_query(config: config, sessionId: "cleanup", sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
    }

    @Test("Verify unsupported table without primary key is read-only")
    func testUnsupportedTableWithoutPrimaryKey() async throws {
        let config = getLocalConfig()
        let tableName = "t_swift_no_pk_\(Int.random(in: 1000...9999))"

        let setupSql = """
        DROP TABLE IF EXISTS \(tableName);
        CREATE TABLE \(tableName) (val text, num int);
        INSERT INTO \(tableName) VALUES ('a', 1);
        """
        _ = try await execute_session_query(config: config, sessionId: "setup", sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        #expect(vm.hasPrimaryKey == false)
        #expect(vm.isEditable == false)
        #expect(vm.nonEditableReason?.contains("no primary key") == true)
        #expect(vm.buildBatchMutationRequest() == nil)

        _ = try? await execute_session_query(config: config, sessionId: "cleanup", sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
    }
}
