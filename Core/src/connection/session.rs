use std::collections::HashMap;
use std::sync::LazyLock;
use std::time::Instant;

use futures_util::pin_mut;
use futures_util::StreamExt;
use tokio::sync::Mutex;
use tokio_postgres::{Client, NoTls};

use crate::connection::ConnectionConfig;
use crate::error::LucidError;
use crate::query::execute::{map_postgres_error, register_cancel_token, unregister_cancel_token, QueryResult};
use crate::query::splitter::{extract_first_keyword, split_statements};
use crate::query::value_mapper::map_cell_value;
use crate::query::RowData;
use crate::schema::ColumnMetadata;

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransactionStatus {
    Idle,
    InTransaction,
    FailedTransaction,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct SessionInfo {
    pub id: String,
    pub is_read_only: bool,
    pub transaction_status: TransactionStatus,
    pub backend_pid: u32,
}

pub struct DedicatedSession {
    pub id: String,
    pub client: Client,
    pub backend_pid: u32,
    pub is_read_only: bool,
    pub transaction_status: TransactionStatus,
    pub conn_handle: tokio::task::JoinHandle<()>,
}

static SESSIONS: LazyLock<Mutex<HashMap<String, DedicatedSession>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

pub async fn get_or_create_session(
    config: &ConnectionConfig,
    session_id: &str,
    read_only: bool,
) -> Result<(), LucidError> {
    let mut sessions = SESSIONS.lock().await;

    if let Some(existing) = sessions.get_mut(session_id) {
        if existing.client.is_closed() {
            sessions.remove(session_id);
            return Err(LucidError::ConnectionFailed {
                reason: "Dedicated SQL session connection was lost or closed by the server. Reconnect to establish a fresh session.".into(),
            });
        }
        return Ok(());
    }

    let mut pg_config = tokio_postgres::Config::new();
    pg_config.host(&config.host);
    pg_config.port(config.port);
    pg_config.dbname(&config.database);
    pg_config.user(&config.user);
    if let Some(ref pass) = config.password {
        pg_config.password(pass);
    }
    pg_config.connect_timeout(std::time::Duration::from_secs(config.timeout_seconds as u64));

    let (client, connection) = pg_config.connect(NoTls).await.map_err(|e| {
        LucidError::ConnectionFailed {
            reason: e.to_string(),
        }
    })?;

    let conn_handle = tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("Session background connection error: {}", e);
        }
    });

    let pid_row = client
        .query_one("SELECT pg_backend_pid()", &[])
        .await
        .map_err(map_postgres_error)?;
    let backend_pid: i32 = pid_row.get(0);

    if read_only {
        client
            .batch_execute(
                "SET default_transaction_read_only = on; SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;",
            )
            .await
            .map_err(map_postgres_error)?;
    }

    sessions.insert(
        session_id.to_string(),
        DedicatedSession {
            id: session_id.to_string(),
            client,
            backend_pid: backend_pid as u32,
            is_read_only: read_only,
            transaction_status: TransactionStatus::Idle,
            conn_handle,
        },
    );

    Ok(())
}

pub async fn close_session(session_id: &str) -> Result<(), LucidError> {
    let mut sessions = SESSIONS.lock().await;
    if let Some(session) = sessions.remove(session_id) {
        if session.transaction_status != TransactionStatus::Idle {
            // Attempt clean rollback
            let _ = session.client.batch_execute("ROLLBACK;").await;
        }
        session.conn_handle.abort();
    }
    Ok(())
}

pub async fn set_session_read_only(
    session_id: &str,
    read_only: bool,
) -> Result<SessionInfo, LucidError> {
    let mut sessions = SESSIONS.lock().await;
    let session = sessions.get_mut(session_id).ok_or_else(|| {
        LucidError::ConnectionFailed {
            reason: format!("Session '{}' not found", session_id),
        }
    })?;

    if session.transaction_status == TransactionStatus::InTransaction {
        return Err(LucidError::ReadOnlyViolation {
            attempted_operation:
                "Cannot toggle read-only mode while inside an active transaction. Please commit or rollback first."
                    .into(),
        });
    }

    let sql = if read_only {
        "SET default_transaction_read_only = on; SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;"
    } else {
        "SET default_transaction_read_only = off; SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE;"
    };

    session
        .client
        .batch_execute(sql)
        .await
        .map_err(map_postgres_error)?;
    session.is_read_only = read_only;

    Ok(SessionInfo {
        id: session.id.clone(),
        is_read_only: session.is_read_only,
        transaction_status: session.transaction_status,
        backend_pid: session.backend_pid,
    })
}

pub async fn get_session_info(session_id: &str) -> Result<SessionInfo, LucidError> {
    let sessions = SESSIONS.lock().await;
    let session = sessions.get(session_id).ok_or_else(|| {
        LucidError::ConnectionFailed {
            reason: format!("Session '{}' not found", session_id),
        }
    })?;

    Ok(SessionInfo {
        id: session.id.clone(),
        is_read_only: session.is_read_only,
        transaction_status: session.transaction_status,
        backend_pid: session.backend_pid,
    })
}

pub async fn execute_session_script(
    config: &ConnectionConfig,
    session_id: &str,
    sql: &str,
    query_id: &str,
    max_rows: Option<u32>,
    read_only_requested: bool,
) -> Result<QueryResult, LucidError> {
    // Ensure session is connected
    get_or_create_session(config, session_id, read_only_requested).await?;

    let mut sessions = SESSIONS.lock().await;
    let session = sessions.get_mut(session_id).ok_or_else(|| {
        LucidError::ConnectionFailed {
            reason: format!("Session '{}' not found", session_id),
        }
    })?;

    if session.client.is_closed() {
        sessions.remove(session_id);
        return Err(LucidError::ConnectionFailed {
            reason: "Dedicated SQL session connection was lost or closed by the server. Reconnect to start a fresh session.".into(),
        });
    }

    // Sync read-only mode if requested differently and not inside an open transaction
    if session.is_read_only != read_only_requested {
        if session.transaction_status == TransactionStatus::Idle {
            let toggle_sql = if read_only_requested {
                "SET default_transaction_read_only = on; SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;"
            } else {
                "SET default_transaction_read_only = off; SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE;"
            };
            if let Err(e) = session.client.batch_execute(toggle_sql).await {
                return Err(map_postgres_error(e));
            }
            session.is_read_only = read_only_requested;
        } else if read_only_requested && !session.is_read_only {
            return Err(LucidError::ReadOnlyViolation {
                attempted_operation:
                    "Cannot enable read-only mode inside an active transaction. Commit or rollback first."
                        .into(),
            });
        }
    }

    let statements = split_statements(sql);
    if statements.is_empty() {
        return Ok(QueryResult {
            columns: vec![],
            rows: vec![],
            affected_rows: None,
            status_message: "Empty query statement".into(),
            execution_duration_ms: 0,
            is_truncated: false,
            transaction_status: session.transaction_status,
        });
    }

    // Register cancellation token
    register_cancel_token(query_id, session.client.cancel_token());

    let start_time = Instant::now();
    let total_statements = statements.len();
    let mut total_affected: Option<u64> = None;
    let mut last_row_result: Option<(Vec<ColumnMetadata>, Vec<RowData>, bool)> = None;

    for (_stmt_idx, stmt) in statements.iter().enumerate() {
        let trimmed = stmt.trim();
        let upper = trimmed.to_uppercase();
        let first_kw = extract_first_keyword(trimmed);

        // Enforce accidental-write read-only mode in Rust execution path:
        // 1. Guard against commands attempting to disable read-only mode
        // 2. Guard against mutations (INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE, CREATE, GRANT, REVOKE)
        //
        // LIMITATIONS NOTE:
        // This is an application-level guardrail designed to prevent accidental modifications during
        // browsing and analysis. It is not an adversarial security boundary; true database authorization
        // must be enforced by PostgreSQL roles and permissions on the server.
        if session.is_read_only {
            if (upper.contains("DEFAULT_TRANSACTION_READ_ONLY") && (upper.contains("OFF") || upper.contains("FALSE")))
                || upper.contains("TRANSACTION READ WRITE")
            {
                unregister_cancel_token(query_id);
                return Err(LucidError::ReadOnlyViolation {
                    attempted_operation: "Cannot disable read-only mode within a read-only session."
                        .into(),
                });
            }

            if let Some(ref kw) = first_kw {
                match kw.as_str() {
                    "INSERT" | "UPDATE" | "DELETE" | "DROP" | "ALTER" | "TRUNCATE" | "GRANT" | "REVOKE" => {
                        unregister_cancel_token(query_id);
                        return Err(LucidError::ReadOnlyViolation {
                            attempted_operation: format!("Cannot execute {} in read-only mode.", kw),
                        });
                    }
                    "CREATE" => {
                        // Allow CREATE TEMP/TEMPORARY objects, but reject persistent schema modifications
                        if !upper.contains("TEMP") && !upper.contains("TEMPORARY") {
                            unregister_cancel_token(query_id);
                            return Err(LucidError::ReadOnlyViolation {
                                attempted_operation: "Cannot execute CREATE on persistent objects in read-only mode."
                                    .into(),
                            });
                        }
                    }
                    _ => {}
                }
            }
        }

        // Execute statement
        let prepare_res = session.client.prepare(trimmed).await;
        let statement = match prepare_res {
            Ok(s) => s,
            Err(e) => {
                unregister_cancel_token(query_id);
                let err = map_postgres_error(e);
                if session.transaction_status == TransactionStatus::InTransaction {
                    session.transaction_status = TransactionStatus::FailedTransaction;
                }
                return Err(err);
            }
        };

        let col_defs = statement.columns();

        if col_defs.is_empty() {
            // Command (INSERT, UPDATE, DELETE, DDL, BEGIN, COMMIT, ROLLBACK, SET)
            let exec_res = session.client.execute(&statement, &[]).await;
            match exec_res {
                Ok(affected) => {
                    total_affected = Some(total_affected.unwrap_or(0) + affected);

                    // Track transaction state changes
                    if let Some(ref kw) = first_kw {
                        match kw.as_str() {
                            "BEGIN" | "START" => {
                                session.transaction_status = TransactionStatus::InTransaction;
                            }
                            "COMMIT" | "END" => {
                                session.transaction_status = TransactionStatus::Idle;
                            }
                            "ROLLBACK" | "ABORT" => {
                                if upper.contains("TO ") || upper.contains("TO SAVEPOINT") {
                                    if session.transaction_status == TransactionStatus::FailedTransaction {
                                        session.transaction_status = TransactionStatus::InTransaction;
                                    }
                                } else {
                                    session.transaction_status = TransactionStatus::Idle;
                                }
                            }
                            _ => {}
                        }
                    }
                }
                Err(e) => {
                    unregister_cancel_token(query_id);
                    let err = map_postgres_error(e);
                    if session.transaction_status == TransactionStatus::InTransaction {
                        session.transaction_status = TransactionStatus::FailedTransaction;
                    }
                    return Err(err);
                }
            }
        } else {
            // Query returning rows (SELECT, SHOW, EXPLAIN, RETURNING)
            let mut columns = Vec::with_capacity(col_defs.len());
            for (idx, col) in col_defs.iter().enumerate() {
                columns.push(ColumnMetadata {
                    name: col.name().to_string(),
                    ordinal_position: idx as u32 + 1,
                    pg_type_name: col.type_().name().to_string(),
                    pg_type_oid: col.type_().oid(),
                    is_primary_key: false,
                    is_nullable: true,
                    default_value: None,
                    is_generated: false,
                });
            }

            let stream_res = session
                .client
                .query_raw(&statement, std::iter::empty::<i32>())
                .await;

            let stream = match stream_res {
                Ok(s) => s,
                Err(e) => {
                    unregister_cancel_token(query_id);
                    let err = map_postgres_error(e);
                    if session.transaction_status == TransactionStatus::InTransaction {
                        session.transaction_status = TransactionStatus::FailedTransaction;
                    }
                    return Err(err);
                }
            };

            pin_mut!(stream);

            let row_limit = max_rows.unwrap_or(1000) as usize;
            let mut rows = Vec::new();
            let mut is_truncated = false;

            while let Some(row_result) = stream.next().await {
                match row_result {
                    Ok(row) => {
                        if rows.len() < row_limit {
                            let mut cells = Vec::with_capacity(columns.len());
                            for i in 0..columns.len() {
                                cells.push(map_cell_value(&row, i));
                            }
                            rows.push(RowData { cells });
                        } else {
                            is_truncated = true;
                            break;
                        }
                    }
                    Err(e) => {
                        unregister_cancel_token(query_id);
                        let err = map_postgres_error(e);
                        if session.transaction_status == TransactionStatus::InTransaction {
                            session.transaction_status = TransactionStatus::FailedTransaction;
                        }
                        return Err(err);
                    }
                }
            }

            last_row_result = Some((columns, rows, is_truncated));
        }
    }

    unregister_cancel_token(query_id);
    let duration_ms = start_time.elapsed().as_millis() as u64;

    if let Some((columns, rows, is_truncated)) = last_row_result {
        let count = rows.len();
        let status_message = if is_truncated {
            format!(
                "Fetched first {} rows (truncated at limit) in {} ms",
                count, duration_ms
            )
        } else if total_statements > 1 {
            format!(
                "{} rows returned ({} statements executed in {} ms)",
                count, total_statements, duration_ms
            )
        } else if count == 1 {
            format!("1 row returned in {} ms", duration_ms)
        } else {
            format!("{} rows returned in {} ms", count, duration_ms)
        };

        Ok(QueryResult {
            columns,
            rows,
            affected_rows: total_affected,
            status_message,
            execution_duration_ms: duration_ms,
            is_truncated,
            transaction_status: session.transaction_status,
        })
    } else {
        let affected = total_affected.unwrap_or(0);
        let status_message = if total_statements > 1 {
            format!(
                "{} statements executed successfully ({} rows affected in {} ms)",
                total_statements, affected, duration_ms
            )
        } else if affected == 1 {
            format!(
                "Query executed successfully (1 row affected in {} ms)",
                duration_ms
            )
        } else {
            format!(
                "Query executed successfully ({} rows affected in {} ms)",
                affected, duration_ms
            )
        };

        Ok(QueryResult {
            columns: vec![],
            rows: vec![],
            affected_rows: Some(affected),
            status_message,
            execution_duration_ms: duration_ms,
            is_truncated: false,
            transaction_status: session.transaction_status,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query::CellValue;

    fn get_test_config() -> ConnectionConfig {
        let user = std::env::var("USER").unwrap_or_else(|_| "postgres".into());
        ConnectionConfig {
            host: "localhost".into(),
            port: 5432,
            database: "postgres".into(),
            user,
            password: None,
            ssl_mode: "disable".into(),
            timeout_seconds: 5,
        }
    }

    #[tokio::test]
    async fn test_session_state_persistence() {
        let config = get_test_config();
        let session_id = "test_session_state_persistence";

        // 1. Set timezone on dedicated session
        execute_session_script(&config, session_id, "SET timezone = 'UTC';", "q1", None, false)
            .await
            .unwrap();

        // 2. Query timezone on same dedicated session
        let res = execute_session_script(&config, session_id, "SHOW timezone;", "q2", None, false)
            .await
            .unwrap();

        assert_eq!(res.rows.len(), 1);
        if let CellValue::Text(val) = &res.rows[0].cells[0] {
            assert_eq!(val, "UTC");
        } else {
            panic!("Expected UTC timezone string");
        }

        close_session(session_id).await.unwrap();
    }

    #[tokio::test]
    async fn test_session_temp_table_persistence() {
        let config = get_test_config();
        let session_id = "test_session_temp_table";

        // 1. Create temporary table and insert rows
        let setup_sql = "CREATE TEMP TABLE t_session_test (id int, label text); INSERT INTO t_session_test VALUES (1, 'apple'), (2, 'banana');";
        execute_session_script(&config, session_id, setup_sql, "q1", None, false)
            .await
            .unwrap();

        // 2. Query the temporary table in a subsequent script
        let query_sql = "SELECT id, label FROM t_session_test ORDER BY id;";
        let res = execute_session_script(&config, session_id, query_sql, "q2", None, false)
            .await
            .unwrap();

        assert_eq!(res.rows.len(), 2);
        assert_eq!(res.columns.len(), 2);
        if let CellValue::Text(val) = &res.rows[0].cells[1] {
            assert_eq!(val, "apple");
        } else {
            panic!("Expected 'apple'");
        }

        close_session(session_id).await.unwrap();
    }

    #[tokio::test]
    async fn test_session_transaction_commit_and_rollback() {
        let config = get_test_config();
        let session_id = "test_session_tx";

        // 1. Begin transaction and create a temp table
        let res1 = execute_session_script(&config, session_id, "BEGIN;", "q1", None, false)
            .await
            .unwrap();
        assert_eq!(res1.transaction_status, TransactionStatus::InTransaction);

        // 2. Rollback transaction
        let res2 = execute_session_script(&config, session_id, "ROLLBACK;", "q2", None, false)
            .await
            .unwrap();
        assert_eq!(res2.transaction_status, TransactionStatus::Idle);

        close_session(session_id).await.unwrap();
    }

    #[tokio::test]
    async fn test_session_aborted_transaction_recovery() {
        let config = get_test_config();
        let session_id = "test_session_abort_recovery";

        // 1. Begin transaction
        let res1 = execute_session_script(&config, session_id, "BEGIN;", "q1", None, false)
            .await
            .unwrap();
        assert_eq!(res1.transaction_status, TransactionStatus::InTransaction);

        // 2. Execute failing statement inside transaction
        let fail_res = execute_session_script(&config, session_id, "SELECT 1/0;", "q2", None, false)
            .await;
        assert!(fail_res.is_err());

        // 3. Verify session status is FailedTransaction
        let info = get_session_info(session_id).await.unwrap();
        assert_eq!(info.transaction_status, TransactionStatus::FailedTransaction);

        // 4. Any subsequent normal statement fails with 25P02
        let blocked = execute_session_script(&config, session_id, "SELECT 1;", "q3", None, false)
            .await;
        assert!(blocked.is_err());
        if let Err(LucidError::DatabaseError { code, .. }) = blocked {
            assert_eq!(code, "25P02");
        } else {
            panic!("Expected 25P02 transaction aborted error");
        }

        // 5. ROLLBACK succeeds and restores Idle status
        let rollback_res = execute_session_script(&config, session_id, "ROLLBACK;", "q4", None, false)
            .await
            .unwrap();
        assert_eq!(rollback_res.transaction_status, TransactionStatus::Idle);

        // 6. Subsequent statement now succeeds
        let success = execute_session_script(&config, session_id, "SELECT 42;", "q5", None, false)
            .await
            .unwrap();
        assert_eq!(success.rows.len(), 1);

        close_session(session_id).await.unwrap();
    }

    #[tokio::test]
    async fn test_session_read_only_enforcement() {
        let config = get_test_config();
        let session_id = "test_session_read_only";

        // 1. Connect in read-only mode
        get_or_create_session(&config, session_id, true).await.unwrap();

        // 2. Direct mutation is blocked by Rust guardrail
        let blocked_insert = execute_session_script(
            &config,
            session_id,
            "INSERT INTO nonexistent VALUES (1);",
            "q1",
            None,
            true,
        )
        .await;
        assert!(blocked_insert.is_err());
        match blocked_insert {
            Err(LucidError::ReadOnlyViolation { .. }) => {}
            _ => panic!("Expected ReadOnlyViolation error"),
        }

        // 3. Attempting to disable read-only via SQL is blocked
        let blocked_set = execute_session_script(
            &config,
            session_id,
            "SET default_transaction_read_only = off;",
            "q2",
            None,
            true,
        )
        .await;
        assert!(blocked_set.is_err());

        // 4. Read query succeeds
        let ok_query = execute_session_script(
            &config,
            session_id,
            "SELECT 100 as safe_val;",
            "q3",
            None,
            true,
        )
        .await
        .unwrap();
        assert_eq!(ok_query.rows.len(), 1);

        close_session(session_id).await.unwrap();
    }

    #[tokio::test]
    async fn test_session_multi_statement_script() {
        let config = get_test_config();
        let session_id = "test_session_multi_script";

        let script = r#"
            -- First statement: create temporary table
            CREATE TEMP TABLE t_multi_items (id int, name text);

            /* Second statement: insert with semicolon inside string literal */
            INSERT INTO t_multi_items VALUES (1, 'item; with semicolon');

            -- Third statement: query
            SELECT name FROM t_multi_items WHERE id = 1;
        "#;

        let res = execute_session_script(&config, session_id, script, "q1", None, false)
            .await
            .unwrap();

        assert_eq!(res.rows.len(), 1);
        if let CellValue::Text(val) = &res.rows[0].cells[0] {
            assert_eq!(val, "item; with semicolon");
        } else {
            panic!("Expected text value");
        }
        assert!(res.status_message.contains("3 statements executed"));

        close_session(session_id).await.unwrap();
    }
}
