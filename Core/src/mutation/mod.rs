pub mod batch_update;

pub use batch_update::execute_batch_mutation;

use crate::query::CellValue;

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct RowMutation {
    pub primary_key_columns: Vec<String>,
    pub primary_key_values: Vec<CellValue>,
    pub original_xmin: String,
    pub updated_columns: Vec<String>,
    pub updated_values: Vec<CellValue>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct BatchMutationRequest {
    pub schema_name: String,
    pub table_name: String,
    pub mutations: Vec<RowMutation>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct BatchMutationResult {
    pub rows_affected: u64,
    pub updated_xmins: Vec<String>,
}
