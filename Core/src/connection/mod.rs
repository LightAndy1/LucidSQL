pub mod pool;
pub mod session;

pub use pool::ManagedPool;
pub use session::{
    close_session, execute_session_script, get_or_create_session, get_session_info,
    set_session_read_only, DedicatedSession, SessionInfo, TransactionStatus,
};

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ConnectionConfig {
    pub host: String,
    pub port: u16,
    pub database: String,
    pub user: String,
    pub password: Option<String>,
    pub ssl_mode: String,
    pub timeout_seconds: u32,
}
