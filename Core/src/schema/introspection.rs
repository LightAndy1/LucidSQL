use std::collections::{HashMap, VecDeque};
use std::sync::{LazyLock, Mutex};

use crate::connection::ConnectionConfig;
use crate::error::LucidError;
use crate::query::execute::map_postgres_error;
use super::{ColumnMetadata, TableInfo};
use deadpool_postgres::GenericClient;

const MAX_CACHED_TABLE_COLUMNS: usize = 256;

#[derive(Clone, PartialEq, Eq, Hash)]
struct ColumnCacheKey {
    host: String,
    port: u16,
    database: String,
    user: String,
    ssl_mode: String,
    schema: String,
    table: String,
}

impl ColumnCacheKey {
    fn new(config: &ConnectionConfig, schema: &str, table: &str) -> Self {
        Self {
            host: config.host.clone(),
            port: config.port,
            database: config.database.clone(),
            user: config.user.clone(),
            ssl_mode: config.ssl_mode.clone(),
            schema: schema.to_string(),
            table: table.to_string(),
        }
    }
}

struct ColumnMetadataCache {
    entries: HashMap<ColumnCacheKey, Vec<ColumnMetadata>>,
    order: VecDeque<ColumnCacheKey>,
}

impl ColumnMetadataCache {
    fn new() -> Self {
        Self {
            entries: HashMap::new(),
            order: VecDeque::new(),
        }
    }

    fn get(&mut self, key: &ColumnCacheKey) -> Option<Vec<ColumnMetadata>> {
        let found = self.entries.get(key).cloned();
        if found.is_some() {
            self.order.retain(|k| k != key);
            self.order.push_back(key.clone());
        }
        found
    }

    fn insert(&mut self, key: ColumnCacheKey, cols: Vec<ColumnMetadata>) {
        self.order.retain(|k| k != &key);
        while self.entries.len() >= MAX_CACHED_TABLE_COLUMNS {
            if let Some(oldest) = self.order.pop_front() {
                self.entries.remove(&oldest);
            } else {
                break;
            }
        }
        self.order.push_back(key.clone());
        self.entries.insert(key, cols);
    }

    fn clear(&mut self) {
        self.entries.clear();
        self.order.clear();
    }
}

static COLUMN_METADATA_CACHE: LazyLock<Mutex<ColumnMetadataCache>> =
    LazyLock::new(|| Mutex::new(ColumnMetadataCache::new()));

pub fn clear_column_metadata_cache() {
    if let Ok(mut cache) = COLUMN_METADATA_CACHE.lock() {
        cache.clear();
    }
}

pub async fn query_columns_cached<C: GenericClient>(
    client: &C,
    config: &ConnectionConfig,
    schema: &str,
    table: &str,
    force_refresh: bool,
) -> Result<Vec<ColumnMetadata>, LucidError> {
    let key = ColumnCacheKey::new(config, schema, table);
    if !force_refresh {
        if let Ok(mut cache) = COLUMN_METADATA_CACHE.lock() {
            if let Some(cols) = cache.get(&key) {
                return Ok(cols);
            }
        }
    }

    let cols = query_columns(client, schema, table).await?;
    if let Ok(mut cache) = COLUMN_METADATA_CACHE.lock() {
        cache.insert(key, cols.clone());
    }
    Ok(cols)
}

pub async fn query_schemas<C: GenericClient>(client: &C) -> Result<Vec<String>, LucidError> {
    let sql = r#"
        SELECT nspname
        FROM pg_namespace
        WHERE nspname NOT LIKE 'pg_toast%'
          AND nspname NOT LIKE 'pg_temp%'
        ORDER BY (nspname = 'public') DESC, nspname ASC;
    "#;
    let rows = client
        .query(sql, &[])
        .await
        .map_err(map_postgres_error)?;

    Ok(rows.into_iter().map(|r| r.get::<_, String>(0)).collect())
}

pub async fn query_tables<C: GenericClient>(client: &C, schema: &str) -> Result<Vec<TableInfo>, LucidError> {
    let sql = r#"
        SELECT 
            c.table_name,
            c.table_type = 'VIEW' as is_view,
            COALESCE(s.n_live_tup, 0) as estimated_rows
        FROM information_schema.tables c
        LEFT JOIN pg_stat_user_tables s 
            ON s.schemaname = c.table_schema AND s.relname = c.table_name
        WHERE c.table_schema = $1
        ORDER BY c.table_name ASC;
    "#;
    let rows = client
        .query(sql, &[&schema])
        .await
        .map_err(map_postgres_error)?;

    let mut tables = Vec::new();
    for row in rows {
        tables.push(TableInfo {
            schema_name: schema.to_string(),
            table_name: row.get(0),
            is_view: row.get(1),
            estimated_row_count: row.get(2),
        });
    }
    Ok(tables)
}

pub async fn query_columns<C: GenericClient>(
    client: &C,
    schema: &str,
    table: &str,
) -> Result<Vec<ColumnMetadata>, LucidError> {
    let sql = r#"
        SELECT 
            a.attname as column_name,
            a.attnum as ordinal_position,
            t.typname as pg_type_name,
            t.oid as pg_type_oid,
            (pk.conkey IS NOT NULL AND a.attnum = ANY(pk.conkey)) as is_pk,
            NOT a.attnotnull as is_nullable,
            pg_get_expr(d.adbin, d.adrelid) as default_value,
            COALESCE(a.attgenerated, '') != '' as is_generated,
            a.attidentity IN ('a', 'd') as is_identity,
            a.attidentity = 'a' as is_identity_always
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_type t ON t.oid = a.atttypid
        LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
        LEFT JOIN pg_constraint pk ON pk.conrelid = c.oid AND pk.contype = 'p'
        WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum ASC;
    "#;
    let rows = client
        .query(sql, &[&schema, &table])
        .await
        .map_err(map_postgres_error)?;

    let mut columns = Vec::new();
    for row in rows {
        columns.push(ColumnMetadata {
            name: row.get(0),
            ordinal_position: row.get::<_, i16>(1) as u32,
            pg_type_name: row.get(2),
            pg_type_oid: row.get(3),
            is_primary_key: row.get(4),
            is_nullable: row.get(5),
            default_value: row.get(6),
            is_generated: row.get(7),
            is_identity: row.get(8),
            is_identity_always: row.get(9),
        });
    }
    Ok(columns)
}
