use super::{map_cell_value, RecordPage, RowData};
use crate::error::LucidError;
use crate::query::execute::map_postgres_error;
use deadpool_postgres::Client;

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
    let start = std::time::Instant::now();

    // Sanitize identifier quoting by escaping double quotes
    let clean_schema = schema.replace('"', "\"\"");
    let clean_table = table.replace('"', "\"\"");

    let order_clause = if let Some(ref col) = sort_col {
        let clean_col = col.replace('"', "\"\"");
        let dir = if sort_desc { "DESC" } else { "ASC" };
        format!(r#"ORDER BY "{}" {}"#, clean_col, dir)
    } else {
        String::new()
    };

    let sql = if has_pk {
        format!(
            r#"SELECT xmin::text AS _lucid_xmin, * FROM "{}"."{}" {} LIMIT $1 OFFSET $2"#,
            clean_schema, clean_table, order_clause
        )
    } else {
        format!(
            r#"SELECT * FROM "{}"."{}" {} LIMIT $1 OFFSET $2"#,
            clean_schema, clean_table, order_clause
        )
    };

    let rows = client
        .query(&sql, &[&(limit as i64), &(offset as i64)])
        .await
        .map_err(map_postgres_error)?;

    let mut record_rows = Vec::new();
    for row in &rows {
        let mut cells = Vec::new();
        for i in 0..row.len() {
            cells.push(map_cell_value(row, i));
        }
        record_rows.push(RowData { cells });
    }

    Ok(RecordPage {
        rows: record_rows,
        total_rows_fetched: rows.len() as u64,
        has_more: rows.len() == (limit as usize),
        execution_duration_ms: start.elapsed().as_millis() as u64,
    })
}
