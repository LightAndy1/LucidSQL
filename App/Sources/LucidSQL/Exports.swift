@_exported import LucidSQLBridge

// Ensure UniFFI bridge types conform to Sendable for Swift concurrency
extension ConnectionConfig: @unchecked Sendable {}
extension ColumnMetadata: @unchecked Sendable {}
extension TableInfo: @unchecked Sendable {}
extension RecordPage: @unchecked Sendable {}
extension RowData: @unchecked Sendable {}
extension CellValue: @unchecked Sendable {}
extension QueryResult: @unchecked Sendable {}

// Provide snake_case aliases matching Rust/plan spec
public func bridge_ping() -> String {
    bridgePing()
}

public func async_test_operation(delayMs: UInt64) async throws -> String {
    try await asyncTestOperation(delayMs: delayMs)
}

public func trigger_test_error(errorType: String) throws {
    try triggerTestError(errorType: errorType)
}

public func test_database_connection(config: ConnectionConfig) async throws -> String {
    try await testDatabaseConnection(config: config)
}

public func introspect_schemas(config: ConnectionConfig) async throws -> [String] {
    try await introspectSchemas(config: config)
}

public func introspect_tables(config: ConnectionConfig, schema: String) async throws -> [TableInfo] {
    try await introspectTables(config: config, schema: schema)
}

public func introspect_columns(config: ConnectionConfig, schema: String, table: String) async throws -> [ColumnMetadata] {
    try await introspectColumns(config: config, schema: schema, table: table)
}

public func fetch_table_page(
    config: ConnectionConfig,
    schema: String,
    table: String,
    offset: UInt64,
    limit: UInt32,
    sortCol: String? = nil,
    sortDesc: Bool = false
) async throws -> RecordPage {
    try await fetchTablePage(config: config, schema: schema, table: table, offset: offset, limit: limit, sortCol: sortCol, sortDesc: sortDesc)
}

public func execute_query(
    config: ConnectionConfig,
    sql: String,
    queryId: String,
    maxRows: UInt32? = nil
) async throws -> QueryResult {
    try await executeQuery(config: config, sql: sql, queryId: queryId, maxRows: maxRows)
}

public func cancel_query(queryId: String) async throws -> Bool {
    try await cancelQuery(queryId: queryId)
}
