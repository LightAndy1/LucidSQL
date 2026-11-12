pub mod introspection;
pub use introspection::*;

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct TableInfo {
    pub schema_name: String,
    pub table_name: String,
    pub is_view: bool,
    pub estimated_row_count: i64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ColumnMetadata {
    pub name: String,
    pub ordinal_position: u32,
    pub pg_type_name: String,
    pub pg_type_oid: u32,
    pub is_primary_key: bool,
    pub is_nullable: bool,
    pub default_value: Option<String>,
}
