pub mod pool;
pub use pool::ManagedPool;

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
