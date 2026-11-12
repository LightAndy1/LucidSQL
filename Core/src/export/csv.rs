use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, RwLock};
use std::time::{Duration, Instant};

use futures_util::{pin_mut, StreamExt};
use tokio::io::{AsyncWriteExt, BufWriter};
use tokio::sync::Notify;

use crate::connection::tls::CancelTlsTarget;
use crate::connection::{ConnectionConfig, ManagedPool};
use crate::error::LucidError;
use crate::query::execute::{
    cancel_active_query, map_postgres_error, register_cancel_token_with_tls,
    unregister_cancel_token,
};
use crate::query::{map_cell_value, CellValue, RowData};
use crate::schema::{query_columns, ColumnMetadata};

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct CsvExportResult {
    pub destination_path: String,
    pub rows_exported: u64,
    pub bytes_written: u64,
    pub execution_duration_ms: u64,
    pub snapshot_isolation: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ExportProgress {
    pub export_id: String,
    pub rows_exported: u64,
    pub bytes_written: u64,
    pub is_finished: bool,
    pub is_cancelled: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct TableCsvExportRequest {
    pub schema_name: String,
    pub table_name: String,
    pub sort_col: Option<String>,
    pub sort_desc: bool,
}

struct ExportRunState {
    rows_exported: AtomicU64,
    bytes_written: AtomicU64,
    is_finished: AtomicBool,
    is_cancelled: AtomicBool,
    cancel_notify: Notify,
}

impl ExportRunState {
    fn new() -> Self {
        Self {
            rows_exported: AtomicU64::new(0),
            bytes_written: AtomicU64::new(0),
            is_finished: AtomicBool::new(false),
            is_cancelled: AtomicBool::new(false),
            cancel_notify: Notify::new(),
        }
    }

    fn snapshot(&self, export_id: &str) -> ExportProgress {
        ExportProgress {
            export_id: export_id.to_string(),
            rows_exported: self.rows_exported.load(Ordering::Acquire),
            bytes_written: self.bytes_written.load(Ordering::Acquire),
            is_finished: self.is_finished.load(Ordering::Acquire),
            is_cancelled: self.is_cancelled.load(Ordering::Acquire),
        }
    }
}

static EXPORT_REGISTRY: LazyLock<RwLock<HashMap<String, Arc<ExportRunState>>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

struct ExportStateGuard {
    export_id: String,
    state: Arc<ExportRunState>,
    has_cancel_token: bool,
}

impl Drop for ExportStateGuard {
    fn drop(&mut self) {
        self.state.is_finished.store(true, Ordering::Release);
        if self.has_cancel_token {
            unregister_cancel_token(&self.export_id);
        }
    }
}

struct TempFileGuard {
    path: Option<PathBuf>,
}

impl TempFileGuard {
    fn disarm(&mut self) {
        self.path = None;
    }

    async fn cleanup_now(&mut self) {
        if let Some(p) = self.path.take() {
            let _ = tokio::fs::remove_file(p).await;
        }
    }
}

impl Drop for TempFileGuard {
    fn drop(&mut self) {
        if let Some(p) = self.path.take() {
            let _ = std::fs::remove_file(p);
        }
    }
}

/// Formats a single string field according to RFC 4180 CSV rules.
/// Non-null empty strings (`""`) are explicitly emitted as `""` so they remain
/// distinguishable on disk from SQL NULL (which is emitted as an unquoted empty field).
pub fn write_rfc4180_field(value: &str, out: &mut String) {
    if value.is_empty() {
        out.push_str("\"\"");
        return;
    }

    let needs_quotes = value
        .bytes()
        .any(|b| matches!(b, b',' | b'"' | b'\n' | b'\r'));

    if !needs_quotes {
        out.push_str(value);
        return;
    }

    out.push('"');
    for ch in value.chars() {
        if ch == '"' {
            out.push_str("\"\"");
        } else {
            out.push(ch);
        }
    }
    out.push('"');
}

/// Formats one lossless `CellValue` into `out` using canonical RFC 4180 CSV + Postgres semantics:
/// - `CellValue::Null` -> unquoted empty field (``)
/// - `CellValue::Text("")` -> quoted empty field (`""`)
/// - `CellValue::Unsupported` -> explicit error (never emits UI placeholder strings)
pub fn write_csv_cell(col_name: &str, value: &CellValue, out: &mut String) -> Result<(), LucidError> {
    match value {
        CellValue::Null => Ok(()),
        CellValue::Text(s) => {
            write_rfc4180_field(s, out);
            Ok(())
        }
        CellValue::Boolean(b) => {
            out.push_str(if *b { "true" } else { "false" });
            Ok(())
        }
        CellValue::Integer(i) => {
            let _ = write!(out, "{}", i);
            Ok(())
        }
        CellValue::Float(f) => {
            let _ = write!(out, "{}", f);
            Ok(())
        }
        CellValue::Decimal(s)
        | CellValue::TimestampWithTimeZone(s)
        | CellValue::TimestampWithoutTimeZone(s)
        | CellValue::Date(s)
        | CellValue::Time(s)
        | CellValue::Uuid(s)
        | CellValue::BinaryHex(s)
        | CellValue::Json(s) => {
            write_rfc4180_field(s, out);
            Ok(())
        }
        CellValue::Unsupported(reason) => Err(LucidError::DatabaseError {
            code: "22023".into(),
            message: format!(
                "Cannot export column '{}' (type '{}'): fetched results do not contain a lossless text representation for this PostgreSQL type. Cast the column with \"{}\"::text in SQL or use full-table streaming export.",
                col_name, reason, col_name
            ),
            detail: Some("Unsupported PostgreSQL types cannot be exported as UI placeholder text.".into()),
        }),
    }
}

pub fn format_csv_header(columns: &[ColumnMetadata], out: &mut String) {
    out.clear();
    for (idx, col) in columns.iter().enumerate() {
        if idx > 0 {
            out.push(',');
        }
        write_rfc4180_field(&col.name, out);
    }
    out.push('\n');
}

pub fn format_csv_row(
    columns: &[ColumnMetadata],
    cells: &[CellValue],
    out: &mut String,
) -> Result<(), LucidError> {
    out.clear();
    for (idx, col) in columns.iter().enumerate() {
        if idx > 0 {
            out.push(',');
        }
        let val = cells.get(idx).unwrap_or(&CellValue::Null);
        write_csv_cell(&col.name, val, out)?;
    }
    out.push('\n');
    Ok(())
}

/// Returns true for PostgreSQL types natively decoded losslessly by `value_mapper::map_cell_value`.
/// Any other column type is projected with `::text` in full-table exports so PostgreSQL supplies
/// its canonical text representation.
pub fn is_csv_natively_mapped_pg_type(pg_type_name: &str) -> bool {
    matches!(
        pg_type_name.to_ascii_lowercase().as_str(),
        "bool"
            | "int2"
            | "int4"
            | "int8"
            | "oid"
            | "xid"
            | "cid"
            | "regproc"
            | "regprocedure"
            | "regoper"
            | "regoperator"
            | "regclass"
            | "regtype"
            | "regconfig"
            | "regdictionary"
            | "regnamespace"
            | "regrole"
            | "regcollation"
            | "xid8"
            | "char"
            | "numeric"
            | "decimal"
            | "float4"
            | "float8"
            | "text"
            | "varchar"
            | "bpchar"
            | "name"
            | "uuid"
            | "timestamptz"
            | "timestamp"
            | "date"
            | "time"
            | "bytea"
            | "json"
            | "jsonb"
            | "inet"
            | "cidr"
            | "macaddr"
            | "_bool"
            | "_int2"
            | "_int4"
            | "_int8"
            | "_oid"
            | "_float4"
            | "_float8"
            | "_text"
            | "_varchar"
            | "_bpchar"
            | "_name"
            | "_uuid"
    )
}

fn validate_and_prepare_paths(destination_path: &str) -> Result<(PathBuf, PathBuf), LucidError> {
    let trimmed = destination_path.trim();
    if trimmed.is_empty() {
        return Err(LucidError::DatabaseError {
            code: "22023".into(),
            message: "Export destination file path cannot be empty.".into(),
            detail: None,
        });
    }

    let dest = PathBuf::from(trimmed);
    if dest.is_dir() {
        return Err(LucidError::DatabaseError {
            code: "22023".into(),
            message: format!(
                "Export destination '{}' is a directory; choose a file path.",
                dest.display()
            ),
            detail: None,
        });
    }

    let parent = match dest.parent() {
        Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
        _ => PathBuf::from("."),
    };

    if !parent.exists() || !parent.is_dir() {
        return Err(LucidError::DatabaseError {
            code: "58030".into(),
            message: format!(
                "Destination folder '{}' does not exist or is not accessible.",
                parent.display()
            ),
            detail: None,
        });
    }

    let base_name = dest
        .file_name()
        .and_then(|n| n.to_str())
        .filter(|s| !s.is_empty())
        .unwrap_or("export.csv");

    let temp_name = format!(".{}.lucidsql-tmp-{}", base_name, uuid::Uuid::new_v4());
    let temp_path = parent.join(temp_name);

    Ok((dest, temp_path))
}

async fn create_temp_writer(
    temp_path: &Path,
) -> Result<BufWriter<tokio::fs::File>, LucidError> {
    let file = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(temp_path)
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58030".into(),
            message: format!("Failed to create temporary export file: {}", e),
            detail: None,
        })?;
    Ok(BufWriter::with_capacity(64 * 1024, file))
}

async fn finalize_temp_file(
    mut writer: BufWriter<tokio::fs::File>,
    temp_path: &Path,
    dest_path: &Path,
) -> Result<(), LucidError> {
    writer.flush().await.map_err(|e| LucidError::DatabaseError {
        code: "58030".into(),
        message: format!("Failed to flush CSV export to disk: {}", e),
        detail: None,
    })?;

    let file = writer.into_inner();
    file.sync_all().await.map_err(|e| LucidError::DatabaseError {
        code: "58030".into(),
        message: format!("Failed to sync CSV export file to disk: {}", e),
        detail: None,
    })?;
    drop(file);

    tokio::fs::rename(temp_path, dest_path)
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58030".into(),
            message: format!(
                "Failed to finalize export at '{}': {}",
                dest_path.display(),
                e
            ),
            detail: None,
        })?;

    Ok(())
}

pub fn sanitize_identifier(ident: &str) -> String {
    ident.replace('"', "\"\"")
}

/// Exports already-fetched SQL or table-page rows atomically to CSV via a temporary file.
/// Does not re-execute any SQL queries and refuses to write unsupported-type placeholders.
pub async fn export_fetched_rows_csv(
    columns: Vec<ColumnMetadata>,
    rows: Vec<RowData>,
    destination_path: String,
    exclude_leading_xmin: bool,
) -> Result<CsvExportResult, LucidError> {
    let start = Instant::now();

    if columns.is_empty() {
        return Err(LucidError::DatabaseError {
            code: "22023".into(),
            message: "No columns available to export.".into(),
            detail: None,
        });
    }

    let (dest_path, temp_path) = validate_and_prepare_paths(&destination_path)?;
    let mut writer = create_temp_writer(&temp_path).await?;
    let mut temp_guard = TempFileGuard {
        path: Some(temp_path.clone()),
    };

    let mut line_buf = String::with_capacity(256);
    let mut bytes_written: u64 = 0;

    format_csv_header(&columns, &mut line_buf);
    writer
        .write_all(line_buf.as_bytes())
        .await
        .map_err(|e| LucidError::DatabaseError {
            code: "58030".into(),
            message: format!("Failed writing CSV header: {}", e),
            detail: None,
        })?;
    bytes_written += line_buf.len() as u64;

    let slice_offset = if exclude_leading_xmin { 1 } else { 0 };
    for row in &rows {
        let slice = if row.cells.len() >= slice_offset {
            &row.cells[slice_offset..]
        } else {
            &[]
        };

        if let Err(err) = format_csv_row(&columns, slice, &mut line_buf) {
            drop(writer);
            temp_guard.cleanup_now().await;
            return Err(err);
        }

        if let Err(e) = writer.write_all(line_buf.as_bytes()).await {
            drop(writer);
            temp_guard.cleanup_now().await;
            return Err(LucidError::DatabaseError {
                code: "58030".into(),
                message: format!("Failed writing CSV row: {}", e),
                detail: None,
            });
        }
        bytes_written += line_buf.len() as u64;
    }

    if let Err(err) = finalize_temp_file(writer, &temp_path, &dest_path).await {
        temp_guard.cleanup_now().await;
        return Err(err);
    }

    temp_guard.disarm();

    Ok(CsvExportResult {
        destination_path: dest_path.to_string_lossy().into_owned(),
        rows_exported: rows.len() as u64,
        bytes_written,
        execution_duration_ms: start.elapsed().as_millis() as u64,
        snapshot_isolation: None,
    })
}

/// Streams a full table or view directly to a temporary CSV file on a separate transient
/// PostgreSQL connection inside `REPEATABLE READ READ ONLY`, never disturbing open SQL-tab
/// sessions or buffering full result sets in memory.
pub async fn export_table_csv(
    config: ConnectionConfig,
    request: TableCsvExportRequest,
    destination_path: String,
    export_id: String,
) -> Result<CsvExportResult, LucidError> {
    let start = Instant::now();
    let (dest_path, temp_path) = validate_and_prepare_paths(&destination_path)?;

    let run_state = Arc::new(ExportRunState::new());
    {
        let mut reg = EXPORT_REGISTRY.write().map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: format!("Export registry lock error: {}", e),
            detail: None,
        })?;
        if reg.len() > 256 {
            reg.retain(|_, v| !v.is_finished.load(Ordering::Acquire));
        }
        reg.insert(export_id.clone(), Arc::clone(&run_state));
    }

    let mut state_guard = ExportStateGuard {
        export_id: export_id.clone(),
        state: Arc::clone(&run_state),
        has_cancel_token: false,
    };

    if run_state.is_cancelled.load(Ordering::Acquire) {
        return Err(LucidError::QueryCancelled);
    }

    let cancel_tls = CancelTlsTarget::from_config(&config)?;

    // Separate transient connection pool (not shared with any SQL tab session).
    let pool = ManagedPool::new(&config)?;
    let client = tokio::select! {
        biased;
        _ = run_state.cancel_notify.notified() => return Err(LucidError::QueryCancelled),
        res = pool.get() => res?,
    };

    register_cancel_token_with_tls(&export_id, client.cancel_token(), cancel_tls);
    state_guard.has_cancel_token = true;

    if run_state.is_cancelled.load(Ordering::Acquire) {
        return Err(LucidError::QueryCancelled);
    }

    tokio::select! {
        biased;
        _ = run_state.cancel_notify.notified() => return Err(LucidError::QueryCancelled),
        res = client.batch_execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;") => {
            res.map_err(map_postgres_error)?;
        }
    }

    let columns = tokio::select! {
        biased;
        _ = run_state.cancel_notify.notified() => return Err(LucidError::QueryCancelled),
        res = query_columns(&client, &request.schema_name, &request.table_name) => res?,
    };

    if columns.is_empty() {
        rollback_with_timeout(&client).await;
        return Err(LucidError::DatabaseError {
            code: "42P01".into(),
            message: format!(
                "Table '{}.{}' was not found or has no exportable columns.",
                request.schema_name, request.table_name
            ),
            detail: None,
        });
    }

    let order_clause = if let Some(ref sort_col) = request.sort_col {
        if !columns.iter().any(|c| &c.name == sort_col) {
            rollback_with_timeout(&client).await;
            return Err(LucidError::DatabaseError {
                code: "42703".into(),
                message: format!(
                    "Sort column '{}' does not exist on '{}.{}'.",
                    sort_col, request.schema_name, request.table_name
                ),
                detail: None,
            });
        }
        let clean_sort = sanitize_identifier(sort_col);
        let dir = if request.sort_desc { "DESC" } else { "ASC" };
        format!(r#" ORDER BY "{}" {}"#, clean_sort, dir)
    } else {
        String::new()
    };

    let projections: Vec<String> = columns
        .iter()
        .map(|col| {
            let clean_col = sanitize_identifier(&col.name);
            if is_csv_natively_mapped_pg_type(&col.pg_type_name) {
                format!(r#""{}""#, clean_col)
            } else {
                format!(r#""{}"::text AS "{}""#, clean_col, clean_col)
            }
        })
        .collect();

    let clean_schema = sanitize_identifier(&request.schema_name);
    let clean_table = sanitize_identifier(&request.table_name);
    let sql = format!(
        r#"SELECT {} FROM "{}"."{}"{}"#,
        projections.join(", "),
        clean_schema,
        clean_table,
        order_clause
    );

    let stmt = tokio::select! {
        biased;
        _ = run_state.cancel_notify.notified() => {
            rollback_with_timeout(&client).await;
            return Err(LucidError::QueryCancelled);
        }
        res = client.prepare(&sql) => {
            match res {
                Ok(s) => s,
                Err(e) => {
                    rollback_with_timeout(&client).await;
                    return Err(map_postgres_error(e));
                }
            }
        }
    };

    let stream = tokio::select! {
        biased;
        _ = run_state.cancel_notify.notified() => {
            rollback_with_timeout(&client).await;
            return Err(LucidError::QueryCancelled);
        }
        res = client.query_raw(&stmt, std::iter::empty::<i32>()) => {
            match res {
                Ok(s) => s,
                Err(e) => {
                    rollback_with_timeout(&client).await;
                    return Err(map_postgres_error(e));
                }
            }
        }
    };

    let mut writer = match create_temp_writer(&temp_path).await {
        Ok(w) => w,
        Err(e) => {
            drop(stream);
            rollback_with_timeout(&client).await;
            return Err(e);
        }
    };
    let mut temp_guard = TempFileGuard {
        path: Some(temp_path.clone()),
    };

    let mut line_buf = String::with_capacity(512);
    let mut row_cells: Vec<CellValue> = Vec::with_capacity(columns.len());
    let mut rows_exported: u64 = 0;
    let mut bytes_written: u64 = 0;

    format_csv_header(&columns, &mut line_buf);
    if let Err(e) = writer.write_all(line_buf.as_bytes()).await {
        drop(writer);
        drop(stream);
        temp_guard.cleanup_now().await;
        rollback_with_timeout(&client).await;
        return Err(LucidError::DatabaseError {
            code: "58030".into(),
            message: format!("Failed writing CSV header: {}", e),
            detail: None,
        });
    }
    bytes_written += line_buf.len() as u64;
    run_state
        .bytes_written
        .store(bytes_written, Ordering::Release);

    pin_mut!(stream);

    loop {
        if run_state.is_cancelled.load(Ordering::Acquire) {
            drop(writer);
            drop(stream);
            temp_guard.cleanup_now().await;
            rollback_with_timeout(&client).await;
            return Err(LucidError::QueryCancelled);
        }

        let next_row = tokio::select! {
            biased;
            _ = run_state.cancel_notify.notified() => {
                drop(writer);
                drop(stream);
                temp_guard.cleanup_now().await;
                rollback_with_timeout(&client).await;
                return Err(LucidError::QueryCancelled);
            }
            item = stream.next() => item,
        };

        let Some(row_res) = next_row else {
            break;
        };

        let row = match row_res {
            Ok(r) => r,
            Err(e) => {
                drop(writer);
                drop(stream);
                temp_guard.cleanup_now().await;
                rollback_with_timeout(&client).await;
                return Err(map_postgres_error(e));
            }
        };

        row_cells.clear();
        for idx in 0..columns.len() {
            row_cells.push(map_cell_value(&row, idx));
        }

        if let Err(err) = format_csv_row(&columns, &row_cells, &mut line_buf) {
            drop(writer);
            drop(stream);
            temp_guard.cleanup_now().await;
            rollback_with_timeout(&client).await;
            return Err(err);
        }

        if let Err(e) = writer.write_all(line_buf.as_bytes()).await {
            drop(writer);
            drop(stream);
            temp_guard.cleanup_now().await;
            rollback_with_timeout(&client).await;
            return Err(LucidError::DatabaseError {
                code: "58030".into(),
                message: format!("Failed writing CSV row: {}", e),
                detail: None,
            });
        }

        rows_exported += 1;
        bytes_written += line_buf.len() as u64;
        run_state
            .rows_exported
            .store(rows_exported, Ordering::Release);
        run_state
            .bytes_written
            .store(bytes_written, Ordering::Release);
    }

    drop(stream);

    if run_state.is_cancelled.load(Ordering::Acquire) {
        drop(writer);
        temp_guard.cleanup_now().await;
        rollback_with_timeout(&client).await;
        return Err(LucidError::QueryCancelled);
    }

    if let Err(err) = finalize_temp_file(writer, &temp_path, &dest_path).await {
        temp_guard.cleanup_now().await;
        rollback_with_timeout(&client).await;
        return Err(err);
    }

    temp_guard.disarm();
    rollback_with_timeout(&client).await;

    Ok(CsvExportResult {
        destination_path: dest_path.to_string_lossy().into_owned(),
        rows_exported,
        bytes_written,
        execution_duration_ms: start.elapsed().as_millis() as u64,
        snapshot_isolation: Some("REPEATABLE READ READ ONLY".to_string()),
    })
}

async fn rollback_with_timeout(client: &deadpool_postgres::Client) {
    let _ = tokio::time::timeout(Duration::from_millis(1500), client.batch_execute("ROLLBACK;")).await;
}

pub fn get_export_progress(export_id: String) -> Option<ExportProgress> {
    let reg = EXPORT_REGISTRY.read().ok()?;
    reg.get(&export_id).map(|s| s.snapshot(&export_id))
}

pub async fn cancel_export(export_id: String) -> Result<bool, LucidError> {
    let state_opt = {
        let reg = EXPORT_REGISTRY.read().map_err(|e| LucidError::DatabaseError {
            code: "58000".into(),
            message: format!("Export registry lock error: {}", e),
            detail: None,
        })?;
        reg.get(&export_id).cloned()
    };

    if let Some(ref state) = state_opt {
        state.is_cancelled.store(true, Ordering::Release);
        state.cancel_notify.notify_waiters();
    }

    let cancelled_pg = cancel_active_query(&export_id).await.unwrap_or(false);
    Ok(state_opt.is_some() || cancelled_pg)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::{
        close_session, execute_session_script, get_session_info, TransactionStatus,
    };

    fn get_test_config() -> ConnectionConfig {
        let user = std::env::var("USER").unwrap_or_else(|_| "postgres".into());
        ConnectionConfig {
            host: "localhost".into(),
            port: 5432,
            database: "postgres".into(),
            user,
            password: None,
            ssl_mode: "disable".into(),
            ssl_root_cert: None,
            timeout_seconds: 5,
        }
    }

    fn make_col(name: &str, pg_type_name: &str, pos: u32) -> ColumnMetadata {
        ColumnMetadata {
            name: name.to_string(),
            ordinal_position: pos,
            pg_type_name: pg_type_name.to_string(),
            pg_type_oid: 25,
            is_primary_key: pos == 1,
            is_nullable: true,
            default_value: None,
            is_generated: false,
            is_identity: false,
            is_identity_always: false,
        }
    }

    fn unique_temp_dir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "lucidsql_csv_test_{}_{}",
            label,
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn test_rfc4180_escaping_null_vs_empty_unicode_and_decimals() {
        let cols = vec![
            make_col("id", "int4", 1),
            make_col("note", "text", 2),
            make_col("empty_or_null", "text", 3),
            make_col("amount", "numeric", 4),
            make_col("flag", "bool", 5),
        ];

        let mut header = String::new();
        format_csv_header(&cols, &mut header);
        assert_eq!(header, "id,note,empty_or_null,amount,flag\n");

        // Row 1: commas, double quotes, embedded newline, Unicode emoji & CJK, SQL NULL vs ""
        let row1 = vec![
            CellValue::Integer(1),
            CellValue::Text("hello, \"world\"\nline2 — café 🚀 日本語".into()),
            CellValue::Null,
            CellValue::Decimal("-12345678901234567890.1234567890".into()),
            CellValue::Boolean(true),
        ];
        let mut out1 = String::new();
        format_csv_row(&cols, &row1, &mut out1).unwrap();
        assert_eq!(
            out1,
            "1,\"hello, \"\"world\"\"\nline2 — café 🚀 日本語\",,-12345678901234567890.1234567890,true\n"
        );

        // Row 2: explicit empty string ("") vs literal "NULL" text
        let row2 = vec![
            CellValue::Integer(2),
            CellValue::Text("NULL".into()),
            CellValue::Text(String::new()),
            CellValue::Decimal("0.0040".into()),
            CellValue::Boolean(false),
        ];
        let mut out2 = String::new();
        format_csv_row(&cols, &row2, &mut out2).unwrap();
        assert_eq!(out2, "2,NULL,\"\",0.0040,false\n");
    }

    #[tokio::test]
    async fn test_fetched_export_rejects_unsupported_and_preserves_existing_file() {
        let dir = unique_temp_dir("unsupported");
        let dest = dir.join("existing.csv");
        std::fs::write(&dest, "keep-existing-data\n").unwrap();

        let cols = vec![
            make_col("id", "int4", 1),
            make_col("vec", "int2vector", 2),
        ];
        let rows = vec![RowData {
            cells: vec![
                CellValue::Integer(1),
                CellValue::Unsupported("int2vector".into()),
            ],
        }];

        let err = export_fetched_rows_csv(cols, rows, dest.to_string_lossy().into_owned(), false)
            .await
            .unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("int2vector"));
        assert!(msg.contains("vec"));

        // Existing destination file untouched and no temp file leaked
        assert_eq!(std::fs::read_to_string(&dest).unwrap(), "keep-existing-data\n");
        let entries: Vec<_> = std::fs::read_dir(&dir).unwrap().collect();
        assert_eq!(entries.len(), 1);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn test_streaming_export_snapshot_isolation_types_and_sql_session_isolation() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let setup_client = pool.get().await.unwrap();

        let schema = format!(
            "lucidsql_csv_stream_{}",
            uuid::Uuid::new_v4().simple()
        );
        setup_client
            .batch_execute(&format!(
                r#"
                CREATE SCHEMA "{schema}";
                CREATE TABLE "{schema}".events (
                    id INT PRIMARY KEY,
                    title TEXT,
                    empty_col TEXT,
                    amount NUMERIC(30, 10),
                    dur INTERVAL,
                    vec INT2VECTOR
                );
                INSERT INTO "{schema}".events
                SELECT
                    g,
                    CASE
                        WHEN g = 1 THEN E'Alpha, "quoted"\nline2 — 🚀 café'
                        WHEN g = 2 THEN 'NULL'
                        ELSE 'Item ' || g
                    END,
                    CASE
                        WHEN g = 1 THEN ''
                        WHEN g = 2 THEN NULL
                        ELSE 'v' || g
                    END,
                    (g::numeric * 1000000000000.0000000001::numeric) * CASE WHEN g = 3 THEN -1 ELSE 1 END,
                    (g || ' minutes')::interval,
                    ('1 ' || g)::int2vector
                FROM generate_series(1, 135) AS g;
                "#,
                schema = schema
            ))
            .await
            .unwrap();

        // Keep an open SQL-tab transaction running concurrently on a dedicated session
        let session_id = format!("csv_iso_tab_{}", uuid::Uuid::new_v4());
        let tx_res = execute_session_script(
            &config,
            &session_id,
            &format!(
                "BEGIN; INSERT INTO \"{schema}\".events VALUES (9999, 'Uncommitted', '', 1.23, '1 hour', '9 9');",
                schema = schema
            ),
            &uuid::Uuid::new_v4().to_string(),
            Some(100),
            false,
        )
        .await
        .unwrap();
        assert_eq!(tx_res.transaction_status, TransactionStatus::InTransaction);

        let dir = unique_temp_dir("stream_ok");
        let dest = dir.join("events.csv");
        let export_id = format!("exp_{}", uuid::Uuid::new_v4());

        let export_res = export_table_csv(
            config.clone(),
            TableCsvExportRequest {
                schema_name: schema.clone(),
                table_name: "events".into(),
                sort_col: Some("id".into()),
                sort_desc: false,
            },
            dest.to_string_lossy().into_owned(),
            export_id.clone(),
        )
        .await
        .unwrap();

        assert_eq!(export_res.rows_exported, 135);
        assert_eq!(
            export_res.snapshot_isolation.as_deref(),
            Some("REPEATABLE READ READ ONLY")
        );

        let contents = std::fs::read_to_string(&dest).unwrap();
        assert!(contents.starts_with("id,title,empty_col,amount,dur,vec\n"));
        assert!(contents.contains(
            "1,\"Alpha, \"\"quoted\"\"\nline2 — café\",\"\",1000000000000.0000000001,00:01:00,1 1\n"
        ) || contents.contains(
            "1,\"Alpha, \"\"quoted\"\"\nline2 — 🚀 café\",\"\",1000000000000.0000000001,00:01:00,1 1\n"
        ));
        assert!(contents.contains("2,NULL,,2000000000000.0000000002,00:02:00,1 2\n"));
        assert!(contents.contains("-3000000000000.0000000003"));
        assert!(!contents.contains("Uncommitted"));
        assert!(!contents.contains("Unsupported"));

        // Verify SQL-tab session transaction remained intact and open
        let info = get_session_info(&session_id).await.unwrap();
        assert_eq!(info.transaction_status, TransactionStatus::InTransaction);

        // No temp files left behind in directory
        let entries: Vec<_> = std::fs::read_dir(&dir).unwrap().collect();
        assert_eq!(entries.len(), 1);

        let _ = execute_session_script(
            &config,
            &session_id,
            "ROLLBACK;",
            &uuid::Uuid::new_v4().to_string(),
            Some(100),
            false,
        )
        .await;
        let _ = close_session(&session_id).await;
        let _ = setup_client
            .batch_execute(&format!(r#"DROP SCHEMA IF EXISTS "{}" CASCADE;"#, schema))
            .await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn test_streaming_export_cancellation_cleans_temp_and_preserves_existing_file() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let setup_client = pool.get().await.unwrap();

        let schema = format!(
            "lucidsql_csv_cancel_{}",
            uuid::Uuid::new_v4().simple()
        );
        setup_client
            .batch_execute(&format!(
                r#"
                CREATE SCHEMA "{schema}";
                CREATE VIEW "{schema}".slow_rows AS
                SELECT g AS id,
                       CASE WHEN g = 200 THEN pg_sleep(5)::text ELSE 'row-' || g END AS body
                FROM generate_series(1, 500) AS g;
                "#,
                schema = schema
            ))
            .await
            .unwrap();

        let dir = unique_temp_dir("stream_cancel");
        let dest = dir.join("target.csv");
        std::fs::write(&dest, "original-destination-intact\n").unwrap();

        let export_id = format!("exp_cancel_{}", uuid::Uuid::new_v4());
        let export_id_clone = export_id.clone();
        let cfg_clone = config.clone();
        let schema_clone = schema.clone();
        let dest_str = dest.to_string_lossy().into_owned();

        let handle = tokio::spawn(async move {
            export_table_csv(
                cfg_clone,
                TableCsvExportRequest {
                    schema_name: schema_clone,
                    table_name: "slow_rows".into(),
                    sort_col: None,
                    sort_desc: false,
                },
                dest_str,
                export_id_clone,
            )
            .await
        });

        // Wait until first batch of rows has been streamed before pg_sleep(5) at row 200
        for _ in 0..40 {
            if let Some(p) = get_export_progress(export_id.clone()) {
                if p.rows_exported > 0 {
                    break;
                }
            }
            tokio::time::sleep(tokio::time::Duration::from_millis(25)).await;
        }

        let cancelled = cancel_export(export_id.clone()).await.unwrap();
        assert!(cancelled);

        let err = handle.await.unwrap().unwrap_err();
        assert_eq!(err, LucidError::QueryCancelled);

        let final_prog = get_export_progress(export_id).unwrap();
        assert!(final_prog.is_cancelled);
        assert!(final_prog.is_finished);

        // Pre-existing destination untouched, zero .tmp leftovers
        assert_eq!(
            std::fs::read_to_string(&dest).unwrap(),
            "original-destination-intact\n"
        );
        let entries: Vec<_> = std::fs::read_dir(&dir).unwrap().collect();
        assert_eq!(entries.len(), 1);

        let _ = setup_client
            .batch_execute(&format!(r#"DROP SCHEMA IF EXISTS "{}" CASCADE;"#, schema))
            .await;
        let _ = std::fs::remove_dir_all(&dir);
    }
}
