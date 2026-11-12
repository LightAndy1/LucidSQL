import Foundation
import Testing
@testable import LucidSQL
import LucidSQLBridge

@Suite("PostgreSQL Schema & Query Integration Tests")
struct PostgresIntegrationTests {
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

    @Test("Verify live connection test to local PostgreSQL if available")
    func testLiveConnection() async throws {
        let config = getLocalConfig()
        let version = try await test_database_connection(config: config)
        print("Connected to live PostgreSQL: \(version)")
        #expect(version.contains("PostgreSQL"))

        // Introspect schemas
        let schemas = try await introspect_schemas(config: config)
        #expect(!schemas.isEmpty)
        #expect(schemas.contains("public") || schemas.contains("information_schema"))

        // Introspect tables in information_schema (guaranteed to exist in any Postgres DB)
        let tables = try await introspect_tables(config: config, schema: "information_schema")
        #expect(!tables.isEmpty)

        // Introspect columns of information_schema.tables
        let columns = try await introspect_columns(config: config, schema: "information_schema", table: "tables")
        #expect(!columns.isEmpty)
        #expect(columns.contains(where: { $0.name == "table_name" }))

        // Fetch table page
        let page = try await fetch_table_page(
            config: config,
            schema: "information_schema",
            table: "tables",
            offset: 0,
            limit: 10
        )
        #expect(!page.rows.isEmpty)
        #expect(page.totalRowsFetched <= 10)
    }
}
