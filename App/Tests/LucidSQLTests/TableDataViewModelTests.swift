import Foundation
import Testing
@testable import LucidSQL
import LucidSQLBridge

@Suite("Table Data View Model & Cell Value Tests")
struct TableDataViewModelTests {
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
}
