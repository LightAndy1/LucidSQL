use super::CellValue;
use tokio_postgres::Row;
use tokio_postgres::types::Type;

pub fn map_cell_value(row: &Row, idx: usize) -> CellValue {
    let col = &row.columns()[idx];
    let col_type = col.type_();

    match *col_type {
        Type::BOOL => match row.try_get::<_, Option<bool>>(idx) {
            Ok(Some(v)) => CellValue::Boolean(v),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("bool conversion error".to_string()),
        },
        Type::INT2 => match row.try_get::<_, Option<i16>>(idx) {
            Ok(Some(v)) => CellValue::Integer(v as i64),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("int2 conversion error".to_string()),
        },
        Type::INT4 => match row.try_get::<_, Option<i32>>(idx) {
            Ok(Some(v)) => CellValue::Integer(v as i64),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("int4 conversion error".to_string()),
        },
        Type::INT8 => match row.try_get::<_, Option<i64>>(idx) {
            Ok(Some(v)) => CellValue::Integer(v),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("int8 conversion error".to_string()),
        },
        Type::FLOAT4 => match row.try_get::<_, Option<f32>>(idx) {
            Ok(Some(v)) => CellValue::Float(v as f64),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("float4 conversion error".to_string()),
        },
        Type::FLOAT8 => match row.try_get::<_, Option<f64>>(idx) {
            Ok(Some(v)) => CellValue::Float(v),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("float8 conversion error".to_string()),
        },
        Type::TEXT | Type::VARCHAR | Type::BPCHAR | Type::NAME => {
            match row.try_get::<_, Option<String>>(idx) {
                Ok(Some(v)) => CellValue::Text(v),
                Ok(None) => CellValue::Null,
                Err(_) => CellValue::Unsupported("text conversion error".to_string()),
            }
        }
        Type::UUID => match row.try_get::<_, Option<uuid::Uuid>>(idx) {
            Ok(Some(v)) => CellValue::Uuid(v.to_string()),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("uuid conversion error".to_string()),
        },
        Type::TIMESTAMPTZ => {
            match row.try_get::<_, Option<chrono::DateTime<chrono::Utc>>>(idx) {
                Ok(Some(v)) => CellValue::TimestampWithTimeZone(v.to_rfc3339()),
                Ok(None) => CellValue::Null,
                Err(_) => CellValue::Unsupported("timestamptz conversion error".to_string()),
            }
        }
        Type::TIMESTAMP => {
            match row.try_get::<_, Option<chrono::NaiveDateTime>>(idx) {
                Ok(Some(v)) => CellValue::TimestampWithoutTimeZone(v.to_string()),
                Ok(None) => CellValue::Null,
                Err(_) => CellValue::Unsupported("timestamp conversion error".to_string()),
            }
        }
        Type::DATE => match row.try_get::<_, Option<chrono::NaiveDate>>(idx) {
            Ok(Some(v)) => CellValue::Date(d_to_string(v)),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("date conversion error".to_string()),
        },
        Type::TIME => match row.try_get::<_, Option<chrono::NaiveTime>>(idx) {
            Ok(Some(v)) => CellValue::Time(v.to_string()),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("time conversion error".to_string()),
        },
        Type::BYTEA => match row.try_get::<_, Option<Vec<u8>>>(idx) {
            Ok(Some(v)) => {
                let hex_str: String = v.iter().map(|b| format!("{:02x}", b)).collect();
                CellValue::BinaryHex(format!("\\x{}", hex_str))
            }
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("bytea conversion error".to_string()),
        },
        Type::JSON | Type::JSONB => {
            match row.try_get::<_, Option<serde_json::Value>>(idx) {
                Ok(Some(v)) => CellValue::Json(v.to_string()),
                Ok(None) => CellValue::Null,
                Err(_) => CellValue::Unsupported("json conversion error".to_string()),
            }
        }
        _ => {
            if let Ok(Some(s)) = row.try_get::<_, Option<String>>(idx) {
                CellValue::Text(s)
            } else if let Ok(None) = row.try_get::<_, Option<String>>(idx) {
                CellValue::Null
            } else {
                CellValue::Unsupported(format!("{}: raw display", col_type.name()))
            }
        }
    }
}

fn d_to_string(d: chrono::NaiveDate) -> String {
    d.to_string()
}
