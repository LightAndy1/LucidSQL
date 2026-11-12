use std::collections::{HashMap, HashSet};
use deadpool_postgres::{Client, GenericClient, Transaction};
use tokio_postgres::types::ToSql;
use tokio_postgres::Row;

use crate::error::LucidError;
use crate::mutation::{
    BatchMutationRequest, BatchMutationResult, InsertedRowResult, RowDelete, RowInsert, RowMutation,
};
use crate::query::execute::map_postgres_error;
use crate::query::value_mapper::map_cell_value;
use crate::query::{CellValue, RowData};
use crate::schema::is_system_schema;

fn sanitize_identifier(ident: &str) -> String {
    ident.replace('"', "\"\"")
}

fn format_cell_value_for_display(val: &CellValue) -> String {
    match val {
        CellValue::Null => "NULL".into(),
        CellValue::Text(s) => format!("'{}'", s),
        CellValue::Boolean(b) => b.to_string(),
        CellValue::Integer(i) => i.to_string(),
        CellValue::Decimal(s)
        | CellValue::TimestampWithTimeZone(s)
        | CellValue::TimestampWithoutTimeZone(s)
        | CellValue::Date(s)
        | CellValue::Time(s)
        | CellValue::Uuid(s)
        | CellValue::BinaryHex(s)
        | CellValue::Json(s) => s.clone(),
        CellValue::Float(f) => f.to_string(),
        CellValue::Unsupported(reason) => format!("Unsupported({})", reason),
    }
}

fn cell_value_to_param(val: &CellValue, role: &str) -> Result<Option<String>, LucidError> {
    match val {
        CellValue::Null => Ok(None),
        CellValue::Text(s) => Ok(Some(s.clone())),
        CellValue::Boolean(b) => Ok(Some(b.to_string())),
        CellValue::Integer(i) => Ok(Some(i.to_string())),
        CellValue::Decimal(s) => Ok(Some(s.clone())),
        CellValue::Float(f) => Ok(Some(f.to_string())),
        CellValue::TimestampWithTimeZone(s) => Ok(Some(s.clone())),
        CellValue::TimestampWithoutTimeZone(s) => Ok(Some(s.clone())),
        CellValue::Date(s) => Ok(Some(s.clone())),
        CellValue::Time(s) => Ok(Some(s.clone())),
        CellValue::Uuid(s) => Ok(Some(s.clone())),
        CellValue::BinaryHex(s) => Ok(Some(s.clone())),
        CellValue::Json(s) => Ok(Some(s.clone())),
        CellValue::Unsupported(reason) => Err(LucidError::DatabaseError {
            code: "22023".into(),
            message: format!(
                "Cannot use unsupported {} value ({}) in table mutation.",
                role, reason
            ),
            detail: None,
        }),
    }
}

struct MutationColumnInfo {
    name: String,
    type_schema: String,
    type_name: String,
    is_primary_key: bool,
    is_nullable: bool,
    has_default: bool,
    is_generated: bool,
    is_identity_always: bool,
}

async fn load_mutation_target<C: GenericClient>(
    client: &C,
    schema: &str,
    table: &str,
) -> Result<(String, Vec<MutationColumnInfo>), LucidError> {
    let rel_row = client
        .query_opt(
            r#"
            SELECT c.relkind::text
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2
            "#,
            &[&schema, &table],
        )
        .await
        .map_err(map_postgres_error)?;

    let relkind: String = match rel_row {
        Some(r) => r.get(0),
        None => {
            return Err(LucidError::DatabaseError {
                code: "42P01".into(),
                message: format!("Table '{}.{}' does not exist.", schema, table),
                detail: None,
            });
        }
    };

    let rows = client
        .query(
            r#"
            SELECT
                a.attname AS column_name,
                tn.nspname AS type_schema,
                t.typname AS type_name,
                (pk.conkey IS NOT NULL AND a.attnum = ANY(pk.conkey)) AS is_pk,
                NOT a.attnotnull AS is_nullable,
                (a.atthasdef OR a.attidentity IN ('a', 'd') OR COALESCE(a.attgenerated, '') != '') AS has_default,
                COALESCE(a.attgenerated, '') != '' AS is_generated,
                a.attidentity = 'a' AS is_identity_always
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t ON t.oid = a.atttypid
            JOIN pg_namespace tn ON tn.oid = t.typnamespace
            LEFT JOIN pg_constraint pk ON pk.conrelid = c.oid AND pk.contype = 'p'
            WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum ASC
            "#,
            &[&schema, &table],
        )
        .await
        .map_err(map_postgres_error)?;

    let cols = rows
        .into_iter()
        .map(|row| MutationColumnInfo {
            name: row.get(0),
            type_schema: row.get(1),
            type_name: row.get(2),
            is_primary_key: row.get(3),
            is_nullable: row.get(4),
            has_default: row.get(5),
            is_generated: row.get(6),
            is_identity_always: row.get(7),
        })
        .collect();

    Ok((relkind, cols))
}

fn decode_returned_row(row: &Row) -> RowData {
    let mut cells = Vec::with_capacity(row.len());
    for i in 0..row.len() {
        cells.push(map_cell_value(row, i));
    }
    RowData { cells }
}

fn canonical_pk_key(
    pk_columns: &[String],
    pk_values: &[CellValue],
) -> Result<Vec<(String, Option<String>)>, LucidError> {
    let mut pairs = Vec::with_capacity(pk_columns.len());
    for (col, val) in pk_columns.iter().zip(pk_values.iter()) {
        let param = cell_value_to_param(val, "primary key")?;
        pairs.push((col.clone(), param));
    }
    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(pairs)
}

fn validate_pk_and_xmin(
    op_label: &str,
    row_num: usize,
    schema_name: &str,
    table_name: &str,
    pk_columns: &[String],
    pk_values: &[CellValue],
    original_xmin: &str,
    expected_pk_set: &HashSet<&str>,
    col_map: &HashMap<String, &MutationColumnInfo>,
) -> Result<(), LucidError> {
    if pk_columns.is_empty() || pk_columns.len() != pk_values.len() {
        return Err(LucidError::DatabaseError {
            code: "22023".into(),
            message: format!(
                "{} at row {} has invalid primary key columns ({}) or values ({}).",
                op_label,
                row_num,
                pk_columns.len(),
                pk_values.len()
            ),
            detail: None,
        });
    }

    let provided_pk_set: HashSet<&str> = pk_columns.iter().map(|s| s.as_str()).collect();
    if provided_pk_set != *expected_pk_set || provided_pk_set.len() != pk_columns.len() {
        return Err(LucidError::DatabaseError {
            code: "22023".into(),
            message: format!(
                "{} at row {} does not specify the complete primary key for '{}.{}'.",
                op_label, row_num, schema_name, table_name
            ),
            detail: None,
        });
    }

    if original_xmin.is_empty() || !original_xmin.bytes().all(|b| b.is_ascii_digit()) {
        return Err(LucidError::DatabaseError {
            code: "22023".into(),
            message: format!(
                "{} at row {} has a missing or invalid row version (xmin).",
                op_label, row_num
            ),
            detail: None,
        });
    }

    for (j, pk_name) in pk_columns.iter().enumerate() {
        if !col_map.contains_key(pk_name) {
            return Err(LucidError::DatabaseError {
                code: "42703".into(),
                message: format!("Primary key column '{}' not found in table.", pk_name),
                detail: None,
            });
        }
        if matches!(pk_values[j], CellValue::Null) {
            return Err(LucidError::DatabaseError {
                code: "22023".into(),
                message: format!("Primary key column '{}' cannot be NULL.", pk_name),
                detail: None,
            });
        }
        let _ = cell_value_to_param(&pk_values[j], "primary key")?;
    }

    Ok(())
}

fn append_pk_and_xmin_where(
    where_clauses: &mut Vec<String>,
    params_storage: &mut Vec<Option<String>>,
    pk_columns: &[String],
    pk_values: &[CellValue],
    original_xmin: &str,
    col_map: &HashMap<String, &MutationColumnInfo>,
) -> Result<(), LucidError> {
    let param_offset = params_storage.len();
    for (j, pk_name) in pk_columns.iter().enumerate() {
        let col_meta = col_map.get(pk_name).unwrap();
        let param = cell_value_to_param(&pk_values[j], "primary key")?;
        let clean_pk = sanitize_identifier(pk_name);
        let clean_type_schema = sanitize_identifier(&col_meta.type_schema);
        let clean_type_name = sanitize_identifier(&col_meta.type_name);
        let param_idx = param_offset + j + 1;
        where_clauses.push(format!(
            r#""{}" = CAST(${}::text AS "{}"."{}")"#,
            clean_pk, param_idx, clean_type_schema, clean_type_name
        ));
        params_storage.push(param);
    }

    let xmin_param_idx = params_storage.len() + 1;
    where_clauses.push(format!("xmin::text = ${}::text", xmin_param_idx));
    params_storage.push(Some(original_xmin.to_string()));
    Ok(())
}

async fn execute_delete(
    tx: &Transaction<'_>,
    schema_name: &str,
    table_name: &str,
    clean_schema: &str,
    clean_table: &str,
    delete_op: &RowDelete,
    col_map: &HashMap<String, &MutationColumnInfo>,
) -> Result<(), LucidError> {
    let mut where_clauses = Vec::new();
    let mut params_storage = Vec::new();
    append_pk_and_xmin_where(
        &mut where_clauses,
        &mut params_storage,
        &delete_op.primary_key_columns,
        &delete_op.primary_key_values,
        &delete_op.original_xmin,
        col_map,
    )?;

    let sql = format!(
        r#"DELETE FROM "{}"."{}" WHERE {} RETURNING 1;"#,
        clean_schema,
        clean_table,
        where_clauses.join(" AND ")
    );
    let params_refs: Vec<&(dyn ToSql + Sync)> =
        params_storage.iter().map(|p| p as &(dyn ToSql + Sync)).collect();

    let rows = tx.query(&sql, &params_refs).await.map_err(map_postgres_error)?;
    if rows.is_empty() {
        let pk_strs: Vec<String> = delete_op
            .primary_key_values
            .iter()
            .map(format_cell_value_for_display)
            .collect();
        return Err(LucidError::ConflictDetected {
            table_name: format!("{}.{}", schema_name, table_name),
            primary_key_values: pk_strs,
        });
    }
    Ok(())
}

async fn execute_update(
    tx: &Transaction<'_>,
    schema_name: &str,
    table_name: &str,
    clean_schema: &str,
    clean_table: &str,
    returning_clause: &str,
    mutation: &RowMutation,
    col_map: &HashMap<String, &MutationColumnInfo>,
) -> Result<(String, RowData), LucidError> {
    let mut set_clauses = Vec::new();
    let mut params_storage: Vec<Option<String>> = Vec::new();

    for (i, col_name) in mutation.updated_columns.iter().enumerate() {
        let col_meta = col_map.get(col_name).unwrap();
        let clean_col = sanitize_identifier(col_name);
        let clean_type_schema = sanitize_identifier(&col_meta.type_schema);
        let clean_type_name = sanitize_identifier(&col_meta.type_name);
        let param_idx = i + 1;
        set_clauses.push(format!(
            r#""{}" = CAST(${}::text AS "{}"."{}")"#,
            clean_col, param_idx, clean_type_schema, clean_type_name
        ));
        let param = cell_value_to_param(&mutation.updated_values[i], "column")?;
        params_storage.push(param);
    }

    let mut where_clauses = Vec::new();
    append_pk_and_xmin_where(
        &mut where_clauses,
        &mut params_storage,
        &mutation.primary_key_columns,
        &mutation.primary_key_values,
        &mutation.original_xmin,
        col_map,
    )?;

    let sql = format!(
        r#"UPDATE "{}"."{}" SET {} WHERE {} RETURNING {};"#,
        clean_schema,
        clean_table,
        set_clauses.join(", "),
        where_clauses.join(" AND "),
        returning_clause
    );
    let params_refs: Vec<&(dyn ToSql + Sync)> =
        params_storage.iter().map(|p| p as &(dyn ToSql + Sync)).collect();

    let rows = tx.query(&sql, &params_refs).await.map_err(map_postgres_error)?;
    if rows.is_empty() {
        let pk_strs: Vec<String> = mutation
            .primary_key_values
            .iter()
            .map(format_cell_value_for_display)
            .collect();
        return Err(LucidError::ConflictDetected {
            table_name: format!("{}.{}", schema_name, table_name),
            primary_key_values: pk_strs,
        });
    }

    let new_xmin: String = rows[0].get(0);
    let row_data = decode_returned_row(&rows[0]);
    Ok((new_xmin, row_data))
}

async fn execute_insert(
    tx: &Transaction<'_>,
    clean_schema: &str,
    clean_table: &str,
    returning_clause: &str,
    insert_op: &RowInsert,
    col_map: &HashMap<String, &MutationColumnInfo>,
) -> Result<InsertedRowResult, LucidError> {
    let row = if insert_op.columns.is_empty() {
        let sql = format!(
            r#"INSERT INTO "{}"."{}" DEFAULT VALUES RETURNING {};"#,
            clean_schema, clean_table, returning_clause
        );
        tx.query_one(&sql, &[]).await.map_err(map_postgres_error)?
    } else {
        let mut quoted_cols = Vec::with_capacity(insert_op.columns.len());
        let mut value_exprs = Vec::with_capacity(insert_op.columns.len());
        let mut params_storage: Vec<Option<String>> = Vec::with_capacity(insert_op.columns.len());

        for (i, col_name) in insert_op.columns.iter().enumerate() {
            let col_meta = col_map.get(col_name).unwrap();
            let clean_col = sanitize_identifier(col_name);
            let clean_type_schema = sanitize_identifier(&col_meta.type_schema);
            let clean_type_name = sanitize_identifier(&col_meta.type_name);
            quoted_cols.push(format!(r#""{}""#, clean_col));
            value_exprs.push(format!(
                r#"CAST(${}::text AS "{}"."{}")"#,
                i + 1,
                clean_type_schema,
                clean_type_name
            ));
            params_storage.push(cell_value_to_param(&insert_op.values[i], "insert column")?);
        }

        let sql = format!(
            r#"INSERT INTO "{}"."{}" ({}) VALUES ({}) RETURNING {};"#,
            clean_schema,
            clean_table,
            quoted_cols.join(", "),
            value_exprs.join(", "),
            returning_clause
        );
        let params_refs: Vec<&(dyn ToSql + Sync)> =
            params_storage.iter().map(|p| p as &(dyn ToSql + Sync)).collect();
        tx.query_one(&sql, &params_refs).await.map_err(map_postgres_error)?
    };

    Ok(InsertedRowResult {
        client_row_id: insert_op.client_row_id.clone(),
        row: decode_returned_row(&row),
    })
}

fn validate_batch_requests(
    req: &BatchMutationRequest,
    columns: &[MutationColumnInfo],
    col_map: &HashMap<String, &MutationColumnInfo>,
    expected_pk_set: &HashSet<&str>,
) -> Result<(), LucidError> {
    let mut delete_pks: HashSet<Vec<(String, Option<String>)>> = HashSet::new();
    for (idx, del) in req.deletes.iter().enumerate() {
        validate_pk_and_xmin(
            "Delete",
            idx + 1,
            &req.schema_name,
            &req.table_name,
            &del.primary_key_columns,
            &del.primary_key_values,
            &del.original_xmin,
            expected_pk_set,
            col_map,
        )?;
        let pk_key = canonical_pk_key(&del.primary_key_columns, &del.primary_key_values)?;
        if !delete_pks.insert(pk_key) {
            return Err(LucidError::DatabaseError {
                code: "22023".into(),
                message: format!(
                    "Delete at row {} duplicates another staged deletion for the same primary key.",
                    idx + 1
                ),
                detail: None,
            });
        }
    }

    let mut update_pks: HashSet<Vec<(String, Option<String>)>> = HashSet::new();
    for (idx, m) in req.mutations.iter().enumerate() {
        if m.updated_columns.is_empty() {
            continue;
        }
        if m.updated_columns.len() != m.updated_values.len() {
            return Err(LucidError::DatabaseError {
                code: "22023".into(),
                message: format!(
                    "Mutation at row {} has mismatched updated columns ({}) and values ({}).",
                    idx + 1,
                    m.updated_columns.len(),
                    m.updated_values.len()
                ),
                detail: None,
            });
        }
        validate_pk_and_xmin(
            "Mutation",
            idx + 1,
            &req.schema_name,
            &req.table_name,
            &m.primary_key_columns,
            &m.primary_key_values,
            &m.original_xmin,
            expected_pk_set,
            col_map,
        )?;

        let pk_key = canonical_pk_key(&m.primary_key_columns, &m.primary_key_values)?;
        if delete_pks.contains(&pk_key) {
            return Err(LucidError::DatabaseError {
                code: "22023".into(),
                message: format!(
                    "Row {} in '{}.{}' is staged for both update and deletion in the same batch. Undo one operation before applying.",
                    idx + 1,
                    req.schema_name,
                    req.table_name
                ),
                detail: None,
            });
        }
        if !update_pks.insert(pk_key) {
            return Err(LucidError::DatabaseError {
                code: "22023".into(),
                message: format!(
                    "Mutation at row {} duplicates another update for the same primary key in one batch.",
                    idx + 1
                ),
                detail: None,
            });
        }

        let mut seen_cols = HashSet::new();
        for (col_idx, col_name) in m.updated_columns.iter().enumerate() {
            if !seen_cols.insert(col_name.as_str()) {
                return Err(LucidError::DatabaseError {
                    code: "22023".into(),
                    message: format!("Duplicate column '{}' in row {} update.", col_name, idx + 1),
                    detail: None,
                });
            }
            if let Some(col_meta) = col_map.get(col_name) {
                if col_meta.is_generated {
                    return Err(LucidError::DatabaseError {
                        code: "428C9".into(),
                        message: format!(
                            "Column '{}' in table '{}.{}' is a generated column and cannot be edited.",
                            col_name, req.schema_name, req.table_name
                        ),
                        detail: None,
                    });
                }
                if col_meta.is_identity_always {
                    return Err(LucidError::DatabaseError {
                        code: "428C9".into(),
                        message: format!(
                            "Column '{}' in table '{}.{}' is GENERATED ALWAYS AS IDENTITY and cannot be assigned an explicit value.",
                            col_name, req.schema_name, req.table_name
                        ),
                        detail: None,
                    });
                }
            } else {
                return Err(LucidError::DatabaseError {
                    code: "42703".into(),
                    message: format!(
                        "Column '{}' does not exist in table '{}.{}'.",
                        col_name, req.schema_name, req.table_name
                    ),
                    detail: None,
                });
            }
            let _ = cell_value_to_param(&m.updated_values[col_idx], "column")?;
        }
    }

    for (idx, ins) in req.inserts.iter().enumerate() {
        if ins.columns.len() != ins.values.len() {
            return Err(LucidError::DatabaseError {
                code: "22023".into(),
                message: format!(
                    "Insert draft {} has mismatched columns ({}) and values ({}).",
                    idx + 1,
                    ins.columns.len(),
                    ins.values.len()
                ),
                detail: None,
            });
        }

        let mut supplied_cols = HashSet::new();
        for (col_idx, col_name) in ins.columns.iter().enumerate() {
            if !supplied_cols.insert(col_name.as_str()) {
                return Err(LucidError::DatabaseError {
                    code: "22023".into(),
                    message: format!("Duplicate column '{}' in insert draft {}.", col_name, idx + 1),
                    detail: None,
                });
            }
            if let Some(col_meta) = col_map.get(col_name) {
                if col_meta.is_generated {
                    return Err(LucidError::DatabaseError {
                        code: "428C9".into(),
                        message: format!(
                            "Column '{}' in '{}.{}' is a generated column; leave it DEFAULT on insert.",
                            col_name, req.schema_name, req.table_name
                        ),
                        detail: None,
                    });
                }
                if col_meta.is_identity_always {
                    return Err(LucidError::DatabaseError {
                        code: "428C9".into(),
                        message: format!(
                            "Column '{}' in '{}.{}' is GENERATED ALWAYS AS IDENTITY; leave it DEFAULT on insert.",
                            col_name, req.schema_name, req.table_name
                        ),
                        detail: None,
                    });
                }
            } else {
                return Err(LucidError::DatabaseError {
                    code: "42703".into(),
                    message: format!(
                        "Column '{}' does not exist in table '{}.{}'.",
                        col_name, req.schema_name, req.table_name
                    ),
                    detail: None,
                });
            }
            let _ = cell_value_to_param(&ins.values[col_idx], "insert column")?;
        }

        for col_meta in columns {
            if !col_meta.is_nullable
                && !col_meta.has_default
                && !supplied_cols.contains(col_meta.name.as_str())
            {
                return Err(LucidError::DatabaseError {
                    code: "23502".into(),
                    message: format!(
                        "Insert draft {}: column '{}' is NOT NULL and has no default value.",
                        idx + 1,
                        col_meta.name
                    ),
                    detail: None,
                });
            }
        }
    }

    Ok(())
}

pub async fn execute_batch_mutation(
    client: &mut Client,
    req: BatchMutationRequest,
) -> Result<BatchMutationResult, LucidError> {
    if is_system_schema(&req.schema_name) {
        return Err(LucidError::ReadOnlyViolation {
            attempted_operation: format!(
                "System schema '{}' is read-only; catalog tables cannot be edited.",
                req.schema_name
            ),
        });
    }

    let has_any_op =
        !req.deletes.is_empty() || !req.mutations.is_empty() || !req.inserts.is_empty();
    if !has_any_op {
        return Ok(BatchMutationResult {
            rows_affected: 0,
            updated_count: 0,
            inserted_count: 0,
            deleted_count: 0,
            updated_xmins: Vec::new(),
            updated_rows: Vec::new(),
            inserted_rows: Vec::new(),
        });
    }

    let tx = client.transaction().await.map_err(map_postgres_error)?;

    // 1. Inspect target relation and columns inside the isolated transaction
    let (relkind, columns) = load_mutation_target(&tx, &req.schema_name, &req.table_name).await?;
    if relkind != "r" && relkind != "p" {
        let _ = tx.rollback().await;
        return Err(LucidError::ReadOnlyViolation {
            attempted_operation: format!(
                "'{}.{}' is not an editable base table.",
                req.schema_name, req.table_name
            ),
        });
    }

    let col_map: HashMap<String, &MutationColumnInfo> =
        columns.iter().map(|c| (c.name.clone(), c)).collect();

    let pk_cols: Vec<String> = columns
        .iter()
        .filter(|c| c.is_primary_key)
        .map(|c| c.name.clone())
        .collect();

    if pk_cols.is_empty() {
        let _ = tx.rollback().await;
        return Err(LucidError::MissingPrimaryKey {
            table_name: format!("{}.{}", req.schema_name, req.table_name),
        });
    }

    let expected_pk_set: HashSet<&str> = pk_cols.iter().map(|s| s.as_str()).collect();
    if let Err(e) = validate_batch_requests(&req, &columns, &col_map, &expected_pk_set) {
        let _ = tx.rollback().await;
        return Err(e);
    }

    let clean_schema = sanitize_identifier(&req.schema_name);
    let clean_table = sanitize_identifier(&req.table_name);
    let returning_cols: Vec<String> = std::iter::once("xmin::text".to_string())
        .chain(
            columns
                .iter()
                .map(|c| format!(r#""{}""#, sanitize_identifier(&c.name))),
        )
        .collect();
    let returning_clause = returning_cols.join(", ");

    // Deterministic Phase 1: Deletes
    let mut deleted_count: u64 = 0;
    for delete_op in &req.deletes {
        if let Err(e) = execute_delete(
            &tx,
            &req.schema_name,
            &req.table_name,
            &clean_schema,
            &clean_table,
            delete_op,
            &col_map,
        )
        .await
        {
            let _ = tx.rollback().await;
            return Err(e);
        }
        deleted_count += 1;
    }

    // Deterministic Phase 2: Updates
    let mut updated_xmins = Vec::with_capacity(req.mutations.len());
    let mut updated_rows = Vec::with_capacity(req.mutations.len());
    for mutation in &req.mutations {
        if mutation.updated_columns.is_empty() {
            continue;
        }
        match execute_update(
            &tx,
            &req.schema_name,
            &req.table_name,
            &clean_schema,
            &clean_table,
            &returning_clause,
            mutation,
            &col_map,
        )
        .await
        {
            Ok((new_xmin, row_data)) => {
                updated_xmins.push(new_xmin);
                updated_rows.push(row_data);
            }
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(e);
            }
        }
    }

    // Deterministic Phase 3: Inserts
    let mut inserted_rows = Vec::with_capacity(req.inserts.len());
    for insert_op in &req.inserts {
        match execute_insert(
            &tx,
            &clean_schema,
            &clean_table,
            &returning_clause,
            insert_op,
            &col_map,
        )
        .await
        {
            Ok(res) => inserted_rows.push(res),
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(e);
            }
        }
    }

    // Never retry automatically after ambiguous commit failures.
    tx.commit().await.map_err(|e| LucidError::UncertainCommitOutcome {
        message: e.to_string(),
    })?;

    let updated_count = updated_rows.len() as u64;
    let inserted_count = inserted_rows.len() as u64;

    Ok(BatchMutationResult {
        rows_affected: deleted_count + updated_count + inserted_count,
        updated_count,
        inserted_count,
        deleted_count,
        updated_xmins,
        updated_rows,
        inserted_rows,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::ConnectionConfig;
    use crate::connection::ManagedPool;
    use crate::mutation::RowMutation;

    fn get_test_config() -> ConnectionConfig {
        let user = std::env::var("USER").unwrap_or_else(|_| "postgres".into());
        ConnectionConfig {
            host: "localhost".into(),
            port: 5432,
            database: "postgres".into(),
            user,
            password: None,
            ssl_mode: "disable".into(),
            timeout_seconds: 5,
        }
    }

    #[tokio::test]
    async fn test_batch_mutation_success_and_xmin() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        // 1. Setup disposable table with single PK
        let table_name = "test_mutate_single_pk";
        client
            .batch_execute(&format!(
                r#"
                DROP TABLE IF EXISTS "{}";
                CREATE TABLE "{}" (id serial PRIMARY KEY, name text, price numeric(10,2), note text);
                INSERT INTO "{}" (name, price, note) VALUES ('Apple', 1.50, 'fresh');
                "#,
                table_name, table_name, table_name
            ))
            .await
            .unwrap();

        // Fetch row and its xmin
        let row = client
            .query_one(&format!(r#"SELECT xmin::text, id, name, price, note FROM "{}""#, table_name), &[])
            .await
            .unwrap();
        let xmin: String = row.get(0);
        let id: i32 = row.get(1);

        // 2. Execute mutation: update price with exact decimal and note to empty string
        let req = BatchMutationRequest {
            schema_name: "public".into(),
            table_name: table_name.into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(id as i64)],
                original_xmin: xmin.clone(),
                updated_columns: vec!["price".into(), "note".into()],
                updated_values: vec![
                    CellValue::Decimal("1.99".into()),
                    CellValue::Text("".into()),
                ],
            }],
            inserts: vec![],
            deletes: vec![],
        };

        let res = execute_batch_mutation(&mut client, req).await.unwrap();
        assert_eq!(res.rows_affected, 1);
        assert!(!res.updated_xmins.is_empty());
        assert_ne!(res.updated_xmins[0], xmin);

        // Verify in DB
        let updated_row = client
            .query_one(&format!(r#"SELECT price::text, note FROM "{}" WHERE id = $1"#, table_name), &[&id])
            .await
            .unwrap();
        let updated_price: String = updated_row.get(0);
        let updated_note: String = updated_row.get(1);
        assert_eq!(updated_price, "1.99");
        assert_eq!(updated_note, "");

        // Cleanup
        let _ = client.batch_execute(&format!(r#"DROP TABLE IF EXISTS "{}";"#, table_name)).await;
    }

    #[tokio::test]
    async fn test_batch_mutation_composite_pk() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let table_name = "test_mutate_composite_pk";
        client
            .batch_execute(&format!(
                r#"
                DROP TABLE IF EXISTS "{}";
                CREATE TABLE "{}" (dept_id int, emp_id int, name text, PRIMARY KEY(dept_id, emp_id));
                INSERT INTO "{}" VALUES (10, 101, 'Alice');
                "#,
                table_name, table_name, table_name
            ))
            .await
            .unwrap();

        let row = client
            .query_one(&format!(r#"SELECT xmin::text FROM "{}" WHERE dept_id = 10 AND emp_id = 101"#, table_name), &[])
            .await
            .unwrap();
        let xmin: String = row.get(0);

        let req = BatchMutationRequest {
            schema_name: "public".into(),
            table_name: table_name.into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec!["dept_id".into(), "emp_id".into()],
                primary_key_values: vec![CellValue::Integer(10), CellValue::Integer(101)],
                original_xmin: xmin,
                updated_columns: vec!["name".into()],
                updated_values: vec![CellValue::Text("Alice Cooper".into())],
            }],
            inserts: vec![],
            deletes: vec![],
        };

        let res = execute_batch_mutation(&mut client, req).await.unwrap();
        assert_eq!(res.rows_affected, 1);

        // Cleanup
        let _ = client.batch_execute(&format!(r#"DROP TABLE IF EXISTS "{}";"#, table_name)).await;
    }

    #[tokio::test]
    async fn test_batch_mutation_conflict_detection() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let table_name = "test_mutate_conflict";
        client
            .batch_execute(&format!(
                r#"
                DROP TABLE IF EXISTS "{}";
                CREATE TABLE "{}" (id int PRIMARY KEY, val text);
                INSERT INTO "{}" VALUES (1, 'initial');
                "#,
                table_name, table_name, table_name
            ))
            .await
            .unwrap();

        // Mutate with wrong/stale xmin
        let req = BatchMutationRequest {
            schema_name: "public".into(),
            table_name: table_name.into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(1)],
                original_xmin: "9999999".into(),
                updated_columns: vec!["val".into()],
                updated_values: vec![CellValue::Text("stale edit".into())],
            }],
            inserts: vec![],
            deletes: vec![],
        };

        let res = execute_batch_mutation(&mut client, req).await;
        assert!(res.is_err());
        match res {
            Err(LucidError::ConflictDetected { primary_key_values, .. }) => {
                assert_eq!(primary_key_values, vec!["1"]);
            }
            _ => panic!("Expected ConflictDetected error"),
        }

        // Cleanup
        let _ = client.batch_execute(&format!(r#"DROP TABLE IF EXISTS "{}";"#, table_name)).await;
    }

    #[tokio::test]
    async fn test_batch_mutation_atomic_rollback() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let table_name = "test_mutate_atomic_rollback";
        client
            .batch_execute(&format!(
                r#"
                DROP TABLE IF EXISTS "{}";
                CREATE TABLE "{}" (id int PRIMARY KEY, val text);
                INSERT INTO "{}" VALUES (1, 'first'), (2, 'second');
                "#,
                table_name, table_name, table_name
            ))
            .await
            .unwrap();

        let r1 = client
            .query_one(&format!(r#"SELECT xmin::text FROM "{}" WHERE id = 1"#, table_name), &[])
            .await
            .unwrap();
        let xmin1: String = r1.get(0);

        // Row 1 has valid xmin, row 2 has invalid xmin
        let req = BatchMutationRequest {
            schema_name: "public".into(),
            table_name: table_name.into(),
            mutations: vec![
                RowMutation {
                    primary_key_columns: vec!["id".into()],
                    primary_key_values: vec![CellValue::Integer(1)],
                    original_xmin: xmin1,
                    updated_columns: vec!["val".into()],
                    updated_values: vec![CellValue::Text("first_updated".into())],
                },
                RowMutation {
                    primary_key_columns: vec!["id".into()],
                    primary_key_values: vec![CellValue::Integer(2)],
                    original_xmin: "12345678".into(), // invalid!
                    updated_columns: vec!["val".into()],
                    updated_values: vec![CellValue::Text("second_updated".into())],
                },
            ],
            inserts: vec![],
            deletes: vec![],
        };

        let res = execute_batch_mutation(&mut client, req).await;
        assert!(res.is_err());

        // Verify row 1 was NOT modified (atomic rollback preserved original state)
        let check = client
            .query_one(&format!(r#"SELECT val FROM "{}" WHERE id = 1"#, table_name), &[])
            .await
            .unwrap();
        let val: String = check.get(0);
        assert_eq!(val, "first");

        // Cleanup
        let _ = client.batch_execute(&format!(r#"DROP TABLE IF EXISTS "{}";"#, table_name)).await;
    }

    #[tokio::test]
    async fn test_batch_mutation_unsupported_table_without_pk() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let table_name = "test_mutate_no_pk";
        client
            .batch_execute(&format!(
                r#"
                DROP TABLE IF EXISTS "{}";
                CREATE TABLE "{}" (val text);
                INSERT INTO "{}" VALUES ('hello');
                "#,
                table_name, table_name, table_name
            ))
            .await
            .unwrap();

        let req = BatchMutationRequest {
            schema_name: "public".into(),
            table_name: table_name.into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec![],
                primary_key_values: vec![],
                original_xmin: "123".into(),
                updated_columns: vec!["val".into()],
                updated_values: vec![CellValue::Text("updated".into())],
            }],
            inserts: vec![],
            deletes: vec![],
        };

        let res = execute_batch_mutation(&mut client, req).await;
        assert!(res.is_err());
        match res {
            Err(LucidError::MissingPrimaryKey { .. }) => {}
            _ => panic!("Expected MissingPrimaryKey error"),
        }

        let _ = client.batch_execute(&format!(r#"DROP TABLE IF EXISTS "{}";"#, table_name)).await;
    }

    #[tokio::test]
    async fn test_batch_mutation_generated_column_rejected() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let table_name = "test_mutate_generated_col";
        client
            .batch_execute(&format!(
                r#"
                DROP TABLE IF EXISTS "{}";
                CREATE TABLE "{}" (id serial PRIMARY KEY, base_val int, gen_val int GENERATED ALWAYS AS (base_val * 2) STORED);
                INSERT INTO "{}" (base_val) VALUES (5);
                "#,
                table_name, table_name, table_name
            ))
            .await
            .unwrap();

        let row = client
            .query_one(&format!(r#"SELECT xmin::text FROM "{}""#, table_name), &[])
            .await
            .unwrap();
        let xmin: String = row.get(0);

        let req = BatchMutationRequest {
            schema_name: "public".into(),
            table_name: table_name.into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(1)],
                original_xmin: xmin,
                updated_columns: vec!["gen_val".into()],
                updated_values: vec![CellValue::Integer(99)],
            }],
            inserts: vec![],
            deletes: vec![],
        };

        let res = execute_batch_mutation(&mut client, req).await;
        assert!(res.is_err());
        match res {
            Err(LucidError::DatabaseError { code, message, .. }) => {
                assert_eq!(code, "428C9");
                assert!(message.contains("generated column"));
            }
            _ => panic!("Expected DatabaseError 428C9 for generated column"),
        }

        let _ = client.batch_execute(&format!(r#"DROP TABLE IF EXISTS "{}";"#, table_name)).await;
    }

    #[tokio::test]
    async fn test_batch_mutation_null_vs_empty_string() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let table_name = "test_mutate_null_vs_empty";
        client
            .batch_execute(&format!(
                r#"
                DROP TABLE IF EXISTS "{}";
                CREATE TABLE "{}" (id int PRIMARY KEY, col_null text, col_empty text);
                INSERT INTO "{}" VALUES (1, 'non_null', 'non_empty');
                "#,
                table_name, table_name, table_name
            ))
            .await
            .unwrap();

        let row = client
            .query_one(&format!(r#"SELECT xmin::text FROM "{}""#, table_name), &[])
            .await
            .unwrap();
        let xmin: String = row.get(0);

        let req = BatchMutationRequest {
            schema_name: "public".into(),
            table_name: table_name.into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(1)],
                original_xmin: xmin,
                updated_columns: vec!["col_null".into(), "col_empty".into()],
                updated_values: vec![CellValue::Null, CellValue::Text("".into())],
            }],
            inserts: vec![],
            deletes: vec![],
        };

        let res = execute_batch_mutation(&mut client, req).await.unwrap();
        assert_eq!(res.rows_affected, 1);

        let check = client
            .query_one(&format!(r#"SELECT col_null, col_empty FROM "{}" WHERE id = 1"#, table_name), &[])
            .await
            .unwrap();
        let null_val: Option<String> = check.get(0);
        let empty_val: Option<String> = check.get(1);

        assert_eq!(null_val, None);
        assert_eq!(empty_val, Some("".into()));

        let _ = client.batch_execute(&format!(r#"DROP TABLE IF EXISTS "{}";"#, table_name)).await;
    }

    #[tokio::test]
    async fn test_batch_mutation_rejects_system_schemas() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let req = BatchMutationRequest {
            schema_name: "pg_catalog".into(),
            table_name: "pg_am".into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec!["oid".into()],
                primary_key_values: vec![CellValue::Integer(403)],
                original_xmin: "1".into(),
                updated_columns: vec!["amname".into()],
                updated_values: vec![CellValue::Text("btree_hacked".into())],
            }],
            inserts: vec![],
            deletes: vec![],
        };

        let res = execute_batch_mutation(&mut client, req).await;
        assert!(matches!(res, Err(LucidError::ReadOnlyViolation { .. })));

        let info_req = BatchMutationRequest {
            schema_name: "information_schema".into(),
            table_name: "tables".into(),
            mutations: vec![],
            inserts: vec![RowInsert {
                client_row_id: "d1".into(),
                columns: vec![],
                values: vec![],
            }],
            deletes: vec![],
        };
        let info_res = execute_batch_mutation(&mut client, info_req).await;
        assert!(matches!(info_res, Err(LucidError::ReadOnlyViolation { .. })));
    }

    #[tokio::test]
    async fn test_batch_mutation_rejects_unsupported_pk_and_updated_values() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let schema = "test_lucid_unsupported_guard";
        let table = "items";
        client
            .batch_execute(&format!(
                r#"
                DROP SCHEMA IF EXISTS "{}" CASCADE;
                CREATE SCHEMA "{}";
                CREATE TABLE "{}"."{}" (id oid PRIMARY KEY, label text);
                INSERT INTO "{}"."{}" VALUES (403, 'original');
                "#,
                schema, schema, schema, table, schema, table
            ))
            .await
            .unwrap();

        let row = client
            .query_one(&format!(r#"SELECT xmin::text FROM "{}"."{}" WHERE id = 403"#, schema, table), &[])
            .await
            .unwrap();
        let xmin: String = row.get(0);

        // Unsupported PK placeholder must never reach SQL
        let bad_pk_req = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Unsupported("oid: raw display".into())],
                original_xmin: xmin.clone(),
                updated_columns: vec!["label".into()],
                updated_values: vec![CellValue::Text("changed".into())],
            }],
            inserts: vec![],
            deletes: vec![],
        };
        let bad_pk_res = execute_batch_mutation(&mut client, bad_pk_req).await;
        assert!(matches!(
            bad_pk_res,
            Err(LucidError::DatabaseError { ref code, ref message, .. })
                if code == "22023" && message.contains("unsupported primary key")
        ));

        // Unsupported updated value must never reach SQL
        let bad_val_req = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(403)],
                original_xmin: xmin,
                updated_columns: vec!["label".into()],
                updated_values: vec![CellValue::Unsupported("text: raw display".into())],
            }],
            inserts: vec![],
            deletes: vec![],
        };
        let bad_val_res = execute_batch_mutation(&mut client, bad_val_req).await;
        assert!(matches!(
            bad_val_res,
            Err(LucidError::DatabaseError { ref code, ref message, .. })
                if code == "22023" && message.contains("unsupported column")
        ));

        let _ = client
            .batch_execute(&format!(r#"DROP SCHEMA IF EXISTS "{}" CASCADE;"#, schema))
            .await;
    }

    #[tokio::test]
    async fn test_batch_mutation_custom_schema_composite_pk_high_precision_numeric() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let schema = "test_lucid_custom_schema";
        let table = "ledger";
        client
            .batch_execute(&format!(
                r#"
                DROP SCHEMA IF EXISTS "{}" CASCADE;
                CREATE SCHEMA "{}";
                CREATE TYPE "{}"."entry_kind" AS ENUM ('credit', 'debit');
                CREATE TABLE "{}"."{}" (
                    tenant_id int NOT NULL,
                    entry_id bigint NOT NULL,
                    amount numeric(24, 10) NOT NULL,
                    kind "{}"."entry_kind" NOT NULL,
                    memo text,
                    PRIMARY KEY (tenant_id, entry_id)
                );
                INSERT INTO "{}"."{}" VALUES (7, 9001, 123456789012.0000123456, 'credit', 'init');
                "#,
                schema, schema, schema, schema, table, schema, schema, table
            ))
            .await
            .unwrap();

        let page = crate::query::fetch_page(&client, schema, table, 0, 10, None, false, true)
            .await
            .unwrap();
        assert_eq!(page.rows.len(), 1);
        let xmin = match &page.rows[0].cells[0] {
            CellValue::Text(s) => s.clone(),
            other => panic!("Expected xmin Text, got {:?}", other),
        };
        assert_eq!(
            page.rows[0].cells[3],
            CellValue::Decimal("123456789012.0000123456".into())
        );
        assert_eq!(page.rows[0].cells[4], CellValue::Text("credit".into()));

        let req = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec!["tenant_id".into(), "entry_id".into()],
                primary_key_values: vec![CellValue::Integer(7), CellValue::Integer(9001)],
                original_xmin: xmin,
                updated_columns: vec!["amount".into(), "kind".into(), "memo".into()],
                updated_values: vec![
                    CellValue::Decimal("987654321098.9876543210".into()),
                    CellValue::Text("debit".into()),
                    CellValue::Null,
                ],
            }],
            inserts: vec![],
            deletes: vec![],
        };

        let res = execute_batch_mutation(&mut client, req).await.unwrap();
        assert_eq!(res.rows_affected, 1);

        let page_after = crate::query::fetch_page(&client, schema, table, 0, 10, None, false, true)
            .await
            .unwrap();
        assert_eq!(
            page_after.rows[0].cells[3],
            CellValue::Decimal("987654321098.9876543210".into())
        );
        assert_eq!(page_after.rows[0].cells[4], CellValue::Text("debit".into()));
        assert_eq!(page_after.rows[0].cells[5], CellValue::Null);

        let _ = client
            .batch_execute(&format!(r#"DROP SCHEMA IF EXISTS "{}" CASCADE;"#, schema))
            .await;
    }

    #[tokio::test]
    async fn test_batch_insert_defaults_identity_generated_null_and_empty() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let schema = "test_lucid_insert_defaults";
        let table = "items";
        client
            .batch_execute(&format!(
                r#"
                DROP SCHEMA IF EXISTS "{}" CASCADE;
                CREATE SCHEMA "{}";
                CREATE TABLE "{}"."{}" (
                    id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                    code text NOT NULL DEFAULT 'DEF-CODE',
                    note text DEFAULT 'def-note',
                    amount numeric(10, 2) NOT NULL DEFAULT 12.50,
                    doubled numeric(12, 2) GENERATED ALWAYS AS (amount * 2) STORED
                );
                "#,
                schema, schema, schema, table
            ))
            .await
            .unwrap();

        // Check schema introspection flags including is_identity and is_identity_always
        let cols = crate::schema::introspection::query_columns(&client, schema, table)
            .await
            .unwrap();
        assert!(cols[0].is_identity && cols[0].is_identity_always && cols[0].is_primary_key);
        assert_eq!(cols[1].default_value.as_deref(), Some("'DEF-CODE'::text"));
        assert!(cols[4].is_generated);

        // 1. Insert with DEFAULT VALUES (omits every column)
        // 2. Insert distinguishing DEFAULT (omit code), explicit NULL (note), empty string "" (on code -> second insert)
        let req = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            mutations: vec![],
            inserts: vec![
                RowInsert {
                    client_row_id: "draft-defaults".into(),
                    columns: vec![],
                    values: vec![],
                },
                RowInsert {
                    client_row_id: "draft-explicit".into(),
                    columns: vec!["code".into(), "note".into(), "amount".into()],
                    values: vec![
                        CellValue::Text("".into()),
                        CellValue::Null,
                        CellValue::Decimal("25.00".into()),
                    ],
                },
            ],
            deletes: vec![],
        };

        let res = execute_batch_mutation(&mut client, req).await.unwrap();
        assert_eq!(res.rows_affected, 2);
        assert_eq!(res.inserted_count, 2);
        assert_eq!(res.inserted_rows.len(), 2);

        // Returned row 1: id=1, code='DEF-CODE', note='def-note', amount=12.50, doubled=25.00
        let r1 = &res.inserted_rows[0];
        assert_eq!(r1.client_row_id, "draft-defaults");
        assert!(matches!(r1.row.cells[0], CellValue::Text(_))); // xmin
        assert_eq!(r1.row.cells[1], CellValue::Integer(1));
        assert_eq!(r1.row.cells[2], CellValue::Text("DEF-CODE".into()));
        assert_eq!(r1.row.cells[3], CellValue::Text("def-note".into()));
        assert_eq!(r1.row.cells[4], CellValue::Decimal("12.50".into()));
        assert_eq!(r1.row.cells[5], CellValue::Decimal("25.00".into()));

        // Returned row 2: id=2, code='', note=NULL (overrode default!), amount=25.00, doubled=50.00
        let r2 = &res.inserted_rows[1];
        assert_eq!(r2.client_row_id, "draft-explicit");
        assert_eq!(r2.row.cells[1], CellValue::Integer(2));
        assert_eq!(r2.row.cells[2], CellValue::Text("".into()));
        assert_eq!(r2.row.cells[3], CellValue::Null);
        assert_eq!(r2.row.cells[4], CellValue::Decimal("25.00".into()));
        assert_eq!(r2.row.cells[5], CellValue::Decimal("50.00".into()));

        // Explicitly supplying GENERATED ALWAYS AS IDENTITY fails cleanly with 428C9
        let bad_identity_req = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            mutations: vec![],
            inserts: vec![RowInsert {
                client_row_id: "bad-id".into(),
                columns: vec!["id".into()],
                values: vec![CellValue::Integer(99)],
            }],
            deletes: vec![],
        };
        let bad_id_res = execute_batch_mutation(&mut client, bad_identity_req).await;
        assert!(matches!(
            bad_id_res,
            Err(LucidError::DatabaseError { ref code, .. }) if code == "428C9"
        ));

        let _ = client
            .batch_execute(&format!(r#"DROP SCHEMA IF EXISTS "{}" CASCADE;"#, schema))
            .await;
    }

    #[tokio::test]
    async fn test_batch_insert_missing_not_null_and_identity_by_default() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let schema = "test_lucid_insert_validation";
        let table = "tasks";
        client
            .batch_execute(&format!(
                r#"
                DROP SCHEMA IF EXISTS "{}" CASCADE;
                CREATE SCHEMA "{}";
                CREATE TABLE "{}"."{}" (
                    id int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                    title text NOT NULL
                );
                "#,
                schema, schema, schema, table
            ))
            .await
            .unwrap();

        // Omitting required NOT NULL column `title` fails with 23502
        let missing_req = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            mutations: vec![],
            inserts: vec![RowInsert {
                client_row_id: "missing-title".into(),
                columns: vec![],
                values: vec![],
            }],
            deletes: vec![],
        };
        let err = execute_batch_mutation(&mut client, missing_req).await.unwrap_err();
        assert!(matches!(err, LucidError::DatabaseError { ref code, .. } if code == "23502"));

        // BY DEFAULT identity can be overridden explicitly
        let explicit_id_req = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            mutations: vec![],
            inserts: vec![RowInsert {
                client_row_id: "explicit-id".into(),
                columns: vec!["id".into(), "title".into()],
                values: vec![CellValue::Integer(500), CellValue::Text("Pinned ID".into())],
            }],
            deletes: vec![],
        };
        let res = execute_batch_mutation(&mut client, explicit_id_req).await.unwrap();
        assert_eq!(res.inserted_rows[0].row.cells[1], CellValue::Integer(500));

        let _ = client
            .batch_execute(&format!(r#"DROP SCHEMA IF EXISTS "{}" CASCADE;"#, schema))
            .await;
    }

    #[tokio::test]
    async fn test_batch_delete_success_and_xmin_conflict_rollback() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let schema = "test_lucid_delete";
        let table = "entries";
        client
            .batch_execute(&format!(
                r#"
                DROP SCHEMA IF EXISTS "{}" CASCADE;
                CREATE SCHEMA "{}";
                CREATE TABLE "{}"."{}" (id int PRIMARY KEY, name text NOT NULL);
                INSERT INTO "{}"."{}" VALUES (1, 'one'), (2, 'two');
                "#,
                schema, schema, schema, table, schema, table
            ))
            .await
            .unwrap();

        let r1 = client
            .query_one(&format!(r#"SELECT xmin::text FROM "{}"."{}" WHERE id = 1"#, schema, table), &[])
            .await
            .unwrap();
        let xmin1: String = r1.get(0);

        // Stale xmin delete on row 2 aborts earlier delete of row 1 cleanly
        let conflict_req = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            mutations: vec![],
            inserts: vec![],
            deletes: vec![
                RowDelete {
                    primary_key_columns: vec!["id".into()],
                    primary_key_values: vec![CellValue::Integer(1)],
                    original_xmin: xmin1.clone(),
                },
                RowDelete {
                    primary_key_columns: vec!["id".into()],
                    primary_key_values: vec![CellValue::Integer(2)],
                    original_xmin: "999999".into(),
                },
            ],
        };
        let err = execute_batch_mutation(&mut client, conflict_req).await.unwrap_err();
        assert!(matches!(err, LucidError::ConflictDetected { .. }));

        // Row 1 must still exist after rollback
        let count: i64 = client
            .query_one(&format!(r#"SELECT count(*) FROM "{}"."{}""#, schema, table), &[])
            .await
            .unwrap()
            .get(0);
        assert_eq!(count, 2);

        // Valid delete succeeds
        let ok_req = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            mutations: vec![],
            inserts: vec![],
            deletes: vec![RowDelete {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(1)],
                original_xmin: xmin1,
            }],
        };
        let res = execute_batch_mutation(&mut client, ok_req).await.unwrap();
        assert_eq!(res.deleted_count, 1);
        assert_eq!(res.rows_affected, 1);

        let count_after: i64 = client
            .query_one(&format!(r#"SELECT count(*) FROM "{}"."{}""#, schema, table), &[])
            .await
            .unwrap()
            .get(0);
        assert_eq!(count_after, 1);

        let _ = client
            .batch_execute(&format!(r#"DROP SCHEMA IF EXISTS "{}" CASCADE;"#, schema))
            .await;
    }

    #[tokio::test]
    async fn test_mixed_batch_ordering_and_constraint_rollback_and_conflict_rejection() {
        let config = get_test_config();
        let pool = ManagedPool::new(&config).unwrap();
        let mut client = pool.get().await.unwrap();

        let schema = "test_lucid_mixed_batch";
        let table = "users";
        client
            .batch_execute(&format!(
                r#"
                DROP SCHEMA IF EXISTS "{}" CASCADE;
                CREATE SCHEMA "{}";
                CREATE TABLE "{}"."{}" (
                    id int PRIMARY KEY,
                    email text NOT NULL UNIQUE
                );
                INSERT INTO "{}"."{}" VALUES (1, 'old@example.com'), (2, 'keep@example.com');
                "#,
                schema, schema, schema, table, schema, table
            ))
            .await
            .unwrap();

        let r1 = client
            .query_one(&format!(r#"SELECT xmin::text FROM "{}"."{}" WHERE id = 1"#, schema, table), &[])
            .await
            .unwrap();
        let r2 = client
            .query_one(&format!(r#"SELECT xmin::text FROM "{}"."{}" WHERE id = 2"#, schema, table), &[])
            .await
            .unwrap();
        let xmin1: String = r1.get(0);
        let xmin2: String = r2.get(0);

        // Conflicting update + delete targeting same PK 1 must be rejected cleanly without guessing
        let same_row_conflict = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            mutations: vec![RowMutation {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(1)],
                original_xmin: xmin1.clone(),
                updated_columns: vec!["email".into()],
                updated_values: vec![CellValue::Text("x@example.com".into())],
            }],
            inserts: vec![],
            deletes: vec![RowDelete {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(1)],
                original_xmin: xmin1.clone(),
            }],
        };
        let conflict_err = execute_batch_mutation(&mut client, same_row_conflict)
            .await
            .unwrap_err();
        assert!(matches!(
            conflict_err,
            LucidError::DatabaseError { ref code, ref message, .. }
                if code == "22023" && message.contains("both update and deletion")
        ));

        // Mixed batch constraint failure rolls back prior delete & update completely
        let failing_mixed = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            deletes: vec![RowDelete {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(1)],
                original_xmin: xmin1.clone(),
            }],
            mutations: vec![RowMutation {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(2)],
                original_xmin: xmin2.clone(),
                updated_columns: vec!["email".into()],
                updated_values: vec![CellValue::Text("updated@example.com".into())],
            }],
            inserts: vec![RowInsert {
                client_row_id: "dup-insert".into(),
                columns: vec!["id".into(), "email".into()],
                // Collides with row 2's updated email!
                values: vec![CellValue::Integer(3), CellValue::Text("updated@example.com".into())],
            }],
        };
        let rollback_err = execute_batch_mutation(&mut client, failing_mixed).await.unwrap_err();
        assert!(matches!(rollback_err, LucidError::DatabaseError { ref code, .. } if code == "23505"));

        // DB state untouched
        let rows_check = client
            .query(&format!(r#"SELECT id, email FROM "{}"."{}" ORDER BY id"#, schema, table), &[])
            .await
            .unwrap();
        assert_eq!(rows_check.len(), 2);
        assert_eq!(rows_check[1].get::<_, String>(1), "keep@example.com");

        // Mixed batch valid deterministic execution:
        // Phase 1 Delete id=1 frees 'old@example.com', Phase 2 Update id=2 -> 'mid@example.com',
        // Phase 3 Insert id=3 reuses 'old@example.com' cleanly!
        let valid_mixed = BatchMutationRequest {
            schema_name: schema.into(),
            table_name: table.into(),
            deletes: vec![RowDelete {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(1)],
                original_xmin: xmin1,
            }],
            mutations: vec![RowMutation {
                primary_key_columns: vec!["id".into()],
                primary_key_values: vec![CellValue::Integer(2)],
                original_xmin: xmin2,
                updated_columns: vec!["email".into()],
                updated_values: vec![CellValue::Text("mid@example.com".into())],
            }],
            inserts: vec![RowInsert {
                client_row_id: "reuse-email".into(),
                columns: vec!["id".into(), "email".into()],
                values: vec![CellValue::Integer(3), CellValue::Text("old@example.com".into())],
            }],
        };
        let ok_res = execute_batch_mutation(&mut client, valid_mixed).await.unwrap();
        assert_eq!(ok_res.deleted_count, 1);
        assert_eq!(ok_res.updated_count, 1);
        assert_eq!(ok_res.inserted_count, 1);
        assert_eq!(ok_res.rows_affected, 3);

        let final_rows = client
            .query(&format!(r#"SELECT id, email FROM "{}"."{}" ORDER BY id"#, schema, table), &[])
            .await
            .unwrap();
        assert_eq!(final_rows.len(), 2);
        assert_eq!(final_rows[0].get::<_, i32>(0), 2);
        assert_eq!(final_rows[0].get::<_, String>(1), "mid@example.com");
        assert_eq!(final_rows[1].get::<_, i32>(0), 3);
        assert_eq!(final_rows[1].get::<_, String>(1), "old@example.com");

        let _ = client
            .batch_execute(&format!(r#"DROP SCHEMA IF EXISTS "{}" CASCADE;"#, schema))
            .await;
    }
}
