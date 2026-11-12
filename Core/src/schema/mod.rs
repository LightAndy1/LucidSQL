pub mod introspection;
pub use introspection::*;

/// Returns true for PostgreSQL system/internal schemas that must be treated as read-only.
pub fn is_system_schema(schema: &str) -> bool {
    let lower = schema.trim().to_ascii_lowercase();
    lower == "pg_catalog" || lower == "information_schema" || lower.starts_with("pg_")
}

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
    pub is_generated: bool,
    pub is_identity: bool,
    pub is_identity_always: bool,
}
