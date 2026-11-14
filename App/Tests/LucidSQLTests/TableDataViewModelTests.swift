import AppKit
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
            sslRootCert: nil,
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
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "col1", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "col2", ordinalPosition: 3, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "col3", ordinalPosition: 4, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
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
        _ = try await execute_query(config: config, sql: setupSql, queryId: UUID().uuidString)

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
        let res = try await execute_query(config: config, sql: verifySql, queryId: UUID().uuidString)
        #expect(res.rows.count == 1)
        #expect(res.rows[0].cells[0] == .text("14.9950"))
        #expect(res.rows[0].cells[1] == .null)

        // Cleanup
        _ = try? await execute_query(config: config, sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
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
        _ = try await execute_query(config: config, sql: setupSql, queryId: UUID().uuidString)

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
        let res = try await execute_query(config: config, sql: verifySql, queryId: UUID().uuidString)
        #expect(res.rows.count == 1)
        #expect(res.rows[0].cells[0] == .text("Carol Danvers"))
        #expect(res.rows[0].cells[1] == .boolean(true))

        _ = try? await execute_query(config: config, sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
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
        _ = try await execute_query(config: config, sql: setupSql, queryId: UUID().uuidString)

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
        let res = try await execute_query(config: config, sql: verifySql, queryId: UUID().uuidString)
        #expect(res.rows[0].cells[0] == .null)
        #expect(res.rows[0].cells[1] == .text(""))
        #expect(res.rows[0].cells[2] == .boolean(true))
        #expect(res.rows[0].cells[3] == .boolean(true))

        _ = try? await execute_query(config: config, sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
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
        _ = try await execute_query(config: config, sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        // Stage edit in Swift memory
        vm.stageTextEdit(row: 0, column: 1, text: "150")

        // Concurrent update in background advancing row xmin
        _ = try await execute_query(
            config: config,
            sql: "UPDATE \(tableName) SET count = 200 WHERE id = 1;",
            queryId: UUID().uuidString
        )

        // Now try applying staged edits in ViewModel
        await vm.applyStagedEdits(config: config)

        // Must report conflict and preserve staged edits in memory
        #expect(vm.errorMessage?.contains("Conflict detected") == true)
        #expect(!vm.stagedEdits.isEmpty)

        // Verify DB still holds concurrent value 200 (not overwritten)
        let checkRes = try await execute_query(config: config, sql: "SELECT count FROM \(tableName) WHERE id = 1;", queryId: UUID().uuidString)
        #expect(checkRes.rows[0].cells[0] == .integer(200))

        _ = try? await execute_query(config: config, sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
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
        _ = try await execute_query(config: config, sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        // Edit row 1: valid score 60
        vm.stageTextEdit(row: 0, column: 1, text: "60")
        // Edit row 2: invalid score -10 (violates check constraint)
        vm.stageTextEdit(row: 1, column: 1, text: "-10")

        await vm.applyStagedEdits(config: config)
        #expect(vm.errorMessage != nil)

        // Verify row 1 was NOT modified (atomic rollback preserved original 50)
        let checkRes = try await execute_query(config: config, sql: "SELECT score FROM \(tableName) ORDER BY id;", queryId: UUID().uuidString)
        #expect(checkRes.rows[0].cells[0] == .integer(50))
        #expect(checkRes.rows[1].cells[0] == .integer(80))

        _ = try? await execute_query(config: config, sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
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
        _ = try await execute_query(config: config, sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        // Turn on read-only
        vm.isReadOnly = true
        #expect(vm.isEditable == false)
        #expect(vm.nonEditableReason?.contains("Read-only") == true)

        // Attempting to stage or apply in read-only mode
        vm.stageTextEdit(row: 0, column: 1, text: "Attempted Edit")
        #expect(vm.stagedEdits.isEmpty) // Blocked by isEditable guard

        _ = try? await execute_query(config: config, sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
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
        _ = try await execute_query(config: config, sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "public", table: tableName)

        #expect(vm.hasPrimaryKey == false)
        #expect(vm.isEditable == false)
        #expect(vm.nonEditableReason?.contains("no primary key") == true)
        #expect(vm.buildBatchMutationRequest() == nil)

        _ = try? await execute_query(config: config, sql: "DROP TABLE \(tableName);", queryId: UUID().uuidString)
    }

    @Test("Verify system catalogs are read-only and pg_catalog.pg_am decodes without placeholders")
    func testSystemCatalogReadOnlyAndDecoded() async throws {
        let config = getLocalConfig()
        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: "pg_catalog", table: "pg_am")

        #expect(vm.isSystemSchema == true)
        #expect(vm.hasPrimaryKey == true)
        #expect(vm.isEditable == false)
        #expect(vm.nonEditableReason?.contains("System schema") == true)
        #expect(!vm.rows.isEmpty)

        // Verify no cell contains "raw display" or Unsupported placeholder
        for row in vm.rows {
            for cell in row.cells {
                #expect(!cell.isUnsupported)
                #expect(!cell.displayString.contains("raw display"))
            }
        }

        // Staging an edit against a system catalog must be blocked
        vm.stageTextEdit(row: 0, column: 1, text: "tampered")
        #expect(vm.stagedEdits.isEmpty)
        #expect(vm.buildBatchMutationRequest() == nil)
    }

    @Test("Verify unsupported cells and primary keys cannot be edited or sent as mutation parameters")
    func testUnsupportedValuesBlockedFromEditingAndMutation() {
        let vm = TableDataViewModel()
        vm.currentSchema = "user_schema"
        vm.currentTable = "weird_table"
        vm.columns = [
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "oid", pgTypeOid: 26, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "label", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "extra", ordinalPosition: 3, pgTypeName: "int2vector", pgTypeOid: 22, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false)
        ]
        vm.rows = [
            RowData(cells: [.text("100"), .unsupported("oid"), .text("ok"), .unsupported("int2vector")]),
            RowData(cells: [.text("101"), .integer(403), .text("ok2"), .unsupported("int2vector")])
        ]

        // Row 0 has an unsupported PK -> no cell on row 0 is editable
        #expect(vm.isRowIdentifiable(row: 0) == false)
        #expect(vm.isCellEditable(row: 0, column: 1) == false)
        vm.stageTextEdit(row: 0, column: 1, text: "should_not_stage")
        #expect(vm.stagedEdits.isEmpty)

        // Row 1 has a valid PK, so col 1 ('label') is editable, while col 2 ('extra') is unsupported
        #expect(vm.isRowIdentifiable(row: 1) == true)
        #expect(vm.isCellEditable(row: 1, column: 1) == true)
        #expect(vm.isCellEditable(row: 1, column: 2) == false)

        // Even via setCellValue, .unsupported cannot be staged
        vm.setCellValue(row: 1, column: 1, value: .unsupported("fake"))
        #expect(vm.stagedEdits.isEmpty)
    }

    @Test("Verify LucidError.userFacingMessage formats concisely without debug enum reflection")
    func testUserFacingErrorFormatting() {
        let dbErr = LucidError.DatabaseError(
            code: "22P02",
            message: "invalid input syntax for type integer: \"abc\"",
            detail: "Value out of range"
        )
        let msg = dbErr.userFacingMessage
        #expect(msg.contains("SQLSTATE 22P02"))
        #expect(msg.contains("invalid input syntax"))
        #expect(msg.contains("Value out of range"))
        #expect(!msg.contains("LucidSQLBridge"))
        #expect(!msg.contains("DatabaseError("))

        let conflictErr = LucidError.ConflictDetected(tableName: "public.items", primaryKeyValues: ["42"])
        #expect(conflictErr.userFacingMessage.contains("Conflict detected in public.items"))
        #expect(!conflictErr.userFacingMessage.contains("LucidError"))
    }

    @Test("Verify parseCellValue does not misclassify point/interval as integer")
    func testParseCellValueTypeMatching() {
        let vm = TableDataViewModel()
        let pointCol = ColumnMetadata(name: "loc", ordinalPosition: 1, pgTypeName: "point", pgTypeOid: 600, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false)
        let intCol = ColumnMetadata(name: "cnt", ordinalPosition: 2, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false)

        #expect(vm.parseCellValue(text: "123", column: pointCol) == .text("123"))
        #expect(vm.parseCellValue(text: "123", column: intCol) == .integer(123))
    }

    @Test("Verify disposable user-schema composite PK and high-precision numeric round-trip")
    func testDisposableSchemaCompositePkAndNumericPrecision() async throws {
        let config = getLocalConfig()
        let schema = "lucid_swift_test_\(Int.random(in: 1000...9999))"
        let table = "orders"

        let setupSql = """
        DROP SCHEMA IF EXISTS \(schema) CASCADE;
        CREATE SCHEMA \(schema);
        CREATE TABLE \(schema).\(table) (
            tenant_id int NOT NULL,
            order_id bigint NOT NULL,
            amount numeric(24, 10) NOT NULL,
            note text,
            PRIMARY KEY (tenant_id, order_id)
        );
        INSERT INTO \(schema).\(table) VALUES (10, 5001, 1234567890.0000123456, 'initial');
        """
        _ = try await execute_query(config: config, sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: schema, table: table)

        #expect(vm.isSystemSchema == false)
        #expect(vm.isEditable == true)
        #expect(vm.rows.count == 1)
        #expect(vm.originalCellValue(row: 0, column: 2) == .decimal("1234567890.0000123456"))

        // Update numeric with trailing zeros and change note to empty string
        vm.stageTextEdit(row: 0, column: 2, text: "9999999999.1234500000")
        vm.stageTextEdit(row: 0, column: 3, text: "")

        await vm.applyStagedEdits(config: config)
        #expect(vm.errorMessage == nil)
        #expect(vm.stagedEdits.isEmpty)
        #expect(vm.originalCellValue(row: 0, column: 2) == .decimal("9999999999.1234500000"))
        #expect(vm.originalCellValue(row: 0, column: 3) == .text(""))

        let verifySql = "SELECT amount::text, note FROM \(schema).\(table) WHERE tenant_id = 10 AND order_id = 5001;"
        let res = try await execute_query(config: config, sql: verifySql, queryId: UUID().uuidString)
        #expect(res.rows[0].cells[0] == .text("9999999999.1234500000"))
        #expect(res.rows[0].cells[1] == .text(""))

        _ = try? await execute_query(config: config, sql: "DROP SCHEMA IF EXISTS \(schema) CASCADE;", queryId: UUID().uuidString)
    }

    @Test("Verify DataTableCellView is non-editable and non-bezeled outside active editing")
    @MainActor
    func testCellViewNotPermanentTextEntryControl() {
        let cell = DataTableCellView(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
        cell.configure(value: .text("hello"), isDirty: false, isEditable: true, isSelectedCell: false)

        let tf = cell.textField
        #expect(tf != nil)
        #expect(tf?.isEditable == false)
        #expect(tf?.isBezeled == false)
        #expect(tf?.isBordered == false)
        #expect(tf?.drawsBackground == false)
        #expect(tf?.stringValue == "hello")

        cell.beginEditing()
        #expect(tf?.isEditable == true)
        #expect(tf?.isBezeled == true)
        #expect(tf?.drawsBackground == true)
    }

    @Test("Verify beginEditingCell attaches an editable field editor in a real NSWindow")
    @MainActor
    func testBeginEditingCellMakesFieldEditorEditable() {
        let vm = TableDataViewModel()
        vm.currentSchema = "public"
        vm.currentTable = "items"
        vm.columns = [
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "label", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false)
        ]
        vm.rows = [
            RowData(cells: [.text("100"), .integer(1), .text("Alpha")])
        ]

        let representable = DataTableView(viewModel: vm)
        let coord = representable.makeCoordinator()
        let tv = LucidDataTableView()
        tv.delegate = coord
        tv.dataSource = coord
        _ = coord.syncColumns(tableView: tv, columns: vm.columns)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scrollView.documentView = tv

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = scrollView
        win.makeKeyAndOrderFront(nil)
        tv.reloadData()
        tv.layoutSubtreeIfNeeded()

        let cellView = tv.view(atColumn: 2, row: 0, makeIfNecessary: true) as? DataTableCellView
        #expect(cellView != nil)
        #expect(cellView?.window === win)
        #expect(vm.isCellEditable(row: 0, column: 1) == true)

        coord.beginEditingCell(tableView: tv, row: 0, tableColumnIndex: 2)
        let fr = win.firstResponder
        let editor = fr as? NSTextView
        #expect(editor != nil, "Expected NSTextView field editor, got \(String(describing: fr))")
        #expect(editor?.isEditable == true, "tfEd=\(String(describing: cellView?.textField?.isEditable)) cellEd=\(String(describing: cellView?.textField?.cell?.isEditable)) sameEd=\(editor === cellView?.textField?.currentEditor()) edDel=\(String(describing: editor?.delegate))")
        if let editor {
            editor.insertText("Omega", replacementRange: NSRange(location: 0, length: editor.string.count))
            #expect(editor.string == "Omega")
        }
        win.makeFirstResponder(tv)
        #expect(vm.stagedEdits[TableDataViewModel.GridCoordinate(row: 0, column: 1)] == .text("Omega"))
    }

    @Test("Verify non-nullable/PK columns cannot be set NULL and idle CellTextField ignores Cmd+Option+N")
    @MainActor
    func testCanSetNullAndIdlePerformKeyEquivalentGuard() {
        let vm = TableDataViewModel()
        vm.currentSchema = "public"
        vm.currentTable = "items"
        vm.columns = [
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "title", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "note", ordinalPosition: 3, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false)
        ]
        vm.rows = [
            RowData(cells: [.text("100"), .integer(1), .text("Req"), .text("Opt")])
        ]

        #expect(vm.canSetNull(row: 0, column: 0) == false)
        #expect(vm.canSetNull(row: 0, column: 1) == false)
        #expect(vm.canSetNull(row: 0, column: 2) == true)

        vm.stageNullEdit(row: 0, column: 0)
        vm.stageNullEdit(row: 0, column: 1)
        #expect(vm.stagedEdits.isEmpty)

        vm.stageNullEdit(row: 0, column: 2)
        #expect(vm.stagedEdits[TableDataViewModel.GridCoordinate(row: 0, column: 2)] == .null)

        // Idle CellTextField must not intercept Cmd+Option+N broadcast
        let tf = CellTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        tf.isEditable = false
        var shortcutFired = false
        tf.onSetNullShortcut = { shortcutFired = true }
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        )!
        #expect(tf.performKeyEquivalent(with: event) == false)
        #expect(shortcutFired == false)
    }

    @Test("Verify Coordinator.hasStateChanged detects reloaded rows even when duration and row count are unchanged")
    @MainActor
    func testCoordinatorDetectsReloadedRowsWithZeroDuration() {
        let vm = TableDataViewModel()
        vm.currentSchema = "public"
        vm.currentTable = "items"
        vm.columns = [
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "label", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false)
        ]
        vm.rows = [RowData(cells: [.text("100"), .integer(1), .text("Alpha")])]
        vm.executionDurationMs = 0

        let coord = DataTableView(viewModel: vm).makeCoordinator()
        #expect(coord.hasStateChanged(viewModel: vm) == true)
        #expect(coord.hasStateChanged(viewModel: vm) == false)

        // Simulate reload with updated cell value but identical row count and 0ms duration
        vm.rows = [RowData(cells: [.text("101"), .integer(1), .text("ExternalUpdate")])]
        vm.notifyRowsUpdated()
        #expect(coord.hasStateChanged(viewModel: vm) == true)
    }

    @Test("Verify draft row staging, DEFAULT vs NULL vs empty string, validation, and draft discard")
    @MainActor
    func testDraftRowStagingDefaultsAndValidation() {
        let vm = TableDataViewModel()
        vm.currentSchema = "public"
        vm.currentTable = "items"
        vm.columns = [
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: true, isIdentityAlways: true),
            ColumnMetadata(name: "required_col", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "default_note", ordinalPosition: 3, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: "'def'::text", isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "computed", ordinalPosition: 4, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: true, isIdentity: false, isIdentityAlways: false),
        ]

        let draftRow = vm.addDraftRow()
        #expect(draftRow == 0)
        #expect(vm.hasPendingChanges == true)
        #expect(vm.stagedInserts.count == 1)
        #expect(vm.totalGridRowCount == 1)

        // GENERATED ALWAYS AS IDENTITY and GENERATED ALWAYS AS (...) are read-only in drafts
        #expect(vm.isCellEditable(row: 0, column: 0) == false)
        #expect(vm.isCellEditable(row: 0, column: 1) == true)
        #expect(vm.isCellEditable(row: 0, column: 2) == true)
        #expect(vm.isCellEditable(row: 0, column: 3) == false)

        // Required column missing triggers validation issue before Apply
        #expect(vm.draftValidationIssues.count == 1)
        #expect(vm.draftValidationIssues[0].contains("required_col"))

        // Navigation guard must prompt when only inserts are staged
        var navigated = false
        vm.safeNavigate { navigated = true }
        #expect(navigated == false)
        #expect(vm.showingUnsavedChangesAlert == true)
        vm.cancelNavigation()

        // Distinguish empty string "" vs NULL vs DEFAULT on text columns
        vm.stageEmptyStringEdit(row: 0, column: 1) // required_col = ""
        #expect(vm.draftValidationIssues.isEmpty)

        vm.stageNullEdit(row: 0, column: 2) // default_note = explicit NULL
        var state = vm.cellState(row: 0, column: 2)
        #expect(state.isDefault == false)
        #expect(state.value == .null)

        vm.revertDraftCellToDefault(row: 0, column: 2) // back to DEFAULT
        state = vm.cellState(row: 0, column: 2)
        #expect(state.isDefault == true)

        // Deleting an unsaved draft row removes it cleanly without staging a DB delete
        vm.stageDeleteRow(row: 0)
        #expect(vm.stagedInserts.isEmpty)
        #expect(vm.stagedDeletes.isEmpty)
        #expect(vm.hasPendingChanges == false)
    }

    @Test("Verify live PostgreSQL Add Row, Delete, Undo Delete, and Mixed-Batch Atomic Rollback")
    func testLiveInsertDeleteMixedBatchAndRollback() async throws {
        let config = getLocalConfig()
        let schema = "lucid_swift_insdel_\(Int.random(in: 1000...9999))"
        let table = "records"

        let setupSql = """
        DROP SCHEMA IF EXISTS \(schema) CASCADE;
        CREATE SCHEMA \(schema);
        CREATE TABLE \(schema).\(table) (
            id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            code text NOT NULL UNIQUE,
            status text DEFAULT 'pending',
            note text DEFAULT 'auto-note',
            doubled_code text GENERATED ALWAYS AS (code || '!') STORED
        );
        INSERT INTO \(schema).\(table) (code, status, note) VALUES ('A1', 'active', 'seed1'), ('B2', 'active', 'seed2');
        """
        _ = try await execute_query(config: config, sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        await vm.loadTable(config: config, schema: schema, table: table)
        #expect(vm.rows.count == 2)
        #expect(vm.columns[0].isIdentity == true)
        #expect(vm.columns[0].isIdentityAlways == true)

        // Stage: 1 delete (row 0), 1 undo then keep row 1 deleted? No: test undo on row 0, delete row 1, insert draft with DEFAULT status, explicit NULL note, "" code? Use distinct code
        vm.stageDeleteRow(row: 0)
        #expect(vm.stagedDeletes.contains(0))
        #expect(vm.isCellEditable(row: 0, column: 1) == false) // pending delete row cannot be edited
        vm.unstageDeleteRow(row: 0)
        #expect(vm.stagedDeletes.isEmpty)
        #expect(vm.isCellEditable(row: 0, column: 1) == true)

        // Stage delete of row 1 (B2), update row 0 (A1), and insert draft row reusing B2 and testing NULL vs "" vs DEFAULT
        vm.stageDeleteRow(row: 1)
        vm.stageTextEdit(row: 0, column: 2, text: "updated")

        let draftIdx = vm.addDraftRow()!
        // code = "", status = left DEFAULT ('pending'), note = explicit NULL (overrides 'auto-note')
        vm.stageEmptyStringEdit(row: draftIdx, column: 1)
        vm.stageNullEdit(row: draftIdx, column: 3)

        #expect(vm.stagedDeleteItems.count == 1)
        #expect(vm.stagedDiffs.count == 1)
        #expect(vm.stagedInsertItems.count == 1)

        await vm.applyStagedEdits(config: config)
        #expect(vm.errorMessage == nil)
        #expect(!vm.hasPendingChanges)
        #expect(vm.rows.count == 2) // A1 updated + new draft id=3

        // Verify newly inserted row refreshed with DB-generated PK (id=3), DEFAULT 'pending', NULL note, and STORED generated '!'
        let insertedRow = vm.rows.first(where: { $0.cells[1] == .integer(3) })
        #expect(insertedRow != nil)
        #expect(insertedRow?.cells[2] == .text(""))
        #expect(insertedRow?.cells[3] == .text("pending"))
        #expect(insertedRow?.cells[4] == .null)
        #expect(insertedRow?.cells[5] == .text("!"))

        // Now verify failed mixed batch rolls back ALL operations and preserves staged work in ViewModel
        vm.stageDeleteRow(row: 1) // delete id=3
        vm.stageTextEdit(row: 0, column: 2, text: "should_rollback")
        let failDraft = vm.addDraftRow()!
        vm.stageTextEdit(row: failDraft, column: 1, text: "A1") // collides with row 0's UNIQUE code 'A1'!
        await vm.applyStagedEdits(config: config)

        #expect(vm.errorMessage != nil)
        #expect(vm.errorMessage?.contains("23505") == true)
        #expect(vm.stagedDeletes.count == 1)
        #expect(vm.stagedEdits.count == 1)
        #expect(vm.stagedInserts.count == 1)

        // Verify Read-Only rejection
        vm.discardChanges()
        vm.isReadOnly = true
        #expect(vm.addDraftRow() == nil)
        #expect(vm.canDeleteRow(0) == false)

        _ = try? await execute_query(config: config, sql: "DROP SCHEMA IF EXISTS \(schema) CASCADE;", queryId: UUID().uuidString)
    }

    @Test("Verify Coordinator Tab/Shift+Tab helper skips non-editable generated columns and pending-delete rows")
    @MainActor
    func testTabNavigationSkipsNonEditableAndDeletedRows() {
        let vm = TableDataViewModel()
        vm.currentSchema = "public"
        vm.currentTable = "t"
        vm.columns = [
            ColumnMetadata(name: "id", ordinalPosition: 1, pgTypeName: "int4", pgTypeOid: 23, isPrimaryKey: true, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: true, isIdentityAlways: true),
            ColumnMetadata(name: "name", ordinalPosition: 2, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: false, defaultValue: nil, isGenerated: false, isIdentity: false, isIdentityAlways: false),
            ColumnMetadata(name: "gen", ordinalPosition: 3, pgTypeName: "text", pgTypeOid: 25, isPrimaryKey: false, isNullable: true, defaultValue: nil, isGenerated: true, isIdentity: false, isIdentityAlways: false),
        ]
        vm.rows = [
            RowData(cells: [.text("10"), .integer(1), .text("Row1"), .text("Row1!")]),
            RowData(cells: [.text("11"), .integer(2), .text("Row2"), .text("Row2!")]),
            RowData(cells: [.text("12"), .integer(3), .text("Row3"), .text("Row3!")]),
        ]
        vm.stageDeleteRow(row: 1) // Row 1 marked for deletion

        let coord = DataTableView(viewModel: vm).makeCoordinator()
        // From (row 0, col 2 'name'): Tab forward skips col 3 'gen', skips deleted row 1, skips col 1 'id' (identity always), lands on (row 2, col 2 'name') -> tableColumn 2
        let forward = coord.findNextEditableCoordinate(fromRow: 0, fromTableCol: 2, direction: 1, totalRows: 3, totalTableCols: 4)
        #expect(forward?.row == 2 && forward?.tableCol == 2)

        // Shift+Tab backward from (row 2, col 2) skips back to (row 0, col 2)
        let backward = coord.findNextEditableCoordinate(fromRow: 2, fromTableCol: 2, direction: -1, totalRows: 3, totalTableCols: 4)
        #expect(backward?.row == 0 && backward?.tableCol == 2)
    }

    @Test("Verify rapid table switch cancels/discards stale slow result and shows immediate loading feedback")
    @MainActor
    func testStaleTableSwitchDiscardsSupersededLoad() async throws {
        let config = getLocalConfig()
        let schema = "s_stale_\(Int.random(in: 1000...9999))"
        let setupSql = """
        CREATE SCHEMA \(schema);
        CREATE TABLE \(schema).fast_items (id int PRIMARY KEY, label text NOT NULL);
        INSERT INTO \(schema).fast_items SELECT g, 'row_' || g FROM generate_series(1, 20) g;
        CREATE VIEW \(schema).slow_view AS
        SELECT pg_sleep(0.25)::text AS waited, id FROM \(schema).fast_items LIMIT 2;
        """
        _ = try await execute_query(config: config, sql: setupSql, queryId: UUID().uuidString)

        let vm = TableDataViewModel()
        vm.startTableLoad(config: config, schema: schema, table: "slow_view")
        #expect(vm.isLoading == true)
        #expect(vm.currentTable == "slow_view")

        try? await Task.sleep(for: .milliseconds(15))
        await vm.loadTable(config: config, schema: schema, table: "fast_items")

        #expect(vm.currentSchema == schema)
        #expect(vm.currentTable == "fast_items")
        #expect(vm.columns.count == 2)
        #expect(vm.rows.count == 20)
        #expect(vm.isLoading == false)

        // Allow slow_view's superseded request enough time to settle and confirm it cannot overwrite fast_items.
        try? await Task.sleep(for: .milliseconds(350))
        #expect(vm.currentTable == "fast_items")
        #expect(vm.columns.count == 2)
        #expect(vm.rows.count == 20)
        #expect(vm.isLoading == false)

        _ = try? await execute_query(config: config, sql: "DROP SCHEMA IF EXISTS \(schema) CASCADE;", queryId: UUID().uuidString)
    }

    @Test("Verify DataTableView syncColumns reuses NSTableColumn instances cleanly across wide and narrow tables")
    @MainActor
    func testSyncColumnsReusesColumnsCleanly() {
        let vm = TableDataViewModel()
        let tableView = LucidDataTableView()
        let coord = DataTableView(viewModel: vm).makeCoordinator()

        func makeCols(_ count: Int, prefix: String) -> [ColumnMetadata] {
            var columns: [ColumnMetadata] = []
            columns.reserveCapacity(count)
            for idx in 0..<count {
                let name = "\(prefix)_\(idx)"
                let ordinal = UInt32(idx + 1)
                let isPrimary = (idx == 0)
                let isNullable = (idx != 0)
                columns.append(
                    ColumnMetadata(
                        name: name,
                        ordinalPosition: ordinal,
                        pgTypeName: "text",
                        pgTypeOid: 25,
                        isPrimaryKey: isPrimary,
                        isNullable: isNullable,
                        defaultValue: nil,
                        isGenerated: false,
                        isIdentity: false,
                        isIdentityAlways: false
                    )
                )
            }
            return columns
        }

        let changed1 = coord.syncColumns(tableView: tableView, columns: makeCols(10, prefix: "a"))
        #expect(changed1 == true)
        #expect(tableView.tableColumns.count == 11)
        let firstDataColRef = tableView.tableColumns[1]

        let unchanged = coord.syncColumns(tableView: tableView, columns: makeCols(10, prefix: "a"))
        #expect(unchanged == false)

        let changed2 = coord.syncColumns(tableView: tableView, columns: makeCols(3, prefix: "b"))
        #expect(changed2 == true)
        #expect(tableView.tableColumns.count == 4)
        #expect(tableView.tableColumns[1] === firstDataColRef)
        #expect(tableView.tableColumns[1].title.contains("b_0"))

        let changed3 = coord.syncColumns(tableView: tableView, columns: makeCols(15, prefix: "c"))
        #expect(changed3 == true)
        #expect(tableView.tableColumns.count == 16)
        #expect(tableView.tableColumns[0].identifier.rawValue == "col_index")
        #expect(tableView.tableColumns[15].identifier.rawValue == "col_14")
    }
}
