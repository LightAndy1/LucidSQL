# LucidSQL Architecture & Product Design Specification

**Date:** 2026-11-10  
**Status:** Approved  
**Author:** LightAndy & Antigravity  
**License:** GNU AGPLv3 (`AGPL-3.0-only`)

---

## 1. Product Vision & Goals

LucidSQL is a native macOS application designed from scratch as a fast, keyboard-friendly, polished PostgreSQL client for browsing, querying, and safely editing databases.

### Core Tenets
1. **Safety First**: Destructive mutations require explicit confirmation; direct table edits are staged locally and committed atomically; transactions have explicit visual controls; read-only mode is enforced at both UI and session levels.
2. **Mac-Native Performance**: Built with SwiftUI for modern system chrome and AppKit bridges (`NSTableView`, `NSTextView`) where macOS platform performance and keyboard-first interaction demand it.
3. **Rust Core Reliability**: All database drivers, connection pooling, SQL execution, cancellation, and type marshaling are owned by a fast, memory-safe Rust core communicating over a narrow UniFFI bridge.
4. **Local-First & Secure**: Credentials reside exclusively in macOS Keychain; no cloud backend or telemetry; query history and connection profiles are stored locally.

---

## 2. Approved Product Scope (Scope 2: Balanced MVP)

### Included Features
- **Connection Profiles**: Host, port, database, user, SSL modes (disable, require), label, color tag. Passwords saved in macOS Keychain.
- **Sidebar Browser**: Collapsible hierarchy: Databases $\to$ Schemas $\to$ Tables & Views.
- **Table Data Grid (In-Grid Editing Enabled by Default)**:
  - High-performance virtualized grid via `NSTableView` bridge.
  - Cell selection, arrow-key navigation, Tab navigation, Enter or double-click to edit in place.
  - Staged dirty edits highlighted visibly with row-level and cell-level markers.
  - Persistent **Apply Changes** and **Discard Changes** actions.
  - Pre-commit change summary modal with exact diffs.
  - Explicit distinction between `NULL` and empty string `""` (`Cmd+Option+N` shortcut).
  - Conflict detection using PostgreSQL tuple version column `xmin` and primary keys.
  - Atomic batch commit via short transaction on a borrowed connection; automatic rollback on failure preserving user edits.
- **Multi-Tab Workspace**:
  - Independent tabs for tables and SQL scratchpads.
  - Dedicated persistent PostgreSQL sessions for SQL editor tabs (preserving temporary tables, `SET search_path`, and session variables).
- **SQL Editor**:
  - Native `NSTextView` bridge with syntax highlighting, line numbers, and keyboard shortcuts (`Cmd+Enter` to run statement/selection).
  - Execution duration, affected row counts, and error display.
  - Query cancellation using driver `CancelToken`.
- **Transaction Controls**:
  - Dedicated SQL tabs track transaction state (`Idle`, `Active`, `Failed`).
  - Prominent toolbar transaction indicator with elapsed time.
  - Explicit Commit (`Cmd+Shift+C`) and Rollback (`Cmd+Shift+R`) actions.
  - Tab closure guard: warn on uncommitted transaction; never auto-commit on close.
- **Read-Only Mode (Toggle in Toolbar, OFF by default)**:
  - When toggled ON, disables grid edits and enforces `SET default_transaction_read_only = on` / `BEGIN READ ONLY` in the database engine.
- **Local Query History**:
  - Local SQLite/JSON store recording timestamp, connection ID, query text, duration, row count, and status.
- **Streaming CSV/TSV Export**:
  - Stream results directly from Rust to disk with formula injection protection (escaping `=`, `+`, `-`, `@`).

### Explicit Exclusions (Out of Scope for MVP)
- Non-PostgreSQL database engines (MySQL, SQLite, etc.).
- SSH tunnels (direct TCP/SSL connections only).
- ER diagrams and schema visualization.
- Database migration, backup, and restore tools.
- Cloud sync, user accounts, and team collaboration.
- AI SQL generation.
- Schema-aware AST autocomplete (keyword syntax highlighting only).

---

## 3. System Architecture & Component Hierarchy

```text
LucidSQL/
├── App/                              # Swift 6 / SwiftUI Target
│   ├── App.swift                     # Entry point & window definitions
│   ├── Features/                     # UI Feature modules
│   │   ├── Connections/              # Connection list, creation form, Keychain bridge
│   │   ├── Workspace/                # Window layout, sidebar, tabs, transaction toolbar
│   │   ├── TableData/                # Staged edits coordinator, diff review sheet
│   │   ├── SQLEditor/                # SQL editor view model, stats bar, cancel controls
│   │   ├── History/                  # Query execution history drawer
│   │   └── Export/                   # Export configuration & progress sheet
│   ├── Components/                   # AppKit Bridges
│   │   ├── Grid/                     # NSTableView bridge with cell selection & editors
│   │   └── Editor/                   # NSTextView bridge with syntax highlighter
│   ├── Services/                     # Swift Actor Services
│   │   ├── DatabaseService.swift     # High-level actor coordinating Rust engine calls
│   │   └── KeychainService.swift     # macOS Keychain API wrapper
│   └── Bridge/                       # Generated UniFFI Swift bindings
│
└── Core/                             # Rust Crate (Static Library liblucidsql_core.a)
    ├── Cargo.toml
    └── src/
        ├── lib.rs                    # UniFFI interface & proc-macro exports
        ├── connection/               # Pool manager, session registry, cleanup recycler
        ├── query/                    # Query runner, CancelToken registry, row limiters
        ├── schema/                   # PostgreSQL catalog introspection & caching
        ├── mutation/                 # PK introspection, diff builder, xmin verification
        ├── export/                   # Streaming CSV/TSV exporter
        ├── safety/                   # Destructive statement analyzer
        └── error.rs                  # Strongly typed error hierarchy
```

---

## 4. Rust-to-Swift FFI / UniFFI Boundary

The boundary is built using **UniFFI proc-macros** (`#[uniffi::export]`, `#[derive(uniffi::Record)]`, `#[derive(uniffi::Error)]`) as the single source of truth.

### Lossless Value Representation
```rust
#[derive(uniffi::Record, Clone, Debug)]
pub struct ColumnMetadata {
    pub name: String,
    pub ordinal_position: u32,
    pub pg_type_name: String,
    pub pg_type_oid: u32,
    pub is_primary_key: bool,
    pub is_nullable: bool,
    pub default_value: Option<String>,
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum CellValue {
    Null,
    Text(String),
    Boolean(bool),
    Integer(i64),
    Decimal(String),            // Exact representation to avoid IEEE-754 precision loss
    Float(f64),
    TimestampWithTimeZone(String), // ISO-8601 with offset
    TimestampWithoutTimeZone(String), // ISO-8601 naive timestamp (no fake TZ)
    Date(String),               // YYYY-MM-DD
    Time(String),               // HH:MM:SS[.ffffff]
    Uuid(String),
    BinaryHex(String),          // Hex encoded bytea
    Json(String),
    Unsupported(String),        // Lossless raw string display
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct RowData {
    pub cells: Vec<CellValue>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct RecordPage {
    pub rows: Vec<RowData>,
    pub total_rows_fetched: u64,
    pub has_more: bool,
    pub execution_duration_ms: u64,
}
```

### Strongly Typed Error Hierarchy
```rust
#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum LucidError {
    #[error("Connection failed: {reason}")]
    ConnectionFailed { reason: String },
    #[error("Authentication failed: {message}")]
    AuthenticationFailed { message: String },
    #[error("Query was cancelled by user")]
    QueryCancelled,
    #[error("Query timed out after {duration_ms}ms")]
    QueryTimedOut { duration_ms: u64 },
    #[error("Read-only mode violation: {attempted_operation}")]
    ReadOnlyViolation { attempted_operation: String },
    #[error("Concurrent modification detected for table {table_name}")]
    ConflictDetected { table_name: String, primary_key_values: Vec<String> },
    #[error("Table {table_name} has no primary key")]
    MissingPrimaryKey { table_name: String },
    #[error("Commit outcome uncertain due to network failure: {message}")]
    UncertainCommitOutcome { message: String },
    #[error("Database error ({code}): {message}")]
    DatabaseError { code: String, message: String, detail: Option<String> },
}
```

---

## 5. Connection, Pool & Session Management

### The Hybrid Model
1. **Shared Pool (Table & Schema Browsing + Grid Batch Mutations)**:
   - Managed via `deadpool-postgres` (min: 1, max: 4 connections per active workspace).
   - Serves schema discovery, table column definitions, and paged data fetching.
   - Also executes short atomic batch mutations for in-grid editing.
   - **Connection Hygiene**: Recycled via `RESET ALL` / cleanup checks before being returned to the pool. Connections with aborted transactions or broken sockets are immediately dropped.
2. **Dedicated Sessions (SQL Editor Tabs)**:
   - Lazily created on first query execution per SQL tab.
   - Dedicated physical TCP connection holding session state (`SET search_path`, temp tables, active transactions).
   - Tracks transaction state directly via client status.
   - Disconnected tabs show visible status without silent reconnection.
3. **Cancellation**:
   - Every in-flight query stores its `tokio_postgres::CancelToken` in an active registry.
   - Cancellation triggers `CancelToken::cancel_query(...)` over a short-lived out-of-band socket.
   - Connections with ambiguous cancellation status are verified before reuse or safely discarded.

---

## 6. Table Editing, Mutations & Conflict Detection

1. **Staging**: Edits are collected in Swift memory. No database locks or open transactions are held during user typing.
2. **Pre-Save Verification**:
   - Table must have an introspected Primary Key (single or composite).
   - Hidden `xmin` column is fetched alongside table rows for version tokening.
3. **Execution**:
   - Borrow pooled connection $\to$ `BEGIN`.
   - Run parameterized `UPDATE ... WHERE pk = $1 AND xmin = $2 RETURNING xmin;`.
   - If rows affected is 0: `ROLLBACK`, report `ConflictDetected`, and preserve staged edits in UI.
   - If network drops during `COMMIT`: flag `UncertainCommitOutcome`, do NOT blindly retry.
   - If commit succeeds: update local `xmin` cache with returned tokens and mark cells clean.

---

## 7. Security & Destructive Query Safeguards

1. **Keychain Isolation**: Passwords retrieved transiently by Swift and passed over FFI to Rust connection establishment. Never persisted in logs, settings, or query history.
2. **Dual-Layer Read-Only Mode**:
   - UI: Disables cell editing and shows visual lock indicators.
   - Engine: Enforces `SET default_transaction_read_only = on` on sessions and `BEGIN READ ONLY` on pool transactions.
3. **Destructive SQL Guardrails**:
   - AST/token analysis detects `DROP`, `TRUNCATE`, `ALTER`, `GRANT`, `REVOKE`, and unconstrained `DELETE`/`UPDATE` (missing `WHERE` clause).
   - Prompts with a high-friction confirmation modal detailing the exact target before execution.

---

## 8. Build Integration & Test Strategy

- **Build Integration**: Simple reproducible setup using an Xcode Run Script phase calling `scripts/build-rust-bridge.sh`.
- **Testing Layers**:
  1. *Rust Core Unit & Integration Tests*: Schema queries, `xmin` conflict detection, SQL safety classifier, and value serializer tests.
  2. *Bridge Tests (Milestone 1 Validation)*: Swift invoking Rust async functions, receiving typed data, catching typed errors, and executing cancellation.
  3. *Swift UI Component Tests*: View models, staged edit diff calculations, and Keychain service wrappers using Swift Testing.
