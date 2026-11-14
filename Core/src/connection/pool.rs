use std::collections::{HashMap, VecDeque};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use deadpool_postgres::{
    Config, ManagerConfig, Pool, PoolConfig, PoolError, RecyclingMethod, Runtime, SslMode,
    Timeouts,
};
use tokio_postgres::NoTls;

use crate::error::LucidError;
use super::tls::{build_rustls_connect, format_error_chain, map_postgres_connect_error, LucidSslMode};
use super::ConnectionConfig;

const MAX_CACHED_POOLS: usize = 16;

#[derive(Clone, PartialEq, Eq, Hash)]
struct PoolKey {
    host: String,
    port: u16,
    database: String,
    user: String,
    password: Option<String>,
    ssl_mode: String,
    ssl_root_cert: Option<String>,
    timeout_seconds: u32,
}

impl PoolKey {
    fn from_config(config: &ConnectionConfig) -> Self {
        Self {
            host: config.host.clone(),
            port: config.port,
            database: config.database.clone(),
            user: config.user.clone(),
            password: config.password.clone(),
            ssl_mode: config.ssl_mode.clone(),
            ssl_root_cert: config.ssl_root_cert.clone(),
            timeout_seconds: config.timeout_seconds.max(1),
        }
    }
}

struct PoolCache {
    pools: HashMap<PoolKey, Pool>,
    order: VecDeque<PoolKey>,
}

impl PoolCache {
    fn new() -> Self {
        Self {
            pools: HashMap::new(),
            order: VecDeque::new(),
        }
    }

    fn touch(&mut self, key: &PoolKey) {
        self.order.retain(|k| k != key);
        self.order.push_back(key.clone());
    }

    fn get_or_insert_with<F>(&mut self, key: PoolKey, build: F) -> Result<Pool, LucidError>
    where
        F: FnOnce() -> Result<Pool, LucidError>,
    {
        if let Some(existing) = self.pools.get(&key) {
            if !existing.is_closed() {
                let cloned = existing.clone();
                self.touch(&key);
                return Ok(cloned);
            }
            self.pools.remove(&key);
            self.order.retain(|k| k != &key);
        }

        let created = build()?;
        while self.pools.len() >= MAX_CACHED_POOLS {
            if let Some(oldest) = self.order.pop_front() {
                if let Some(evicted) = self.pools.remove(&oldest) {
                    evicted.close();
                }
            } else {
                break;
            }
        }
        self.touch(&key);
        self.pools.insert(key, created.clone());
        Ok(created)
    }

    fn close_all(&mut self) {
        for (_, pool) in self.pools.drain() {
            pool.close();
        }
        self.order.clear();
    }
}

static SHARED_POOL_CACHE: LazyLock<Mutex<PoolCache>> =
    LazyLock::new(|| Mutex::new(PoolCache::new()));

pub fn close_all_cached_pools() {
    if let Ok(mut cache) = SHARED_POOL_CACHE.lock() {
        cache.close_all();
    }
}

pub fn cached_pool_count() -> usize {
    SHARED_POOL_CACHE
        .lock()
        .map(|cache| cache.pools.len())
        .unwrap_or(0)
}

pub struct ManagedPool {
    pool: Pool,
}

impl ManagedPool {
    fn build_pool(config: &ConnectionConfig, max_size: Option<usize>) -> Result<Pool, LucidError> {
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
        let mut pool_cfg = PoolConfig {
            timeouts: Timeouts {
                wait: Some(timeout),
                create: Some(timeout),
                recycle: Some(Duration::from_secs(5)),
            },
            ..Default::default()
        };
        if let Some(size) = max_size {
            pool_cfg.max_size = size;
        }
        cfg.pool = Some(pool_cfg);
        cfg.manager = Some(ManagerConfig {
            recycling_method: RecyclingMethod::Clean, // executes DISCARD ALL or RESET ALL
        });

        match build_rustls_connect(ssl_mode, config.ssl_root_cert.as_deref())? {
            Some(tls) => cfg.create_pool(Some(Runtime::Tokio1), tls),
            None => cfg.create_pool(Some(Runtime::Tokio1), NoTls),
        }
        .map_err(|e| LucidError::ConnectionFailed {
            reason: format_error_chain(&e),
        })
    }

    pub fn new(config: &ConnectionConfig) -> Result<Self, LucidError> {
        let pool = Self::build_pool(config, None)?;
        Ok(Self { pool })
    }

    pub fn shared(config: &ConnectionConfig) -> Result<Self, LucidError> {
        let key = PoolKey::from_config(config);
        let mut cache = SHARED_POOL_CACHE.lock().map_err(|_| LucidError::ConnectionFailed {
            reason: "Connection pool registry lock poisoned.".to_string(),
        })?;
        let pool = cache.get_or_insert_with(key, || Self::build_pool(config, Some(8)))?;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_config(host: &str, database: &str, ssl_mode: &str) -> ConnectionConfig {
        ConnectionConfig {
            host: host.to_string(),
            port: 5432,
            database: database.to_string(),
            user: "postgres".to_string(),
            password: Some("secret".to_string()),
            ssl_mode: ssl_mode.to_string(),
            ssl_root_cert: None,
            timeout_seconds: 5,
        }
    }

    #[test]
    fn pool_cache_reuses_matching_config_and_separates_distinct_configs() {
        let mut cache = PoolCache::new();
        let mut builds = 0usize;

        let cfg1 = sample_config("127.0.0.1", "db_a", "disable");
        let p1 = cache
            .get_or_insert_with(PoolKey::from_config(&cfg1), || {
                builds += 1;
                ManagedPool::build_pool(&cfg1, Some(4))
            })
            .unwrap();
        let p2 = cache
            .get_or_insert_with(PoolKey::from_config(&cfg1), || {
                builds += 1;
                ManagedPool::build_pool(&cfg1, Some(4))
            })
            .unwrap();

        assert_eq!(builds, 1);
        assert!(!p1.is_closed());
        assert!(!p2.is_closed());
        assert_eq!(cache.pools.len(), 1);

        let cfg2 = sample_config("127.0.0.1", "db_b", "disable");
        let _p3 = cache
            .get_or_insert_with(PoolKey::from_config(&cfg2), || {
                builds += 1;
                ManagedPool::build_pool(&cfg2, Some(4))
            })
            .unwrap();

        assert_eq!(builds, 2);
        assert_eq!(cache.pools.len(), 2);

        cache.close_all();
        assert_eq!(cache.pools.len(), 0);
        assert!(p1.is_closed());
    }

    #[test]
    fn pool_cache_evicts_oldest_when_capacity_exceeded() {
        let mut cache = PoolCache::new();
        let mut created_pools = Vec::new();

        for idx in 0..=MAX_CACHED_POOLS {
            let cfg = sample_config("127.0.0.1", &format!("db_{}", idx), "disable");
            let pool = cache
                .get_or_insert_with(PoolKey::from_config(&cfg), || {
                    ManagedPool::build_pool(&cfg, Some(2))
                })
                .unwrap();
            created_pools.push(pool);
        }

        assert_eq!(cache.pools.len(), MAX_CACHED_POOLS);
        assert!(created_pools[0].is_closed());
        assert!(!created_pools[MAX_CACHED_POOLS].is_closed());
    }
}
