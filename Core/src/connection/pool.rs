use std::time::Duration;

use deadpool_postgres::{
    Config, ManagerConfig, Pool, PoolConfig, PoolError, RecyclingMethod, Runtime, SslMode,
    Timeouts,
};
use tokio_postgres::NoTls;

use crate::error::LucidError;
use super::tls::{build_rustls_connect, format_error_chain, map_postgres_connect_error, LucidSslMode};
use super::ConnectionConfig;

pub struct ManagedPool {
    pool: Pool,
}

impl ManagedPool {
    pub fn new(config: &ConnectionConfig) -> Result<Self, LucidError> {
        let ssl_mode = LucidSslMode::parse(&config.ssl_mode)?;
        let timeout = Duration::from_secs(config.timeout_seconds.max(1) as u64);

        let mut cfg = Config::new();
        cfg.host = Some(config.host.clone());
        cfg.port = Some(config.port);
        cfg.dbname = Some(config.database.clone());
        cfg.user = Some(config.user.clone());
        cfg.password = config.password.clone();
        cfg.ssl_mode = Some(match ssl_mode {
            LucidSslMode::Disable => SslMode::Disable,
            LucidSslMode::Prefer => SslMode::Prefer,
            LucidSslMode::Require | LucidSslMode::VerifyCa | LucidSslMode::VerifyFull => {
                SslMode::Require
            }
        });
        cfg.connect_timeout = Some(timeout);
        cfg.pool = Some(PoolConfig {
            timeouts: Timeouts {
                wait: Some(timeout),
                create: Some(timeout),
                recycle: Some(Duration::from_secs(5)),
            },
            ..Default::default()
        });
        cfg.manager = Some(ManagerConfig {
            recycling_method: RecyclingMethod::Clean, // executes DISCARD ALL or RESET ALL
        });

        let pool = match build_rustls_connect(ssl_mode, config.ssl_root_cert.as_deref())? {
            Some(tls) => cfg.create_pool(Some(Runtime::Tokio1), tls),
            None => cfg.create_pool(Some(Runtime::Tokio1), NoTls),
        }
        .map_err(|e| LucidError::ConnectionFailed {
            reason: format_error_chain(&e),
        })?;

        Ok(Self { pool })
    }

    pub fn pool(&self) -> &Pool {
        &self.pool
    }

    pub async fn get(&self) -> Result<deadpool_postgres::Client, LucidError> {
        self.pool.get().await.map_err(|e| match &e {
            PoolError::Backend(pg_err) => map_postgres_connect_error(pg_err),
            _ => LucidError::ConnectionFailed {
                reason: format_error_chain(&e),
            },
        })
    }
}
