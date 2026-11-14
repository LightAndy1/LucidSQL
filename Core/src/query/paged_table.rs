use deadpool_postgres::Client;
use tokio_postgres::types::ToSql;

use super::{map_cell_value, RecordPage, RowData};
use crate::error::LucidError;
use crate::query::execute::map_postgres_error;
use crate::schema::ColumnMetadata;

pub fn sanitize_identifier(ident: &str) -> String {
    ident.replace('"', "\"\"")
}

/// Explicitly defines the PostgreSQL column types (`pg_type.typname`) eligible for
/// plain-language literal search (`ILIKE`).
///
/// Binary (`bytea`, `bit`, `varbit`), structured/document (`json`, `jsonb`, `xml`,
/// `tsvector`, `tsquery`), array (`_*`), geometric, range, and internal catalog vector/tree
/// types are intentionally excluded so we never indiscriminately cast large or binary blobs.
pub fn is_searchable_pg_type(pg_type_name: &str) -> bool {
    matches!(
        pg_type_name.to_ascii_lowercase().as_str(),
        // Textual types & standard information_schema text domains
        "text"
            | "varchar"
            | "bpchar"
            | "char"
            | "name"
            | "citext"
            | "sql_identifier"
            | "character_data"
            | "yes_or_no"
            // Numeric, OID & boolean scalar types
            | "int2"
            | "int4"
            | "int8"
            | "oid"
            | "cardinal_number"
            | "numeric"
            | "decimal"
            | "float4"
            | "float8"
            | "bool"
            // Temporal scalar types
            | "date"
            | "time"
            | "timetz"
            | "timestamp"
            | "timestamptz"
            | "time_stamp"
            // Identifier & network scalar types
            | "uuid"
            | "inet"
            | "cidr"
            | "macaddr"
            | "macaddr8"
    )
}

fn is_native_ilike_text_type(pg_type_name: &str) -> bool {
    matches!(pg_type_name.to_ascii_lowercase().as_str(), "text" | "varchar")
}

/// Escapes `%`, `_`, and `\` so plain-language user queries match literally under
/// `ILIKE $N ESCAPE E'\\'`.
pub fn escape_ilike_literal(input: &str) -> String {
    let mut escaped = String::with_capacity(input.len() + 4);
    for ch in input.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '%' => escaped.push_str("\\%"),
            '_' => escaped.push_str("\\_"),
            _ => escaped.push(ch),
        }
    }
    format!("%{}%", escaped)
}

fn column_ilike_predicate(col: &ColumnMetadata, param_idx: usize) -> String {
    let clean_col = sanitize_identifier(&col.name);
    if is_native_ilike_text_type(&col.pg_type_name) {
        format!(r#""{}" ILIKE ${} ESCAPE E'\\'"#, clean_col, param_idx)
    } else {
        format!(r#""{}"::text ILIKE ${} ESCAPE E'\\'"#, clean_col, param_idx)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TableSearchFilter {
    pub where_clause: String,
    pub pattern_param: Option<String>,
}

/// Builds a parameterized `WHERE` clause for literal case-insensitive matching across either
/// one validated column or all explicitly supported searchable columns.
pub fn build_search_filter(
    columns: &[ColumnMetadata],
    search_query: Option<&str>,
    search_column: Option<&str>,
    param_idx: usize,
) -> Result<TableSearchFilter, LucidError> {
    let raw_query = match search_query {
        Some(q) if !q.trim().is_empty() => q,
        _ => {
            return Ok(TableSearchFilter {
                where_clause: String::new(),
                pattern_param: None,
            });
        }
    };

    if raw_query.contains('\0') {
        return Err(LucidError::DatabaseError {
            code: "22021".into(),
            message: "Search text cannot contain NUL characters.".into(),
            detail: None,
        });
    }

    let pattern = escape_ilike_literal(raw_query);

    if let Some(target_col_name) = search_column {
        let Some(col) = columns.iter().find(|c| c.name == target_col_name) else {
            return Err(LucidError::DatabaseError {
                code: "42703".into(),
                message: format!("Search column '{}' does not exist in this table.", target_col_name),
                detail: None,
            });
        };

        if !is_searchable_pg_type(&col.pg_type_name) {
            return Err(LucidError::DatabaseError {
                code: "22023".into(),
                message: format!(
                    "Column '{}' (type '{}') does not support literal text search.",
                    col.name, col.pg_type_name
                ),
                detail: None,
            });
        }

        let predicate = column_ilike_predicate(col, param_idx);
        return Ok(TableSearchFilter {
            where_clause: format!(" WHERE {}", predicate),
            pattern_param: Some(pattern),
        });
    }

    let predicates: Vec<String> = columns
        .iter()
        .filter(|c| is_searchable_pg_type(&c.pg_type_name))
        .map(|c| column_ilike_predicate(c, param_idx))
        .collect();

    if predicates.is_empty() {
        return Err(LucidError::DatabaseError {
            code: "22023".into(),
            message: "This table has no searchable text or scalar columns.".into(),
            detail: None,
        });
    }

    Ok(TableSearchFilter {
        where_clause: format!(" WHERE ({})", predicates.join(" OR ")),
        pattern_param: Some(pattern),
    })
}

/// Builds a deterministic `ORDER BY` clause when primary keys or a sort column exist.
/// Primary-key columns are appended as `ASC` tie-breakers when sorting by a non-PK column,
/// and used directly as the default sort order when `sort_col` is `None`.
pub fn build_order_clause(
    columns: &[ColumnMetadata],
    sort_col: Option<&str>,
    sort_desc: bool,
) -> Result<String, LucidError> {
    let pk_cols: Vec<&str> = columns
        .iter()
        .filter(|c| c.is_primary_key)
        .map(|c| c.name.as_str())
        .collect();

    let mut terms: Vec<String> = Vec::new();
    if let Some(col) = sort_col {
        if !columns.iter().any(|c| c.name == col) {
            return Err(LucidError::DatabaseError {
                code: "42703".into(),
                message: format!("Sort column '{}' does not exist in this table.", col),
                detail: None,
            });
        }
        let dir = if sort_desc { "DESC" } else { "ASC" };
        terms.push(format!(r#""{}" {}"#, sanitize_identifier(col), dir));
        for pk in pk_cols {
            if pk != col {
                terms.push(format!(r#""{}" ASC"#, sanitize_identifier(pk)));
            }
        }
    } else {
        for pk in pk_cols {
            terms.push(format!(r#""{}" ASC"#, sanitize_identifier(pk)));
        }
    }

    if terms.is_empty() {
        Ok(String::new())
    } else {
        Ok(format!(" ORDER BY {}", terms.join(", ")))
    }
}

pub async fn fetch_page(
    client: &Client,
    schema: &str,
    table: &str,
    offset: u64,
    limit: u32,
    sort_col: Option<String>,
    sort_desc: bool,
    has_pk: bool,
) -> Result<RecordPage, LucidError> {
    let order_clause = if let Some(ref col) = sort_col {
        let dir = if sort_desc { "DESC" } else { "ASC" };
        format!(r#" ORDER BY "{}" {}"#, sanitize_identifier(col), dir)
    } else {
        String::new()
    };

    fetch_page_sql(
        client,
        schema,
        table,
        offset,
        limit,
        has_pk,
        "",
        &order_clause,
        None,
    )
    .await
}

pub async fn fetch_page_with_columns(
    client: &Client,
    schema: &str,
    table: &str,
    columns: &[ColumnMetadata],
    offset: u64,
    limit: u32,
    sort_col: Option<&str>,
    sort_desc: bool,
    search_query: Option<&str>,
    search_column: Option<&str>,
) -> Result<RecordPage, LucidError> {
    if columns.is_empty() {
        return Err(LucidError::DatabaseError {
            code: "42P01".into(),
            message: format!("Table '{}.{}' was not found or has no columns.", schema, table),
            detail: None,
        });
    }

    let has_pk = columns.iter().any(|c| c.is_primary_key);
    let filter = build_search_filter(columns, search_query, search_column, 3)?;
    let order_clause = build_order_clause(columns, sort_col, sort_desc)?;

    fetch_page_sql(
        client,
        schema,
        table,
        offset,
        limit,
        has_pk,
        &filter.where_clause,
        &order_clause,
        filter.pattern_param,
    )
    .await
}

async fn fetch_page_sql(
    client: &Client,
    schema: &str,
    table: &str,
    offset: u64,
    limit: u32,
    has_pk: bool,
    where_clause: &str,
    order_clause: &str,
    pattern_param: Option<String>,
) -> Result<RecordPage, LucidError> {
    let start = std::time::Instant::now();
    let effective_limit = limit.max(1);
    let fetch_limit = (effective_limit as i64).saturating_add(1);
    let offset_i64 = i64::try_from(offset).map_err(|_| LucidError::DatabaseError {
        code: "22003".into(),
        message: "Requested page offset exceeds PostgreSQL integer range.".into(),
        detail: None,
    })?;

    let clean_schema = sanitize_identifier(schema);
    let clean_table = sanitize_identifier(table);

    let select_prefix = if has_pk {
        "SELECT xmin::text AS _lucid_xmin, *"
    } else {
        "SELECT *"
    };

    let sql = format!(
        r#"{} FROM "{}"."{}"{}{} LIMIT $1 OFFSET $2"#,
        select_prefix, clean_schema, clean_table, where_clause, order_clause
    );

    let rows = match pattern_param {
        Some(ref pattern) => {
            let params: [&(dyn ToSql + Sync); 3] = [&fetch_limit, &offset_i64, pattern];
            client
                .query(&sql, &params)
                .await
                .map_err(map_postgres_error)?
        }
        None => {
            let params: [&(dyn ToSql + Sync); 2] = [&fetch_limit, &offset_i64];
            client
                .query(&sql, &params)
                .await
                .map_err(map_postgres_error)?
        }
    };

    let limit_usize = effective_limit as usize;
    let has_more = rows.len() > limit_usize;
    let take_count = rows.len().min(limit_usize);

    let mut record_rows = Vec::with_capacity(take_count);
    for row in &rows[..take_count] {
        let mut cells = Vec::with_capacity(row.len());
        for i in 0..row.len() {
            cells.push(map_cell_value(row, i));
        }
        record_rows.push(RowData { cells });
    }

    Ok(RecordPage {
        rows: record_rows,
        total_rows_fetched: take_count as u64,
        has_more,
        execution_duration_ms: start.elapsed().as_millis() as u64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::{ConnectionConfig, ManagedPool};
    use crate::query::CellValue;
    use crate::schema::query_columns;

    fn col(name: &str, pg_type_name: &str, is_pk: bool) -> ColumnMetadata {
        ColumnMetadata {
            name: name.to_string(),
            ordinal_position: 1,
            pg_type_name: pg_type_name.to_string(),
            pg_type_oid: 25,
            is_primary_key: is_pk,
            is_nullable: !is_pk,
            default_value: None,
            is_generated: false,
            is_identity: false,
            is_identity_always: false,
        }
    }

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

    #[test]
    fn test_escape_ilike_literal() {
        assert_eq!(escape_ilike_literal("hello"), "%hello%");
        assert_eq!(escape_ilike_literal("100%_a\\b"), "%100\\%\\_a\\\\b%");
        assert_eq!(escape_ilike_literal("O'Reilly \"Pro\""), "%O'Reilly \"Pro\"%");
    }

    #[test]
    fn test_searchable_types_allowlist_and_exclusions() {
        for ty in [
            "text",
            "varchar",
            "bpchar",
            "char",
            "name",
            "citext",
            "int2",
            "int4",
            "int8",
            "oid",
            "numeric",
            "decimal",
            "float4",
            "float8",
            "bool",
            "date",
            "time",
            "timetz",
            "timestamp",
            "timestamptz",
            "uuid",
            "inet",
            "cidr",
            "macaddr",
        ] {
            assert!(is_searchable_pg_type(ty), "expected {} to be searchable", ty);
        }

        for ty in [
            "bytea",
            "bit",
            "varbit",
            "json",
            "jsonb",
            "xml",
            "tsvector",
            "_text",
            "_int4",
            "point",
            "int2vector",
            "pg_node_tree",
        ] {
            assert!(!is_searchable_pg_type(ty), "expected {} NOT to be searchable", ty);
        }
    }

    #[test]
    fn test_build_search_filter_excludes_binary_and_quotes_identifiers() {
        let cols = vec![
            col("id", "int4", true),
            col("Full \"Name\"", "text", false),
            col("payload", "bytea", false),
            col("meta", "jsonb", false),
        ];

        let filter = build_search_filter(&cols, Some("50%_off"), None, 3).unwrap();
        assert_eq!(
            filter.where_clause,
            r#" WHERE ("id"::text ILIKE $3 ESCAPE E'\\' OR "Full ""Name""" ILIKE $3 ESCAPE E'\\')"#
        );
        assert_eq!(filter.pattern_param.as_deref(), Some("%50\\%\\_off%"));

        // Selecting a non-searchable column explicitly fails with clear error
        let err = build_search_filter(&cols, Some("abc"), Some("payload"), 3).unwrap_err();
        assert!(err.to_string().contains("does not support literal text search"));

        // Whitespace-only query yields no filter
        let empty = build_search_filter(&cols, Some("   "), None, 3).unwrap();
        assert!(empty.where_clause.is_empty());
        assert!(empty.pattern_param.is_none());
    }

    #[test]
    fn test_build_order_clause_deterministic_pk_tiebreakers() {
        let cols = vec![
            col("tenant_id", "int4", true),
            col("id", "int8", true),
            col("title", "text", false),
        ];

        assert_eq!(
            build_order_clause(&cols, None, false).unwrap(),
            r#" ORDER BY "tenant_id" ASC, "id" ASC"#
        );
        assert_eq!(
            build_order_clause(&cols, Some("title"), true).unwrap(),
            r#" ORDER BY "title" DESC, "tenant_id" ASC, "id" ASC"#
        );
        assert_eq!(
            build_order_clause(&cols, Some("tenant_id"), true).unwrap(),
            r#" ORDER BY "tenant_id" DESC, "id" ASC"#
        );

        let no_pk_cols = vec![col("val", "text", false)];
        assert_eq!(build_order_clause(&no_pk_cols, None, false).unwrap(), "");
        assert_eq!(
            build_order_clause(&no_pk_cols, Some("val"), false).unwrap(),
            r#" ORDER BY "val" ASC"#
        );
    }

    #[tokio::test]
    async fn test_live_search_pagination_literals_unicode_null_and_has_more() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let client = pool.get().await.unwrap();

        let schema = "test_lucid_search_page";
        let table = "items";

        let _ = client
            .batch_execute(&format!(r#"DROP SCHEMA IF EXISTS "{}" CASCADE;"#, schema))
            .await;

        client
            .batch_execute(&format!(
                r#"
                CREATE SCHEMA "{schema}";
                CREATE TABLE "{schema}"."{table}" (
                    id int PRIMARY KEY,
                    "display""name" text,
                    code varchar(32),
                    raw_blob bytea,
                    notes text
                );
                INSERT INTO "{schema}"."{table}" (id, "display""name", code, raw_blob, notes)
                SELECT
                    g,
                    CASE
                        WHEN g = 120 THEN '100%_literal O''Reilly "Cafe"'
                        WHEN g = 135 THEN 'Café 🚀 Zürich'
                        WHEN g = 140 THEN 'NULL'
                        ELSE 'Item #' || g
                    END,
                    CASE
                        WHEN g = 120 THEN 'PCT_100'
                        WHEN g = 150 THEN 'MATCH_ME'
                        ELSE 'CODE_' || g
                    END,
                    E'\\xdeadbeef'::bytea,
                    CASE
                        WHEN g = 145 THEN NULL
                        ELSE 'note_' || g
                    END
                FROM generate_series(1, 150) AS g;
                "#,
                schema = schema,
                table = table
            ))
            .await
            .unwrap();

        let cols = query_columns(&client, schema, table).await.unwrap();

        // 1. Exact boundary LIMIT+1 check: 150 rows with limit 150 => has_more = false
        let exact_page = fetch_page_with_columns(
            &client, schema, table, &cols, 0, 150, None, false, None, None,
        )
        .await
        .unwrap();
        assert_eq!(exact_page.rows.len(), 150);
        assert!(!exact_page.has_more);

        // 2. Literal %, _, quotes, and backslash outside page 1
        let pct_page = fetch_page_with_columns(
            &client,
            schema,
            table,
            &cols,
            0,
            25,
            None,
            false,
            Some("100%_literal O'Reilly \"Cafe\""),
            None,
        )
        .await
        .unwrap();
        assert_eq!(pct_page.rows.len(), 1);
        assert!(!pct_page.has_more);
        assert_eq!(pct_page.rows[0].cells[1], CellValue::Integer(120));

        // Searching "100%_literal" must NOT treat % or _ as wildcard matching "100Xliteral"
        let no_wildcard = fetch_page_with_columns(
            &client,
            schema,
            table,
            &cols,
            0,
            25,
            None,
            false,
            Some("Item #1_"),
            None,
        )
        .await
        .unwrap();
        assert_eq!(no_wildcard.rows.len(), 0);

        // 3. Unicode match outside page 1
        let unicode_page = fetch_page_with_columns(
            &client,
            schema,
            table,
            &cols,
            0,
            25,
            None,
            false,
            Some("café 🚀"),
            None,
        )
        .await
        .unwrap();
        assert_eq!(unicode_page.rows.len(), 1);
        assert_eq!(unicode_page.rows[0].cells[1], CellValue::Integer(135));

        // 4. NULL vs literal "NULL": searching "null" matches row 140 ('NULL'), not row 145 (SQL NULL)
        let null_page = fetch_page_with_columns(
            &client,
            schema,
            table,
            &cols,
            0,
            25,
            None,
            false,
            Some("null"),
            None,
        )
        .await
        .unwrap();
        assert_eq!(null_page.rows.len(), 1);
        assert_eq!(null_page.rows[0].cells[1], CellValue::Integer(140));

        // 5. Column-scoped search vs all-searchable columns
        let col_scoped = fetch_page_with_columns(
            &client,
            schema,
            table,
            &cols,
            0,
            25,
            None,
            false,
            Some("MATCH_ME"),
            Some("code"),
        )
        .await
        .unwrap();
        assert_eq!(col_scoped.rows.len(), 1);
        assert_eq!(col_scoped.rows[0].cells[1], CellValue::Integer(150));

        // Searching "deadbeef" must NOT match bytea column raw_blob
        let binary_skip = fetch_page_with_columns(
            &client,
            schema,
            table,
            &cols,
            0,
            25,
            None,
            false,
            Some("deadbeef"),
            None,
        )
        .await
        .unwrap();
        assert_eq!(binary_skip.rows.len(), 0);

        // 6. Paginating filtered results across multiple pages
        let paged_search_p1 = fetch_page_with_columns(
            &client,
            schema,
            table,
            &cols,
            0,
            25,
            None,
            false,
            Some("Item #1"),
            None,
        )
        .await
        .unwrap();
        assert_eq!(paged_search_p1.rows.len(), 25);
        assert!(paged_search_p1.has_more);

        let paged_search_p2 = fetch_page_with_columns(
            &client,
            schema,
            table,
            &cols,
            25,
            25,
            None,
            false,
            Some("Item #1"),
            None,
        )
        .await
        .unwrap();
        assert!(!paged_search_p2.rows.is_empty());

        let _ = client
            .batch_execute(&format!(r#"DROP SCHEMA IF EXISTS "{}" CASCADE;"#, schema))
            .await;
    }
}
