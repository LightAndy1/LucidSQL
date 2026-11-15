# LucidSQL Technical Reference

Detailed storage locations, session semantics, TLS options, and packaging notes for LucidSQL. For release distribution and CI packaging flags, see [docs/DISTRIBUTION.md](DISTRIBUTION.md).

## Privacy & Local Storage

LucidSQL collects no telemetry, crash reports, or analytics, and makes no network connections other than direct PostgreSQL connections you initiate.

- **Saved connection profiles:** Stored locally in JSON at `~/Library/Application Support/LucidSQL/profiles.json`. Passwords are never written to `profiles.json`.
- **Passwords:** Stored in the macOS Keychain under service `com.lucidsql.connection-passwords` when **Remember password in macOS Keychain** is enabled (`useKeychain: true`). When disabled, passwords live in process memory for the current session only.
- **SQL drafts & preferences:** Optional SQL editor draft persistence writes to `~/Library/Application Support/LucidSQL/sql_drafts.json` and can be disabled in **Settings** (`UserDefaults`).

## Connection & TLS Options

- **Connection strings:** Supports importing `postgres://` and `postgresql://` connection URLs alongside manual profile configuration.
- **TLS / SSL modes:** Supports `disable`, `prefer`, `require`, `verify-ca`, and `verify-full`, with an optional custom root CA certificate path.
- **Transport scope:** Direct TCP/TLS connections only. Built-in SSH tunneling, multi-host failover connection strings, and Unix-socket `postgres://` URLs are not supported.

## Sessions, Transactions & Safety

- **Shared browsing pool vs. per-tab SQL sessions:** Schema exploration and table browsing run over a bounded `deadpool-postgres` pool. Each SQL editor tab lazily opens its own persistent PostgreSQL connection (`tokio-postgres`) so `search_path`, temporary tables, and open transactions stay isolated per tab.
- **Close-tab transaction guard:** Closing an SQL editor tab or disconnecting while a transaction is open prompts before closing and issues `ROLLBACK` rather than auto-committing.
- **Staged in-grid editing:** Cell edits, row inserts, and row deletes are staged locally in memory without holding an open database transaction while typing. Saving opens a pre-commit diff review and applies changes atomically inside a short transaction using `UPDATE ... WHERE pk = $1 AND xmin = $2` optimistic concurrency checks; any conflict or database error triggers an immediate `ROLLBACK` and preserves staged edits on screen.
- **Lossless types:** Preserves distinct `NULL` (`⌥⌘N`) vs. empty string `""`, exact string representation for `numeric`/`decimal` values, and timezone-naive vs. timezone-aware timestamp formatting.
- **Dual-enforced Read-Only mode:** Enabling the toolbar Read-Only toggle disables mutation UI in SwiftUI/AppKit and enforces `SET default_transaction_read_only = on` on dedicated sessions alongside `BEGIN READ ONLY` on pool transactions in Rust.

## Table Search, Results & CSV Export

- **Non-SQL Table Search (`⌘F`):** Performs case-insensitive literal filtering across all searchable scalar columns or a chosen column, paired with configurable page sizes (`25`, `50`, `100`, `250`, `500` rows per page) and Go-to-Page navigation. Non-scalar columns (binary/`bytea`, JSON/`jsonb`, arrays, geometric types, and ranges) are excluded from table search.
- **SQL query row limit:** SQL editor result grids cap displayed output at `1,000` rows by default.
- **Snapshot CSV export:** Exports the current page or full table in RFC 4180 CSV format streamed inside a `REPEATABLE READ READ ONLY` transaction snapshot. CSV export always reads committed database rows (unstaged in-grid edits are excluded) and writes raw cell values.

## Toolchain & Fallback Notes

- **Architecture:** Apple Silicon (`arm64`) only; Intel (`x86_64`) builds are not provided or supported.
- **SDK appearance & icon compilation:** Building and packaging with **Xcode 26+** SDK activates macOS 26+ Liquid Glass window/toolbar chrome and compiles `Assets/AppIcon/LucidSQL.icon` via `actool` into `Assets.car` while bundling the full 10-size fallback `LucidSQL.icns`. CommandLineTools-only builds omit `Assets.car` and fall back to standard system chrome and `LucidSQL.icns`.
- **Distribution flags:** CI enforces `--require-liquid-glass` and `--require-native-icon` in `scripts/package-app.sh` and `scripts/verify-dmg.sh`; see [docs/DISTRIBUTION.md](DISTRIBUTION.md).
