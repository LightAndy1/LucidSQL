pub mod batch_update;

pub use batch_update::execute_batch_mutation;

use crate::query::{CellValue, RowData};

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct RowMutation {
    pub primary_key_columns: Vec<String>,
    pub primary_key_values: Vec<CellValue>,
    pub original_xmin: String,
    pub updated_columns: Vec<String>,
    pub updated_values: Vec<CellValue>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct RowInsert {
    pub client_row_id: String,
    /// Explicitly supplied column names. Columns omitted here use server DEFAULT / IDENTITY / GENERATED values.
    pub columns: Vec<String>,
    /// Typed values parallel to `columns` (supports explicit `CellValue::Null`, empty string `CellValue::Text("")`, etc.).
    pub values: Vec<CellValue>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct RowDelete {
    pub primary_key_columns: Vec<String>,
    pub primary_key_values: Vec<CellValue>,
    pub original_xmin: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct BatchMutationRequest {
    pub schema_name: String,
    pub table_name: String,
    pub mutations: Vec<RowMutation>,
    pub inserts: Vec<RowInsert>,
    pub deletes: Vec<RowDelete>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct InsertedRowResult {
    pub client_row_id: String,
    pub row: RowData,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct BatchMutationResult {
    pub rows_affected: u64,
    pub updated_count: u64,
    pub inserted_count: u64,
    pub deleted_count: u64,
    pub updated_xmins: Vec<String>,
    pub updated_rows: Vec<RowData>,
    pub inserted_rows: Vec<InsertedRowResult>,
}
