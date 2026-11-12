pub mod pool;
pub mod session;
pub mod tls;

pub use pool::ManagedPool;
pub use session::{
    active_session_count, close_all_sessions, close_session, execute_session_script,
    get_or_create_session, get_session_info, max_dedicated_sessions, set_session_read_only,
    DedicatedSession, SessionInfo, TransactionStatus,
};

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ConnectionConfig {
    pub host: String,
    pub port: u16,
    pub database: String,
    pub user: String,
    pub password: Option<String>,
    pub ssl_mode: String,
    pub ssl_root_cert: Option<String>,
    pub timeout_seconds: u32,
}
