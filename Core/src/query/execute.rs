use std::collections::HashMap;
use std::sync::{LazyLock, RwLock};
use std::time::Instant;

use futures_util::pin_mut;
use futures_util::StreamExt;
use tokio_postgres::{CancelToken, Client};

use crate::connection::TransactionStatus;
use crate::error::LucidError;
use crate::query::value_mapper::map_cell_value;
use crate::query::RowData;
use crate::schema::ColumnMetadata;

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct QueryResult {
    pub columns: Vec<ColumnMetadata>,
    pub rows: Vec<RowData>,
    pub affected_rows: Option<u64>,
    pub status_message: String,
    pub execution_duration_ms: u64,
    pub is_truncated: bool,
    pub transaction_status: TransactionStatus,
}

static CANCELLATION_REGISTRY: LazyLock<RwLock<HashMap<String, CancelToken>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

pub fn register_cancel_token(query_id: &str, token: CancelToken) {
    if let Ok(mut reg) = CANCELLATION_REGISTRY.write() {
        reg.insert(query_id.to_string(), token);
    }
}

pub fn unregister_cancel_token(query_id: &str) {
    if let Ok(mut reg) = CANCELLATION_REGISTRY.write() {
        reg.remove(query_id);
    }
}

pub async fn cancel_active_query(query_id: &str) -> Result<bool, LucidError> {
    let token = {
        let reg = CANCELLATION_REGISTRY
            .read()
            .map_err(|e| LucidError::DatabaseError {
                code: "58000".into(),
                message: format!("Cancellation registry lock error: {}", e),
                detail: None,
            })?;
        reg.get(query_id).cloned()
    };

    if let Some(token) = token {
        // Send cancel request out-of-band to PostgreSQL
        let res = token.cancel_query(tokio_postgres::NoTls).await;
        match res {
            Ok(_) => Ok(true),
            Err(e) => {
                // If the connection was already closed or the query already completed,
                // cancel_query might report an error, which is safe to treat as not-cancelled.
                let msg = e.to_string();
                if msg.contains("broken pipe") || msg.contains("connection refused") {
                    Ok(false)
                } else {
                    Err(LucidError::DatabaseError {
                        code: "57014".into(),
                        message: format!("Failed to send query cancellation packet: {}", e),
                        detail: None,
                    })
                }
            }
        }
    } else {
        Ok(false)
    }
}

pub fn map_postgres_error(err: tokio_postgres::Error) -> LucidError {
    if let Some(db_err) = err.as_db_error() {
        let code = db_err.code().code().to_string();
        if code == "57014" {
            return LucidError::QueryCancelled;
        }

        let mut msg = db_err.message().to_string();
        if let Some(detail) = db_err.detail() {
            msg.push_str(&format!(" (Detail: {})", detail));
        }
        if let Some(hint) = db_err.hint() {
            msg.push_str(&format!(" (Hint: {})", hint));
        }
        if let Some(pos) = db_err.position() {
            match pos {
                tokio_postgres::error::ErrorPosition::Original(offset) => {
                    msg.push_str(&format!(" [position {}]", offset));
                }
                tokio_postgres::error::ErrorPosition::Internal { position, query } => {
                    msg.push_str(&format!(" [position {} in '{}']", position, query));
                }
            }
        }

        LucidError::DatabaseError {
            code,
            message: msg,
            detail: db_err.detail().map(|s| s.to_string()),
        }
    } else {
        let err_str = err.to_string();
        if err_str.contains("canceling statement")
            || err_str.contains("query was cancelled")
            || err_str.contains("user request")
        {
            LucidError::QueryCancelled
        } else {
            LucidError::DatabaseError {
                code: "XX000".to_string(),
                message: err_str,
                detail: None,
            }
        }
    }
}

pub async fn execute_sql(
    client: &Client,
    sql: &str,
    query_id: &str,
    max_rows: Option<u32>,
) -> Result<QueryResult, LucidError> {
    let trimmed = sql.trim();
    if trimmed.is_empty() {
        return Ok(QueryResult {
            columns: vec![],
            rows: vec![],
            affected_rows: None,
            status_message: "Empty query statement".to_string(),
            execution_duration_ms: 0,
            is_truncated: false,
            transaction_status: TransactionStatus::Idle,
        });
    }

    // Register cancel token for this in-flight query
    register_cancel_token(query_id, client.cancel_token());

    let start_time = Instant::now();

    // Prepare statement to determine whether it returns rows (SELECT/RETURNING) or rows affected (DML/DDL)
    let prepare_res = client.prepare(trimmed).await;
    let statement = match prepare_res {
        Ok(stmt) => stmt,
        Err(e) => {
            unregister_cancel_token(query_id);
            return Err(map_postgres_error(e));
        }
    };

    let col_defs = statement.columns();

    if col_defs.is_empty() {
        // DDL or DML without RETURNING (e.g., INSERT, UPDATE, DELETE, CREATE, DROP, ALTER)
        let exec_res = client.execute(&statement, &[]).await;
        unregister_cancel_token(query_id);

        let affected = exec_res.map_err(map_postgres_error)?;
        let duration_ms = start_time.elapsed().as_millis() as u64;

        let status_message = if affected == 1 {
            "Query executed successfully (1 row affected)".to_string()
        } else {
            format!("Query executed successfully ({} rows affected)", affected)
        };

        Ok(QueryResult {
            columns: vec![],
            rows: vec![],
            affected_rows: Some(affected),
            status_message,
            execution_duration_ms: duration_ms,
            is_truncated: false,
            transaction_status: TransactionStatus::Idle,
        })
    } else {
        // Query that returns rows (SELECT, SHOW, EXPLAIN, INSERT/UPDATE/DELETE RETURNING)
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
            });
        }

        let stream_res = client
            .query_raw(&statement, std::iter::empty::<i32>())
            .await;

        let stream = match stream_res {
            Ok(s) => s,
            Err(e) => {
                unregister_cancel_token(query_id);
                return Err(map_postgres_error(e));
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
                    return Err(map_postgres_error(e));
                }
            }
        }

        unregister_cancel_token(query_id);
        let duration_ms = start_time.elapsed().as_millis() as u64;

        let count = rows.len();
        let status_message = if is_truncated {
            format!(
                "Fetched first {} rows (truncated at limit) in {} ms",
                count, duration_ms
            )
        } else if count == 1 {
            format!("1 row returned in {} ms", duration_ms)
        } else {
            format!("{} rows returned in {} ms", count, duration_ms)
        };

        Ok(QueryResult {
            columns,
            rows,
            affected_rows: None,
            status_message,
            execution_duration_ms: duration_ms,
            is_truncated,
            transaction_status: TransactionStatus::Idle,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_sql_handling() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            // Test cancel when not found
            let cancelled = cancel_active_query("nonexistent_id").await.unwrap();
            assert!(!cancelled);
        });
    }

    #[tokio::test]
    async fn test_truncation_followed_by_query() {
        let user = std::env::var("USER").unwrap_or_else(|_| "postgres".into());
        let (client, connection) = tokio_postgres::Config::new()
            .host("localhost")
            .port(5432)
            .user(&user)
            .dbname("postgres")
            .connect(tokio_postgres::NoTls)
            .await
            .unwrap();

        tokio::spawn(async move {
            let _ = connection.await;
        });

        // 1. Run query with max_rows = 5 on a 100-row series
        let res1 = execute_sql(&client, "SELECT generate_series(1, 100);", "q1", Some(5)).await.unwrap();
        assert_eq!(res1.rows.len(), 5);
        assert!(res1.is_truncated);

        // 2. Immediately run a second query on the same connection
        let res2 = execute_sql(&client, "SELECT 42 as answer;", "q2", None).await.unwrap();
        assert_eq!(res2.rows.len(), 1);
        assert!(!res2.is_truncated);
    }
}
