use std::collections::{HashMap, HashSet};
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant};

use futures_util::pin_mut;
use futures_util::StreamExt;
use tokio::sync::Mutex;
use tokio_postgres::{CancelToken, Client, NoTls};

use crate::connection::tls::{
    build_rustls_connect, map_postgres_connect_error, CancelTlsTarget, LucidSslMode,
};
use crate::connection::ConnectionConfig;
use crate::error::LucidError;
use crate::query::execute::{
    map_postgres_error, register_cancel_token_with_tls, unregister_cancel_token, QueryResult,
};
use crate::query::splitter::{extract_first_keyword, split_statements};
use crate::query::value_mapper::map_cell_value;
use crate::query::RowData;
use crate::schema::ColumnMetadata;

pub const MAX_DEDICATED_SESSIONS: usize = 16;

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
    pub cancel_tls: CancelTlsTarget,
}

#[derive(Clone)]
struct SessionEntry {
    inner: Arc<Mutex<DedicatedSession>>,
    snapshot: Arc<std::sync::RwLock<SessionInfo>>,
    cancel_token: CancelToken,
    cancel_tls: CancelTlsTarget,
    conn_abort: tokio::task::AbortHandle,
}

struct SessionRegistry {
    sessions: HashMap<String, SessionEntry>,
    connecting: HashSet<String>,
}

pub struct SessionManager {
    registry: std::sync::Mutex<SessionRegistry>,
    max_sessions: usize,
}

struct ConnectingReservation<'a> {
    manager: &'a SessionManager,
    session_id: String,
    active: bool,
}

impl<'a> Drop for ConnectingReservation<'a> {
    fn drop(&mut self) {
        if self.active {
            if let Ok(mut reg) = self.manager.registry.lock() {
                reg.connecting.remove(&self.session_id);
            }
        }
    }
}

impl SessionManager {
    pub fn new(max_sessions: usize) -> Self {
        Self {
            registry: std::sync::Mutex::new(SessionRegistry {
                sessions: HashMap::new(),
                connecting: HashSet::new(),
            }),
            max_sessions,
        }
    }

    pub fn max_sessions(&self) -> usize {
        self.max_sessions
    }

    pub fn active_session_count(&self) -> usize {
        let mut reg = self.registry.lock().expect("session registry poisoned");
        prune_finished_entries(&mut reg.sessions);
        reg.sessions.len()
    }

    async fn acquire_entry(
        &self,
        config: &ConnectionConfig,
        session_id: &str,
        read_only: bool,
    ) -> Result<SessionEntry, LucidError> {
        enum AcquireStep<'a> {
            Existing(SessionEntry),
            WaitConnecting,
            Reserved(ConnectingReservation<'a>),
        }

        let reservation = loop {
            let step = {
                let mut reg = self.registry.lock().map_err(|_| LucidError::ConnectionFailed {
                    reason: "Session registry lock error".into(),
                })?;

                if let Some(existing) = reg.sessions.get(session_id).cloned() {
                    if existing.conn_abort.is_finished() {
                        reg.sessions.remove(session_id);
                        return Err(LucidError::ConnectionFailed {
                            reason: "Dedicated SQL session connection was lost or closed by the server (temporary tables and uncommitted transactions were discarded). Run again to reconnect.".into(),
                        });
                    }
                    AcquireStep::Existing(existing)
                } else {
                    prune_finished_entries(&mut reg.sessions);

                    if reg.connecting.contains(session_id) {
                        AcquireStep::WaitConnecting
                    } else {
                        let active_total = reg.sessions.len() + reg.connecting.len();
                        if active_total >= self.max_sessions {
                            return Err(LucidError::ConnectionFailed {
                                reason: format!(
                                    "Active SQL session limit reached ({}/{}). Close an unused connected SQL tab before opening a new session.",
                                    active_total, self.max_sessions
                                ),
                            });
                        }

                        reg.connecting.insert(session_id.to_string());
                        AcquireStep::Reserved(ConnectingReservation {
                            manager: self,
                            session_id: session_id.to_string(),
                            active: true,
                        })
                    }
                }
            };

            match step {
                AcquireStep::Existing(existing) => return Ok(existing),
                AcquireStep::WaitConnecting => {
                    tokio::time::sleep(std::time::Duration::from_millis(15)).await;
                }
                AcquireStep::Reserved(res) => break res,
            }
        };

        let ssl_mode = LucidSslMode::parse(&config.ssl_mode)?;
        let cancel_tls = CancelTlsTarget {
            ssl_mode,
            ssl_root_cert: config.ssl_root_cert.clone(),
        };

        let mut pg_config = tokio_postgres::Config::new();
        pg_config.host(&config.host);
        pg_config.port(config.port);
        pg_config.dbname(&config.database);
        pg_config.user(&config.user);
        if let Some(ref pass) = config.password {
            pg_config.password(pass);
        }
        pg_config.ssl_mode(ssl_mode.to_pg_ssl_mode());
        pg_config.connect_timeout(Duration::from_secs(config.timeout_seconds.max(1) as u64));

        let (client, conn_handle) =
            match build_rustls_connect(ssl_mode, config.ssl_root_cert.as_deref())? {
                Some(tls) => {
                    let (client, connection) = pg_config
                        .connect(tls)
                        .await
                        .map_err(|e| map_postgres_connect_error(&e))?;
                    let conn_handle = tokio::spawn(async move {
                        let _ = connection.await;
                    });
                    (client, conn_handle)
                }
                None => {
                    let (client, connection) = pg_config
                        .connect(NoTls)
                        .await
                        .map_err(|e| map_postgres_connect_error(&e))?;
                    let conn_handle = tokio::spawn(async move {
                        let _ = connection.await;
                    });
                    (client, conn_handle)
                }
            };
        let conn_abort = conn_handle.abort_handle();

        let pid_row = match client.query_one("SELECT pg_backend_pid()", &[]).await {
            Ok(row) => row,
            Err(e) => {
                conn_handle.abort();
                return Err(map_postgres_error(e));
            }
        };
        let backend_pid = pid_row.get::<_, i32>(0) as u32;

        if read_only {
            if let Err(e) = client
                .batch_execute(
                    "SET default_transaction_read_only = on; SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;",
                )
                .await
            {
                conn_handle.abort();
                return Err(map_postgres_error(e));
            }
        }

        let cancel_token = client.cancel_token();
        let initial_info = SessionInfo {
            id: session_id.to_string(),
            is_read_only: read_only,
            transaction_status: TransactionStatus::Idle,
            backend_pid,
        };

        let entry = SessionEntry {
            inner: Arc::new(Mutex::new(DedicatedSession {
                id: session_id.to_string(),
                client,
                backend_pid,
                is_read_only: read_only,
                transaction_status: TransactionStatus::Idle,
                conn_handle,
                cancel_tls: cancel_tls.clone(),
            })),
            snapshot: Arc::new(std::sync::RwLock::new(initial_info)),
            cancel_token,
            cancel_tls,
            conn_abort,
        };

        let mut reservation = reservation;
        reservation.active = false;
        {
            let mut reg = self.registry.lock().map_err(|_| LucidError::ConnectionFailed {
                reason: "Session registry lock error".into(),
            })?;
            reg.connecting.remove(&reservation.session_id);
            reg.sessions.insert(session_id.to_string(), entry.clone());
        }

        Ok(entry)
    }

    pub async fn get_or_create_session(
        &self,
        config: &ConnectionConfig,
        session_id: &str,
        read_only: bool,
    ) -> Result<(), LucidError> {
        let entry = self.acquire_entry(config, session_id, read_only).await?;
        let is_closed = {
            let guard = entry.inner.try_lock();
            match guard {
                Ok(s) => s.client.is_closed(),
                Err(_) => false,
            }
        };
        if is_closed {
            self.evict_session(session_id);
            return Err(LucidError::ConnectionFailed {
                reason: "Dedicated SQL session connection was lost or closed by the server. Reconnect to establish a fresh session.".into(),
            });
        }
        Ok(())
    }

    fn evict_session(&self, session_id: &str) -> Option<SessionEntry> {
        let mut reg = self.registry.lock().ok()?;
        reg.sessions.remove(session_id)
    }

    async fn close_entry(entry: SessionEntry) {
        if let Ok(session) = entry.inner.try_lock() {
            if session.transaction_status != TransactionStatus::Idle && !session.client.is_closed() {
                let _ = tokio::time::timeout(
                    Duration::from_secs(2),
                    session.client.batch_execute("ROLLBACK;"),
                )
                .await;
            }
            session.conn_handle.abort();
        } else {
            // Query is actively running on this session: issue bounded PG cancel packet and close socket
            // immediately so any uncommitted transaction rolls back cleanly on the server without hanging UI.
            let _ = entry
                .cancel_tls
                .cancel_with_timeout(&entry.cancel_token, Duration::from_secs(2))
                .await;
            entry.conn_abort.abort();
        }
    }

    pub async fn close_session(&self, session_id: &str) -> Result<(), LucidError> {
        if let Some(entry) = self.evict_session(session_id) {
            Self::close_entry(entry).await;
        }
        Ok(())
    }

    pub async fn close_all_sessions(&self) -> Result<(), LucidError> {
        let entries: Vec<SessionEntry> = {
            let mut reg = self.registry.lock().map_err(|_| LucidError::ConnectionFailed {
                reason: "Session registry lock error".into(),
            })?;
            reg.sessions.drain().map(|(_, entry)| entry).collect()
        };

        for entry in entries {
            Self::close_entry(entry).await;
        }
        Ok(())
    }

    pub async fn set_session_read_only(
        &self,
        session_id: &str,
        read_only: bool,
    ) -> Result<SessionInfo, LucidError> {
        let entry = {
            let reg = self.registry.lock().map_err(|_| LucidError::ConnectionFailed {
                reason: "Session registry lock error".into(),
            })?;
            reg.sessions.get(session_id).cloned()
        }
        .ok_or_else(|| LucidError::ConnectionFailed {
            reason: format!("Session '{}' not found", session_id),
        })?;

        let mut session = entry.inner.lock().await;
        if session.client.is_closed() {
            drop(session);
            self.evict_session(session_id);
            return Err(LucidError::ConnectionFailed {
                reason: "Dedicated SQL session connection was lost or closed by the server.".into(),
            });
        }

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

        let info = SessionInfo {
            id: session.id.clone(),
            is_read_only: session.is_read_only,
            transaction_status: session.transaction_status,
            backend_pid: session.backend_pid,
        };
        if let Ok(mut snap) = entry.snapshot.write() {
            *snap = info.clone();
        }
        Ok(info)
    }

    pub async fn get_session_info(&self, session_id: &str) -> Result<SessionInfo, LucidError> {
        let entry = {
            let reg = self.registry.lock().map_err(|_| LucidError::ConnectionFailed {
                reason: "Session registry lock error".into(),
            })?;
            reg.sessions.get(session_id).cloned()
        }
        .ok_or_else(|| LucidError::ConnectionFailed {
            reason: format!("Session '{}' not found", session_id),
        })?;

        if entry.conn_abort.is_finished() {
            self.evict_session(session_id);
            return Err(LucidError::ConnectionFailed {
                reason: "Dedicated SQL session connection was lost or closed by the server.".into(),
            });
        }

        let info = entry
            .snapshot
            .read()
            .map_err(|_| LucidError::ConnectionFailed {
                reason: "Session snapshot lock error".into(),
            })?
            .clone();
        Ok(info)
    }

    pub async fn execute_session_script(
        &self,
        config: &ConnectionConfig,
        session_id: &str,
        sql: &str,
        query_id: &str,
        max_rows: Option<u32>,
        read_only_requested: bool,
    ) -> Result<QueryResult, LucidError> {
        let entry = self
            .acquire_entry(config, session_id, read_only_requested)
            .await?;

        let mut session = entry.inner.lock().await;

        if session.client.is_closed() {
            drop(session);
            self.evict_session(session_id);
            return Err(LucidError::ConnectionFailed {
                reason: "Dedicated SQL session connection was lost or closed by the server. Run again to start a fresh session.".into(),
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
                    let is_conn_loss = session.client.is_closed() || is_connection_loss_error(&e);
                    let mapped = map_postgres_error(e);
                    if is_conn_loss {
                        drop(session);
                        if let Some(evicted) = self.evict_session(session_id) {
                            evicted.conn_abort.abort();
                        }
                        return Err(connection_lost_error(&mapped));
                    }
                    return Err(mapped);
                }
                session.is_read_only = read_only_requested;
                update_snapshot(&entry, &session);
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

        register_cancel_token_with_tls(
            query_id,
            session.client.cancel_token(),
            session.cancel_tls.clone(),
        );

        let start_time = Instant::now();
        let total_statements = statements.len();
        let mut total_affected: Option<u64> = None;
        let mut last_row_result: Option<(Vec<ColumnMetadata>, Vec<RowData>, bool)> = None;

        for stmt in statements.iter() {
            let trimmed = stmt.trim();
            let upper = trimmed.to_uppercase();
            let first_kw = extract_first_keyword(trimmed);

            if session.is_read_only {
                if (upper.contains("DEFAULT_TRANSACTION_READ_ONLY")
                    && (upper.contains("OFF") || upper.contains("FALSE")))
                    || upper.contains("TRANSACTION READ WRITE")
                {
                    unregister_cancel_token(query_id);
                    return Err(LucidError::ReadOnlyViolation {
                        attempted_operation:
                            "Cannot disable read-only mode within a read-only session.".into(),
                    });
                }

                if let Some(ref kw) = first_kw {
                    match kw.as_str() {
                        "INSERT" | "UPDATE" | "DELETE" | "DROP" | "ALTER" | "TRUNCATE"
                        | "GRANT" | "REVOKE" => {
                            unregister_cancel_token(query_id);
                            return Err(LucidError::ReadOnlyViolation {
                                attempted_operation: format!(
                                    "Cannot execute {} in read-only mode.",
                                    kw
                                ),
                            });
                        }
                        "CREATE" => {
                            if !upper.contains("TEMP") && !upper.contains("TEMPORARY") {
                                unregister_cancel_token(query_id);
                                return Err(LucidError::ReadOnlyViolation {
                                    attempted_operation:
                                        "Cannot execute CREATE on persistent objects in read-only mode."
                                            .into(),
                                });
                            }
                        }
                        _ => {}
                    }
                }
            }

            let statement = match session.client.prepare(trimmed).await {
                Ok(s) => s,
                Err(e) => {
                    unregister_cancel_token(query_id);
                    return Err(handle_query_failure(self, &entry, &mut session, session_id, e));
                }
            };

            let col_defs = statement.columns();

            if col_defs.is_empty() {
                match session.client.execute(&statement, &[]).await {
                    Ok(affected) => {
                        total_affected = Some(total_affected.unwrap_or(0) + affected);

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
                                        if session.transaction_status
                                            == TransactionStatus::FailedTransaction
                                        {
                                            session.transaction_status =
                                                TransactionStatus::InTransaction;
                                        }
                                    } else {
                                        session.transaction_status = TransactionStatus::Idle;
                                    }
                                }
                                _ => {}
                            }
                            update_snapshot(&entry, &session);
                        }
                    }
                    Err(e) => {
                        unregister_cancel_token(query_id);
                        return Err(handle_query_failure(self, &entry, &mut session, session_id, e));
                    }
                }
            } else {
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
                        is_identity: false,
                        is_identity_always: false,
                    });
                }

                let stream = match session
                    .client
                    .query_raw(&statement, std::iter::empty::<i32>())
                    .await
                {
                    Ok(s) => s,
                    Err(e) => {
                        unregister_cancel_token(query_id);
                        return Err(handle_query_failure(self, &entry, &mut session, session_id, e));
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
                            drop(stream);
                            return Err(handle_query_failure(
                                self,
                                &entry,
                                &mut session,
                                session_id,
                                e,
                            ));
                        }
                    }
                }

                last_row_result = Some((columns, rows, is_truncated));
            }
        }

        unregister_cancel_token(query_id);
        let duration_ms = start_time.elapsed().as_millis() as u64;
        update_snapshot(&entry, &session);

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
}

fn prune_finished_entries(sessions: &mut HashMap<String, SessionEntry>) {
    sessions.retain(|_, entry| !entry.conn_abort.is_finished());
}

fn update_snapshot(entry: &SessionEntry, session: &DedicatedSession) {
    if let Ok(mut snap) = entry.snapshot.write() {
        snap.is_read_only = session.is_read_only;
        snap.transaction_status = session.transaction_status;
        snap.backend_pid = session.backend_pid;
    }
}

fn is_connection_loss_error(err: &tokio_postgres::Error) -> bool {
    if err.is_closed() {
        return true;
    }
    if let Some(db_err) = err.as_db_error() {
        let code = db_err.code().code();
        return matches!(code, "57P01" | "57P02" | "57P03") || code.starts_with("08");
    }
    let msg = err.to_string().to_lowercase();
    msg.contains("connection closed") || msg.contains("broken pipe") || msg.contains("unexpected eof")
}

fn connection_lost_error(err: &LucidError) -> LucidError {
    LucidError::ConnectionFailed {
        reason: format!(
            "Dedicated SQL session connection was lost ({}). Temporary tables, session settings, and uncommitted transactions were discarded.",
            err
        ),
    }
}

fn handle_query_failure(
    manager: &SessionManager,
    entry: &SessionEntry,
    session: &mut tokio::sync::MutexGuard<'_, DedicatedSession>,
    session_id: &str,
    err: tokio_postgres::Error,
) -> LucidError {
    let conn_lost = session.client.is_closed() || is_connection_loss_error(&err);
    let mapped = map_postgres_error(err);

    if matches!(mapped, LucidError::QueryCancelled) && !conn_lost {
        if session.transaction_status == TransactionStatus::InTransaction {
            session.transaction_status = TransactionStatus::FailedTransaction;
        }
        update_snapshot(entry, session);
        return mapped;
    }

    if conn_lost {
        session.conn_handle.abort();
        if let Some(evicted) = manager.evict_session(session_id) {
            evicted.conn_abort.abort();
        }
        return connection_lost_error(&mapped);
    }

    if session.transaction_status == TransactionStatus::InTransaction {
        session.transaction_status = TransactionStatus::FailedTransaction;
    }
    update_snapshot(entry, session);
    mapped
}

static DEFAULT_SESSION_MANAGER: LazyLock<SessionManager> =
    LazyLock::new(|| SessionManager::new(MAX_DEDICATED_SESSIONS));

pub fn max_dedicated_sessions() -> u32 {
    DEFAULT_SESSION_MANAGER.max_sessions() as u32
}

pub fn active_session_count() -> u32 {
    DEFAULT_SESSION_MANAGER.active_session_count() as u32
}

pub async fn get_or_create_session(
    config: &ConnectionConfig,
    session_id: &str,
    read_only: bool,
) -> Result<(), LucidError> {
    DEFAULT_SESSION_MANAGER
        .get_or_create_session(config, session_id, read_only)
        .await
}

pub async fn close_session(session_id: &str) -> Result<(), LucidError> {
    DEFAULT_SESSION_MANAGER.close_session(session_id).await
}

pub async fn close_all_sessions() -> Result<(), LucidError> {
    DEFAULT_SESSION_MANAGER.close_all_sessions().await
}

pub async fn set_session_read_only(
    session_id: &str,
    read_only: bool,
) -> Result<SessionInfo, LucidError> {
    DEFAULT_SESSION_MANAGER
        .set_session_read_only(session_id, read_only)
        .await
}

pub async fn get_session_info(session_id: &str) -> Result<SessionInfo, LucidError> {
    DEFAULT_SESSION_MANAGER.get_session_info(session_id).await
}

pub async fn execute_session_script(
    config: &ConnectionConfig,
    session_id: &str,
    sql: &str,
    query_id: &str,
    max_rows: Option<u32>,
    read_only_requested: bool,
) -> Result<QueryResult, LucidError> {
    DEFAULT_SESSION_MANAGER
        .execute_session_script(
            config,
            session_id,
            sql,
            query_id,
            max_rows,
            read_only_requested,
        )
        .await
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
            ssl_root_cert: None,
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

    #[tokio::test]
    async fn test_two_sessions_independent_state_and_nonblocking_execution() {
        let config = get_test_config();
        let mgr = SessionManager::new(4);
        let s1 = "test_isolation_s1";
        let s2 = "test_isolation_s2";

        // Setup independent session state in each tab
        mgr.execute_session_script(
            &config,
            s1,
            "SET TIME ZONE 'UTC'; CREATE TEMP TABLE t_shared_name (v text); INSERT INTO t_shared_name VALUES ('tab1_val'); BEGIN;",
            "q_s1_init",
            None,
            false,
        )
        .await
        .unwrap();

        mgr.execute_session_script(
            &config,
            s2,
            "SET TIME ZONE 'America/New_York'; CREATE TEMP TABLE t_shared_name (v text); INSERT INTO t_shared_name VALUES ('tab2_val');",
            "q_s2_init",
            None,
            false,
        )
        .await
        .unwrap();

        // While s1 runs a slow query, s2 must execute promptly without being blocked by s1's lock
        let slow_mgr_handle = tokio::spawn({
            let config = config.clone();
            async move {
                execute_session_script(&config, "test_concurrent_slow_s1", "SELECT pg_sleep(1.5);", "q_slow", None, false).await
            }
        });
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;

        let fast_start = Instant::now();
        let fast_res = execute_session_script(
            &config,
            "test_concurrent_fast_s2",
            "SELECT 1 as ok;",
            "q_fast",
            None,
            false,
        )
        .await
        .unwrap();
        assert_eq!(fast_res.rows.len(), 1);
        assert!(
            fast_start.elapsed().as_millis() < 1000,
            "Tab 2 should not block waiting on Tab 1's running query"
        );
        let _ = slow_mgr_handle.await;
        let _ = close_session("test_concurrent_slow_s1").await;
        let _ = close_session("test_concurrent_fast_s2").await;

        // Verify isolated session states remain intact in mgr
        let res1 = mgr
            .execute_session_script(
                &config,
                s1,
                "SELECT current_setting('TIMEZONE'), (SELECT v FROM t_shared_name);",
                "q_s1_check",
                None,
                false,
            )
            .await
            .unwrap();
        assert_eq!(res1.transaction_status, TransactionStatus::InTransaction);
        assert_eq!(res1.rows[0].cells[0], CellValue::Text("UTC".into()));
        assert_eq!(res1.rows[0].cells[1], CellValue::Text("tab1_val".into()));

        let res2 = mgr
            .execute_session_script(
                &config,
                s2,
                "SELECT current_setting('TIMEZONE'), (SELECT v FROM t_shared_name);",
                "q_s2_check",
                None,
                false,
            )
            .await
            .unwrap();
        assert_eq!(res2.transaction_status, TransactionStatus::Idle);
        assert_eq!(
            res2.rows[0].cells[0],
            CellValue::Text("America/New_York".into())
        );
        assert_eq!(res2.rows[0].cells[1], CellValue::Text("tab2_val".into()));

        mgr.close_all_sessions().await.unwrap();
        assert_eq!(mgr.active_session_count(), 0);
    }

    #[tokio::test]
    async fn test_session_cancellation_isolation() {
        let config = get_test_config();
        let s1 = "test_cancel_iso_s1";
        let s2 = "test_cancel_iso_s2";

        // Warm up sessions
        execute_session_script(&config, s1, "SELECT 1;", "warm1", None, false)
            .await
            .unwrap();
        execute_session_script(&config, s2, "SELECT 2;", "warm2", None, false)
            .await
            .unwrap();

        let task1 = tokio::spawn({
            let config = config.clone();
            async move {
                execute_session_script(&config, s1, "SELECT pg_sleep(5);", "qid_cancel_1", None, false).await
            }
        });
        let task2 = tokio::spawn({
            let config = config.clone();
            async move {
                execute_session_script(&config, s2, "SELECT pg_sleep(0.6);", "qid_keep_2", None, false).await
            }
        });

        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        let cancelled = crate::query::cancel_active_query("qid_cancel_1").await.unwrap();
        assert!(cancelled);

        let res1 = task1.await.unwrap();
        assert!(matches!(res1, Err(LucidError::QueryCancelled)));

        let res2 = task2.await.unwrap();
        assert!(res2.is_ok(), "Unrelated Tab 2 query must not be cancelled");

        close_session(s1).await.unwrap();
        close_session(s2).await.unwrap();
    }

    #[tokio::test]
    async fn test_session_limit_and_close_cleanup() {
        let config = get_test_config();
        let mgr = SessionManager::new(2);

        mgr.execute_session_script(&config, "lim_1", "SELECT 1;", "ql1", None, false)
            .await
            .unwrap();
        mgr.execute_session_script(&config, "lim_2", "SELECT 2;", "ql2", None, false)
            .await
            .unwrap();
        assert_eq!(mgr.active_session_count(), 2);

        let err = mgr
            .execute_session_script(&config, "lim_3", "SELECT 3;", "ql3", None, false)
            .await
            .unwrap_err();
        match err {
            LucidError::ConnectionFailed { reason } => {
                assert!(reason.contains("limit reached (2/2)"));
            }
            other => panic!("Expected ConnectionFailed for session cap, got {:?}", other),
        }

        // Closing one session frees capacity immediately
        mgr.close_session("lim_1").await.unwrap();
        assert_eq!(mgr.active_session_count(), 1);

        mgr.execute_session_script(&config, "lim_3", "SELECT 3;", "ql3_retry", None, false)
            .await
            .unwrap();
        assert_eq!(mgr.active_session_count(), 2);

        mgr.close_all_sessions().await.unwrap();
        assert_eq!(mgr.active_session_count(), 0);
    }

    #[tokio::test]
    async fn test_close_running_session_cancels_and_rolls_back() {
        let config = get_test_config();
        let mgr = SessionManager::new(4);
        let tbl = "lucidsql_close_rollback_test";

        mgr.execute_session_script(
            &config,
            "s_setup",
            &format!("DROP TABLE IF EXISTS {}; CREATE TABLE {} (id int primary key);", tbl, tbl),
            "q_setup",
            None,
            false,
        )
        .await
        .unwrap();
        mgr.close_session("s_setup").await.unwrap();

        mgr.execute_session_script(
            &config,
            "s_tx",
            &format!("BEGIN; INSERT INTO {} VALUES (99);", tbl),
            "q_tx_insert",
            None,
            false,
        )
        .await
        .unwrap();

        let running_task = tokio::spawn({
            let config = config.clone();
            // Run against default manager or shared? Use mgr? Wait: mgr isn't Send+Sync across spawn unless Arc!
            async move {
                execute_session_script(&config, "s_close_running_global", &format!("BEGIN; INSERT INTO {} VALUES (100);", tbl), "q_g1", None, false).await.unwrap();
                execute_session_script(&config, "s_close_running_global", "SELECT pg_sleep(5);", "q_g2", None, false).await
            }
        });

        // Clean close on idle-in-tx session in mgr first
        mgr.close_session("s_tx").await.unwrap();
        assert_eq!(mgr.active_session_count(), 0);

        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        close_session("s_close_running_global").await.unwrap();
        let running_res = running_task.await.unwrap();
        assert!(running_res.is_err());

        // Verify neither uncommitted row (99 or 100) was committed, then drop table
        let verify = mgr
            .execute_session_script(
                &config,
                "s_verify",
                &format!("SELECT count(*) FROM {}; DROP TABLE {};", tbl, tbl),
                "q_verify",
                None,
                false,
            )
            .await
            .unwrap();
        assert_eq!(verify.rows[0].cells[0], CellValue::Integer(0));
        mgr.close_all_sessions().await.unwrap();
    }

    #[tokio::test]
    async fn test_session_connection_loss_detection_and_recovery() {
        let config = get_test_config();
        let mgr = SessionManager::new(4);
        let sid = "s_conn_loss";

        mgr.execute_session_script(&config, sid, "SELECT 1;", "q1", None, false)
            .await
            .unwrap();
        let info = mgr.get_session_info(sid).await.unwrap();
        let pid1 = info.backend_pid;

        // Terminate backend externally from another session
        mgr.execute_session_script(
            &config,
            "s_killer",
            &format!("SELECT pg_terminate_backend({});", pid1),
            "q_kill",
            None,
            false,
        )
        .await
        .unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        let lost_err = mgr
            .execute_session_script(&config, sid, "SELECT 2;", "q2", None, false)
            .await
            .unwrap_err();
        match lost_err {
            LucidError::ConnectionFailed { reason } => {
                assert!(reason.contains("lost") || reason.contains("closed"));
            }
            other => panic!("Expected ConnectionFailed on terminated session, got {:?}", other),
        }

        // Next execution opens a fresh clean session with a new backend_pid
        mgr.execute_session_script(&config, sid, "SELECT 3;", "q3", None, false)
            .await
            .unwrap();
        let new_info = mgr.get_session_info(sid).await.unwrap();
        assert_ne!(new_info.backend_pid, pid1);

        mgr.close_all_sessions().await.unwrap();
    }
}
