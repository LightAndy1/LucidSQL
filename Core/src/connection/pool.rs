use deadpool_postgres::{Config, ManagerConfig, Pool, RecyclingMethod, Runtime};
use tokio_postgres::NoTls;
use crate::error::LucidError;
use super::ConnectionConfig;

pub struct ManagedPool {
    pool: Pool,
}

impl ManagedPool {
    pub fn new(config: &ConnectionConfig) -> Result<Self, LucidError> {
        let mut cfg = Config::new();
        cfg.host = Some(config.host.clone());
        cfg.port = Some(config.port);
        cfg.dbname = Some(config.database.clone());
        cfg.user = Some(config.user.clone());
        cfg.password = config.password.clone();
        cfg.manager = Some(ManagerConfig {
            recycling_method: RecyclingMethod::Clean, // executes DISCARD ALL or RESET ALL
        });

        let pool = cfg
            .create_pool(Some(Runtime::Tokio1), NoTls)
            .map_err(|e| LucidError::ConnectionFailed {
                reason: e.to_string(),
            })?;

        Ok(Self { pool })
    }

    pub fn pool(&self) -> &Pool {
        &self.pool
    }

    pub async fn get(&self) -> Result<deadpool_postgres::Client, LucidError> {
        self.pool.get().await.map_err(|e| LucidError::ConnectionFailed {
            reason: e.to_string(),
        })
    }
}
