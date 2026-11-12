use std::collections::HashMap;
use deadpool_postgres::Client;
use tokio_postgres::types::ToSql;

use crate::error::LucidError;
use crate::mutation::{BatchMutationRequest, BatchMutationResult};
use crate::query::execute::map_postgres_error;
use crate::query::CellValue;
use crate::schema::introspection::query_columns;

fn sanitize_identifier(ident: &str) -> String {
    ident.replace('"', "\"\"")
}

fn cell_value_to_param(val: &CellValue) -> Option<String> {
    match val {
        CellValue::Null => None,
        CellValue::Text(s) => Some(s.clone()),
        CellValue::Boolean(b) => Some(b.to_string()),
        CellValue::Integer(i) => Some(i.to_string()),
        CellValue::Decimal(s) => Some(s.clone()),
        CellValue::Float(f) => Some(f.to_string()),
        CellValue::TimestampWithTimeZone(s) => Some(s.clone()),
        CellValue::TimestampWithoutTimeZone(s) => Some(s.clone()),
        CellValue::Date(s) => Some(s.clone()),
        CellValue::Time(s) => Some(s.clone()),
        CellValue::Uuid(s) => Some(s.clone()),
        CellValue::BinaryHex(s) => Some(s.clone()),
        CellValue::Json(s) => Some(s.clone()),
        CellValue::Unsupported(s) => Some(s.clone()),
    }
}

pub async fn execute_batch_mutation(
    client: &mut Client,
    req: BatchMutationRequest,
) -> Result<BatchMutationResult, LucidError> {
    if req.mutations.is_empty() {
        return Ok(BatchMutationResult {
            rows_affected: 0,
            updated_xmins: Vec::new(),
        });
    }

    let tx = client.transaction().await.map_err(map_postgres_error)?;

    // 1. Inspect table columns inside the transaction
    let columns = query_columns(&tx, &req.schema_name, &req.table_name).await?;
    let col_map: HashMap<String, &crate::schema::ColumnMetadata> =
        columns.iter().map(|c| (c.name.clone(), c)).collect();

    let pk_cols: Vec<String> = columns
        .iter()
        .filter(|c| c.is_primary_key)
        .map(|c| c.name.clone())
        .collect();

    if pk_cols.is_empty() {
        return Err(LucidError::MissingPrimaryKey {
            table_name: format!("{}.{}", req.schema_name, req.table_name),
        });
    }

    let clean_schema = sanitize_identifier(&req.schema_name);
    let clean_table = sanitize_identifier(&req.table_name);
    let mut updated_xmins = Vec::with_capacity(req.mutations.len());

    for (idx, m) in req.mutations.iter().enumerate() {
        if m.updated_columns.is_empty() {
            continue;
        }

        if m.updated_columns.len() != m.updated_values.len() {
            return Err(LucidError::DatabaseError {
                code: "22023".into(),
                message: format!(
                    "Mutation at row {} has mismatched updated columns ({}) and values ({})",
                    idx + 1,
                    m.updated_columns.len(),
                    m.updated_values.len()
                ),
                detail: None,
            });
        }

        if m.primary_key_columns.len() != m.primary_key_values.len() {
            return Err(LucidError::DatabaseError {
                code: "22023".into(),
                message: format!(
                    "Mutation at row {} has mismatched primary key columns ({}) and values ({})",
                    idx + 1,
                    m.primary_key_columns.len(),
                    m.primary_key_values.len()
                ),
                detail: None,
            });
        }

        // Verify none of updated columns are generated or PK
        for col_name in &m.updated_columns {
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
        }

        // Build SET clauses
        let mut set_clauses = Vec::new();
        let mut params_storage: Vec<Option<String>> = Vec::new();

        for (i, col_name) in m.updated_columns.iter().enumerate() {
            let col_meta = col_map.get(col_name).unwrap();
            let clean_col = sanitize_identifier(col_name);
            let param_idx = i + 1;
            set_clauses.push(format!(
                r#""{}" = CAST(${}::text AS "{}")"#,
                clean_col, param_idx, col_meta.pg_type_name
            ));
            params_storage.push(cell_value_to_param(&m.updated_values[i]));
        }

        // Build WHERE clauses for primary keys
        let param_offset = m.updated_columns.len();
        let mut where_clauses = Vec::new();

        for (j, pk_name) in m.primary_key_columns.iter().enumerate() {
            let col_meta = col_map.get(pk_name).ok_or_else(|| LucidError::DatabaseError {
                code: "42703".into(),
                message: format!("Primary key column '{}' not found in table", pk_name),
                detail: None,
            })?;
            let clean_pk = sanitize_identifier(pk_name);
            let param_idx = param_offset + j + 1;
            where_clauses.push(format!(
                r#""{}" = CAST(${}::text AS "{}")"#,
                clean_pk, param_idx, col_meta.pg_type_name
            ));
            params_storage.push(cell_value_to_param(&m.primary_key_values[j]));
        }

        // Concurrency xmin check
        let xmin_param_idx = param_offset + m.primary_key_columns.len() + 1;
        where_clauses.push(format!("xmin::text = ${}::text", xmin_param_idx));
        params_storage.push(Some(m.original_xmin.clone()));

        let sql = format!(
            r#"UPDATE "{}"."{}" SET {} WHERE {} RETURNING xmin::text;"#,
            clean_schema,
            clean_table,
            set_clauses.join(", "),
            where_clauses.join(" AND ")
        );

        let params_refs: Vec<&(dyn ToSql + Sync)> = params_storage
            .iter()
            .map(|p| p as &(dyn ToSql + Sync))
            .collect();

        let rows = tx.query(&sql, &params_refs).await.map_err(|e| {
            map_postgres_error(e)
        })?;

        if rows.is_empty() {
            // Concurrent modification conflict detected!
            let _ = tx.rollback().await;
            let pk_strs: Vec<String> = m
                .primary_key_values
                .iter()
                .map(|v| match v {
                    CellValue::Null => "NULL".into(),
                    CellValue::Text(s) => format!("'{}'", s),
                    CellValue::Integer(i) => i.to_string(),
                    CellValue::Decimal(s) => s.clone(),
                    CellValue::Boolean(b) => b.to_string(),
                    _ => format!("{:?}", v),
                })
                .collect();

            return Err(LucidError::ConflictDetected {
                table_name: format!("{}.{}", req.schema_name, req.table_name),
                primary_key_values: pk_strs,
            });
        }

        let new_xmin: String = rows[0].get(0);
        updated_xmins.push(new_xmin);
    }

    tx.commit().await.map_err(|e| LucidError::UncertainCommitOutcome {
        message: e.to_string(),
    })?;

    Ok(BatchMutationResult {
        rows_affected: updated_xmins.len() as u64,
        updated_xmins,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::ConnectionConfig;
    use crate::connection::ManagedPool;

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
}
