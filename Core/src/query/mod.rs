pub mod execute;
pub mod paged_table;
pub mod value_mapper;

pub use execute::{cancel_active_query, execute_sql, QueryResult};
pub use paged_table::fetch_page;
pub use value_mapper::map_cell_value;

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum CellValue {
    Null,
    Text(String),
    Boolean(bool),
    Integer(i64),
    Decimal(String),
    Float(f64),
    TimestampWithTimeZone(String),
    TimestampWithoutTimeZone(String),
    Date(String),
    Time(String),
    Uuid(String),
    BinaryHex(String),
    Json(String),
    Unsupported(String),
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct RowData {
    pub cells: Vec<CellValue>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct RecordPage {
    pub rows: Vec<RowData>,
    pub total_rows_fetched: u64,
    pub has_more: bool,
    pub execution_duration_ms: u64,
}
