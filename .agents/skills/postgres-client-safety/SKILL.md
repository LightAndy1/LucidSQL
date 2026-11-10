---
name: postgres-client-safety
description: Use whenever implementing SQL execution, transactions, schema browsing, table editing, exports, credentials, connection handling, or database mutations.
---

# PostgreSQL client safety

## Connections

- Store passwords only in macOS Keychain.
- Never store passwords in plaintext files, SQLite databases, logs, screenshots, or exported configuration.
- Never log full connection URLs, passwords, tokens, or sensitive query parameters.
- Support read-only connection mode.
- Clearly display host, database, user, SSL state, and read-only status before executing queries.
- Use connection pooling; do not open a new PostgreSQL connection for every query.
- Close or return connections safely, including after errors and cancellation.

## SQL execution

- Use parameterized queries; never interpolate user values into SQL.
- Enforce a query timeout and row limit for ad hoc queries.
- Support cancellation through PostgreSQL cancellation.
- Run only the selected SQL statement by default.
- Require explicit user action before executing multiple statements.
- Never auto-commit destructive statements.
- Show query duration, row count, truncation status, and errors clearly.

## Dangerous SQL

Require explicit confirmation before executing:

- `DROP`
- `TRUNCATE`
- `ALTER`
- `CREATE`
- `GRANT`
- `REVOKE`
- `DELETE` without a `WHERE` clause
- `UPDATE` without a `WHERE` clause
- Statements likely to lock tables for a long time

Treat these as high-risk operations even if the user is connected as a read-only database user.

## Transactions

- Use explicit transactions only when the user starts one.
- Provide clear commit and rollback controls.
- Never leave a transaction open after an error or app termination without a defined recovery path.
- Show transaction state in the UI.
- Do not mix schema exploration and transactional edits in confusing ways.

## Schema metadata

- Read metadata from PostgreSQL catalogs and `information_schema`.
- Cache schema data per connection.
- Refresh manually or after detected DDL changes.
- Do not aggressively poll metadata.
- Handle large schemas without loading every object into memory.

## Results and editing

- Fetch results in bounded pages.
- Use virtualization for large result sets.
- Preserve `NULL` distinctly from an empty string.
- Clearly indicate truncated results.
- Allow cell editing only when a reliable primary key or row identifier exists.
- Require confirmation for destructive row operations.
- Use parameterized updates; never build SQL by string interpolation.

## Exports

- Stream large exports instead of loading entire result sets into memory.
- Sanitize CSV values to prevent formula injection.
- Do not include credentials or connection metadata in exports.
- Show export progress and allow cancellation.

## Testing

- Test query parsing, parameter binding, pagination, cancellation, and error handling.
- Test destructive-query detection.
- Test read-only mode.
- Test connection failure, timeout, and cancellation paths.
- Never test against production databases.
