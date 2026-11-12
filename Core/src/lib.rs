use std::sync::LazyLock;
use tokio::runtime::Runtime;

uniffi::setup_scaffolding!();

pub mod connection;
pub mod error;
pub mod export;
pub mod mutation;
pub mod query;
pub mod schema;

pub use connection::{ConnectionConfig, SessionInfo, TransactionStatus};
pub use error::LucidError;
pub use export::{CsvExportResult, ExportProgress, TableCsvExportRequest};
pub use mutation::{
    BatchMutationRequest, BatchMutationResult, InsertedRowResult, RowDelete, RowInsert, RowMutation,
};
pub use query::{CellValue, QueryResult, RecordPage, RowData};
pub use schema::{ColumnMetadata, TableInfo};

static TOKIO_RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to initialize Tokio runtime")
});

pub fn get_runtime() -> &'static Runtime {
    &TOKIO_RUNTIME
}

#[uniffi::export]
pub fn bridge_ping() -> String {
    "pong from rust".to_string()
}

#[uniffi::export]
pub async fn async_test_operation(delay_ms: u64) -> Result<String, LucidError> {
    get_runtime()
        .spawn(async move {
            tokio::time::sleep(tokio::time::Duration::from_millis(delay_ms)).await;
            Ok::<String, LucidError>(format!("completed after {}ms", delay_ms))
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub fn trigger_test_error(error_type: String) -> Result<(), LucidError> {
    match error_type.as_str() {
        "auth" => Err(LucidError::AuthenticationFailed {
            message: "invalid credentials".into(),
        }),
        "timeout" => Err(LucidError::QueryTimedOut { duration_ms: 5000 }),
        "readonly" => Err(LucidError::ReadOnlyViolation {
            attempted_operation: "DROP TABLE".into(),
        }),
        _ => Err(LucidError::DatabaseError {
            code: "42601".into(),
            message: "syntax error".into(),
            detail: None,
        }),
    }
}

#[uniffi::export]
pub async fn test_database_connection(config: ConnectionConfig) -> Result<String, LucidError> {
    get_runtime()
        .spawn(async move {
            let pool = connection::ManagedPool::new(&config)?;
            let client = pool.get().await?;
            let row = client
                .query_one("SELECT version();", &[])
                .await
                .map_err(|e| LucidError::DatabaseError {
                    code: "08000".into(),
                    message: e.to_string(),
                    detail: None,
                })?;
            let version: String = row.get(0);
            Ok(version)
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn introspect_schemas(config: ConnectionConfig) -> Result<Vec<String>, LucidError> {
    get_runtime()
        .spawn(async move {
            let pool = connection::ManagedPool::new(&config)?;
            let client = pool.get().await?;
            schema::query_schemas(&client).await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn introspect_tables(
    config: ConnectionConfig,
    schema: String,
) -> Result<Vec<TableInfo>, LucidError> {
    get_runtime()
        .spawn(async move {
            let pool = connection::ManagedPool::new(&config)?;
            let client = pool.get().await?;
            schema::query_tables(&client, &schema).await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn introspect_columns(
    config: ConnectionConfig,
    schema: String,
    table: String,
) -> Result<Vec<ColumnMetadata>, LucidError> {
    get_runtime()
        .spawn(async move {
            let pool = connection::ManagedPool::new(&config)?;
            let client = pool.get().await?;
            schema::query_columns(&client, &schema, &table).await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn fetch_table_page(
    config: ConnectionConfig,
    schema: String,
    table: String,
    offset: u64,
    limit: u32,
    sort_col: Option<String>,
    sort_desc: bool,
) -> Result<RecordPage, LucidError> {
    get_runtime()
        .spawn(async move {
            let pool = connection::ManagedPool::new(&config)?;
            let client = pool.get().await?;
            let cols = schema::query_columns(&client, &schema, &table).await?;
            let has_pk = cols.iter().any(|c| c.is_primary_key);
            query::fetch_page(
                &client, &schema, &table, offset, limit, sort_col, sort_desc, has_pk,
            )
            .await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn apply_table_mutations(
    config: ConnectionConfig,
    request: BatchMutationRequest,
    read_only: bool,
) -> Result<BatchMutationResult, LucidError> {
    if read_only {
        return Err(LucidError::ReadOnlyViolation {
            attempted_operation: "Table row mutations are not allowed in read-only mode.".into(),
        });
    }

    if schema::is_system_schema(&request.schema_name) {
        return Err(LucidError::ReadOnlyViolation {
            attempted_operation: format!(
                "System schema '{}' is read-only; catalog tables cannot be edited.",
                request.schema_name
            ),
        });
    }

    get_runtime()
        .spawn(async move {
            let pool = connection::ManagedPool::new(&config)?;
            let mut client = pool.get().await?;
            mutation::execute_batch_mutation(&mut client, request).await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn execute_session_query(
    config: ConnectionConfig,
    session_id: String,
    sql: String,
    query_id: String,
    max_rows: Option<u32>,
    read_only: bool,
) -> Result<QueryResult, LucidError> {
    get_runtime()
        .spawn(async move {
            connection::execute_session_script(
                &config,
                &session_id,
                &sql,
                &query_id,
                max_rows,
                read_only,
            )
            .await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn close_session(session_id: String) -> Result<(), LucidError> {
    get_runtime()
        .spawn(async move {
            connection::close_session(&session_id).await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn close_all_sessions() -> Result<(), LucidError> {
    get_runtime()
        .spawn(async move { connection::close_all_sessions().await })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub fn active_session_count() -> u32 {
    connection::active_session_count()
}

#[uniffi::export]
pub fn max_dedicated_sessions() -> u32 {
    connection::max_dedicated_sessions()
}

#[uniffi::export]
pub async fn set_session_read_only(
    session_id: String,
    read_only: bool,
) -> Result<SessionInfo, LucidError> {
    get_runtime()
        .spawn(async move {
            connection::set_session_read_only(&session_id, read_only).await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn get_session_info(session_id: String) -> Result<SessionInfo, LucidError> {
    get_runtime()
        .spawn(async move {
            connection::get_session_info(&session_id).await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn execute_query(
    config: ConnectionConfig,
    sql: String,
    query_id: String,
    max_rows: Option<u32>,
) -> Result<QueryResult, LucidError> {
    execute_session_query(
        config,
        "default_editor".to_string(),
        sql,
        query_id,
        max_rows,
        false,
    )
    .await
}

#[uniffi::export]
pub async fn cancel_query(query_id: String) -> Result<bool, LucidError> {
    get_runtime()
        .spawn(async move {
            query::cancel_active_query(&query_id).await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn export_fetched_rows_csv(
    columns: Vec<ColumnMetadata>,
    rows: Vec<RowData>,
    destination_path: String,
    exclude_leading_xmin: bool,
) -> Result<CsvExportResult, LucidError> {
    get_runtime()
        .spawn(async move {
            export::export_fetched_rows_csv(
                columns,
                rows,
                destination_path,
                exclude_leading_xmin,
            )
            .await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub async fn export_table_csv(
    config: ConnectionConfig,
    request: TableCsvExportRequest,
    destination_path: String,
    export_id: String,
) -> Result<CsvExportResult, LucidError> {
    get_runtime()
        .spawn(async move {
            export::export_table_csv(config, request, destination_path, export_id).await
        })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[uniffi::export]
pub fn get_export_progress(export_id: String) -> Option<ExportProgress> {
    export::get_export_progress(export_id)
}

#[uniffi::export]
pub async fn cancel_export(export_id: String) -> Result<bool, LucidError> {
    get_runtime()
        .spawn(async move { export::cancel_export(export_id).await })
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: e.to_string(),
            detail: None,
        })?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bridge_ping() {
        assert_eq!(bridge_ping(), "pong from rust");
    }

    #[tokio::test]
    async fn test_async_operation() {
        let res = async_test_operation(10).await;
        assert_eq!(res.unwrap(), "completed after 10ms");
    }

    #[test]
    fn test_trigger_errors() {
        let auth_err = trigger_test_error("auth".into()).unwrap_err();
        assert_eq!(
            auth_err,
            LucidError::AuthenticationFailed {
                message: "invalid credentials".into(),
            }
        );

        let timeout_err = trigger_test_error("timeout".into()).unwrap_err();
        assert_eq!(timeout_err, LucidError::QueryTimedOut { duration_ms: 5000 });

        let ro_err = trigger_test_error("readonly".into()).unwrap_err();
        assert_eq!(
            ro_err,
            LucidError::ReadOnlyViolation {
                attempted_operation: "DROP TABLE".into(),
            }
        );

        let other_err = trigger_test_error("unknown".into()).unwrap_err();
        assert_eq!(
            other_err,
            LucidError::DatabaseError {
                code: "42601".into(),
                message: "syntax error".into(),
                detail: None,
            }
        );
    }
}
