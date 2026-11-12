use std::error::Error;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use tokio_postgres::types::{FromSql, Kind, Type};
use tokio_postgres::Row;

use super::CellValue;

struct PgNumeric(String);

impl<'a> FromSql<'a> for PgNumeric {
    fn from_sql(_: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        if raw.len() < 8 {
            return Err("invalid numeric binary header".into());
        }
        let ndigits = u16::from_be_bytes([raw[0], raw[1]]) as usize;
        let weight = i16::from_be_bytes([raw[2], raw[3]]) as i32;
        let sign = u16::from_be_bytes([raw[4], raw[5]]);
        let dscale = u16::from_be_bytes([raw[6], raw[7]]) as usize;

        if raw.len() < 8 + ndigits * 2 {
            return Err("truncated numeric binary payload".into());
        }

        match sign {
            0xC000 => return Ok(PgNumeric("NaN".to_string())),
            0xD000 => return Ok(PgNumeric("Infinity".to_string())),
            0xF000 => return Ok(PgNumeric("-Infinity".to_string())),
            0x0000 | 0x4000 => {}
            other => return Err(format!("unknown numeric sign: 0x{:04x}", other).into()),
        }

        let mut digits = Vec::with_capacity(ndigits);
        for i in 0..ndigits {
            let off = 8 + i * 2;
            digits.push(i16::from_be_bytes([raw[off], raw[off + 1]]));
        }

        let mut out = String::new();
        if sign == 0x4000 && !digits.is_empty() {
            out.push('-');
        }

        if weight < 0 || digits.is_empty() {
            out.push('0');
        } else {
            let mut started = false;
            for w in (0..=weight).rev() {
                let k = (weight - w) as usize;
                let d = if k < digits.len() { digits[k] } else { 0 };
                if !started {
                    if d != 0 || w == 0 {
                        out.push_str(&d.to_string());
                        started = true;
                    }
                } else {
                    out.push_str(&format!("{:04}", d));
                }
            }
            if !started {
                out.push('0');
            }
        }

        if dscale > 0 {
            out.push('.');
            let num_frac_groups = dscale.div_ceil(4);
            let mut frac = String::with_capacity(num_frac_groups * 4);
            for g in 0..num_frac_groups {
                let w = -1 - (g as i32);
                let k = weight - w;
                let d = if k >= 0 && (k as usize) < digits.len() {
                    digits[k as usize]
                } else {
                    0
                };
                frac.push_str(&format!("{:04}", d));
            }
            frac.truncate(dscale);
            out.push_str(&frac);
        }

        Ok(PgNumeric(out))
    }

    fn accepts(ty: &Type) -> bool {
        *ty == Type::NUMERIC
    }
}

struct PgU32(u32);

impl<'a> FromSql<'a> for PgU32 {
    fn from_sql(_: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        if raw.len() != 4 {
            return Err(format!("expected 4 bytes for oid-like type, got {}", raw.len()).into());
        }
        Ok(PgU32(u32::from_be_bytes([raw[0], raw[1], raw[2], raw[3]])))
    }

    fn accepts(ty: &Type) -> bool {
        matches!(
            *ty,
            Type::OID
                | Type::XID
                | Type::CID
                | Type::REGPROC
                | Type::REGPROCEDURE
                | Type::REGOPER
                | Type::REGOPERATOR
                | Type::REGCLASS
                | Type::REGTYPE
                | Type::REGCONFIG
                | Type::REGDICTIONARY
                | Type::REGNAMESPACE
                | Type::REGROLE
                | Type::REGCOLLATION
        )
    }
}

struct PgU64(u64);

impl<'a> FromSql<'a> for PgU64 {
    fn from_sql(_: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        if raw.len() != 8 {
            return Err(format!("expected 8 bytes for xid8, got {}", raw.len()).into());
        }
        Ok(PgU64(u64::from_be_bytes([
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
        ])))
    }

    fn accepts(ty: &Type) -> bool {
        ty.name() == "xid8"
    }
}

struct PgInet(String);

impl<'a> FromSql<'a> for PgInet {
    fn from_sql(_: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        if raw.len() < 4 {
            return Err("invalid inet/cidr payload".into());
        }
        let family = raw[0];
        let bits = raw[1];
        let is_cidr = raw[2] != 0;
        let len = raw[3] as usize;
        let addr_bytes = &raw[4..];
        if addr_bytes.len() != len {
            return Err("truncated inet/cidr address bytes".into());
        }

        let (ip, max_bits): (IpAddr, u8) = match (family, len) {
            (2, 4) => (
                IpAddr::V4(Ipv4Addr::new(
                    addr_bytes[0],
                    addr_bytes[1],
                    addr_bytes[2],
                    addr_bytes[3],
                )),
                32,
            ),
            (3, 16) => {
                let mut octets = [0u8; 16];
                octets.copy_from_slice(addr_bytes);
                (IpAddr::V6(Ipv6Addr::from(octets)), 128)
            }
            _ => return Err("unsupported inet address family".into()),
        };

        if is_cidr || bits < max_bits {
            Ok(PgInet(format!("{}/{}", ip, bits)))
        } else {
            Ok(PgInet(ip.to_string()))
        }
    }

    fn accepts(ty: &Type) -> bool {
        *ty == Type::INET || *ty == Type::CIDR
    }
}

struct PgMacAddr(String);

impl<'a> FromSql<'a> for PgMacAddr {
    fn from_sql(_: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        if raw.len() != 6 {
            return Err("expected 6 bytes for macaddr".into());
        }
        Ok(PgMacAddr(format!(
            "{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5]
        )))
    }

    fn accepts(ty: &Type) -> bool {
        *ty == Type::MACADDR
    }
}

struct PgEnumText(String);

impl<'a> FromSql<'a> for PgEnumText {
    fn from_sql(_: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        let s = std::str::from_utf8(raw)?;
        Ok(PgEnumText(s.to_string()))
    }

    fn accepts(ty: &Type) -> bool {
        matches!(ty.kind(), Kind::Enum(_))
    }
}

fn format_pg_array_element(s: &str) -> String {
    let needs_quotes = s.is_empty()
        || s.eq_ignore_ascii_case("NULL")
        || s.chars().any(|c| {
            c.is_whitespace() || matches!(c, '{' | '}' | ',' | '"' | '\\')
        });
    if !needs_quotes {
        return s.to_string();
    }
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{}\"", escaped)
}

fn format_array<T: ToString>(items: Vec<Option<T>>, quote_strings: bool) -> CellValue {
    let parts: Vec<String> = items
        .into_iter()
        .map(|opt| match opt {
            None => "NULL".to_string(),
            Some(v) => {
                let s = v.to_string();
                if quote_strings {
                    format_pg_array_element(&s)
                } else {
                    s
                }
            }
        })
        .collect();
    CellValue::Text(format!("{{{}}}", parts.join(",")))
}

pub fn map_cell_value(row: &Row, idx: usize) -> CellValue {
    let col = &row.columns()[idx];
    let col_type = col.type_();

    match *col_type {
        Type::BOOL => match row.try_get::<_, Option<bool>>(idx) {
            Ok(Some(v)) => CellValue::Boolean(v),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("bool decode error".to_string()),
        },
        Type::INT2 => match row.try_get::<_, Option<i16>>(idx) {
            Ok(Some(v)) => CellValue::Integer(v as i64),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("int2 decode error".to_string()),
        },
        Type::INT4 => match row.try_get::<_, Option<i32>>(idx) {
            Ok(Some(v)) => CellValue::Integer(v as i64),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("int4 decode error".to_string()),
        },
        Type::INT8 => match row.try_get::<_, Option<i64>>(idx) {
            Ok(Some(v)) => CellValue::Integer(v),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("int8 decode error".to_string()),
        },
        Type::OID
        | Type::XID
        | Type::CID
        | Type::REGPROC
        | Type::REGPROCEDURE
        | Type::REGOPER
        | Type::REGOPERATOR
        | Type::REGCLASS
        | Type::REGTYPE
        | Type::REGCONFIG
        | Type::REGDICTIONARY
        | Type::REGNAMESPACE
        | Type::REGROLE
        | Type::REGCOLLATION => match row.try_get::<_, Option<PgU32>>(idx) {
            Ok(Some(v)) => CellValue::Integer(v.0 as i64),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported(format!("{} decode error", col_type.name())),
        },
        Type::CHAR => match row.try_get::<_, Option<i8>>(idx) {
            Ok(Some(v)) => {
                let byte = v as u8;
                if byte == 0 {
                    CellValue::Text(String::new())
                } else {
                    CellValue::Text((byte as char).to_string())
                }
            }
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("char decode error".to_string()),
        },
        Type::NUMERIC => match row.try_get::<_, Option<PgNumeric>>(idx) {
            Ok(Some(v)) => CellValue::Decimal(v.0),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("numeric decode error".to_string()),
        },
        Type::FLOAT4 => match row.try_get::<_, Option<f32>>(idx) {
            Ok(Some(v)) => CellValue::Float(v as f64),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("float4 decode error".to_string()),
        },
        Type::FLOAT8 => match row.try_get::<_, Option<f64>>(idx) {
            Ok(Some(v)) => CellValue::Float(v),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("float8 decode error".to_string()),
        },
        Type::TEXT | Type::VARCHAR | Type::BPCHAR | Type::NAME => {
            match row.try_get::<_, Option<String>>(idx) {
                Ok(Some(v)) => CellValue::Text(v),
                Ok(None) => CellValue::Null,
                Err(_) => CellValue::Unsupported("text decode error".to_string()),
            }
        }
        Type::UUID => match row.try_get::<_, Option<uuid::Uuid>>(idx) {
            Ok(Some(v)) => CellValue::Uuid(v.to_string()),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("uuid decode error".to_string()),
        },
        Type::TIMESTAMPTZ => {
            match row.try_get::<_, Option<chrono::DateTime<chrono::Utc>>>(idx) {
                Ok(Some(v)) => CellValue::TimestampWithTimeZone(v.to_rfc3339()),
                Ok(None) => CellValue::Null,
                Err(_) => CellValue::Unsupported("timestamptz decode error".to_string()),
            }
        }
        Type::TIMESTAMP => {
            match row.try_get::<_, Option<chrono::NaiveDateTime>>(idx) {
                Ok(Some(v)) => CellValue::TimestampWithoutTimeZone(v.to_string()),
                Ok(None) => CellValue::Null,
                Err(_) => CellValue::Unsupported("timestamp decode error".to_string()),
            }
        }
        Type::DATE => match row.try_get::<_, Option<chrono::NaiveDate>>(idx) {
            Ok(Some(v)) => CellValue::Date(v.to_string()),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("date decode error".to_string()),
        },
        Type::TIME => match row.try_get::<_, Option<chrono::NaiveTime>>(idx) {
            Ok(Some(v)) => CellValue::Time(v.to_string()),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("time decode error".to_string()),
        },
        Type::BYTEA => match row.try_get::<_, Option<Vec<u8>>>(idx) {
            Ok(Some(v)) => {
                let hex_str: String = v.iter().map(|b| format!("{:02x}", b)).collect();
                CellValue::BinaryHex(format!("\\x{}", hex_str))
            }
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("bytea decode error".to_string()),
        },
        Type::JSON | Type::JSONB => {
            match row.try_get::<_, Option<serde_json::Value>>(idx) {
                Ok(Some(v)) => CellValue::Json(v.to_string()),
                Ok(None) => CellValue::Null,
                Err(_) => CellValue::Unsupported("json decode error".to_string()),
            }
        }
        Type::INET | Type::CIDR => match row.try_get::<_, Option<PgInet>>(idx) {
            Ok(Some(v)) => CellValue::Text(v.0),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported(format!("{} decode error", col_type.name())),
        },
        Type::MACADDR => match row.try_get::<_, Option<PgMacAddr>>(idx) {
            Ok(Some(v)) => CellValue::Text(v.0),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("macaddr decode error".to_string()),
        },
        Type::BOOL_ARRAY => match row.try_get::<_, Option<Vec<Option<bool>>>>(idx) {
            Ok(Some(v)) => format_array(v, false),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("_bool decode error".to_string()),
        },
        Type::INT2_ARRAY => match row.try_get::<_, Option<Vec<Option<i16>>>>(idx) {
            Ok(Some(v)) => format_array(v, false),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("_int2 decode error".to_string()),
        },
        Type::INT4_ARRAY => match row.try_get::<_, Option<Vec<Option<i32>>>>(idx) {
            Ok(Some(v)) => format_array(v, false),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("_int4 decode error".to_string()),
        },
        Type::INT8_ARRAY => match row.try_get::<_, Option<Vec<Option<i64>>>>(idx) {
            Ok(Some(v)) => format_array(v, false),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("_int8 decode error".to_string()),
        },
        Type::OID_ARRAY => match row.try_get::<_, Option<Vec<Option<u32>>>>(idx) {
            Ok(Some(v)) => format_array(v, false),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("_oid decode error".to_string()),
        },
        Type::FLOAT4_ARRAY => match row.try_get::<_, Option<Vec<Option<f32>>>>(idx) {
            Ok(Some(v)) => format_array(v, false),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("_float4 decode error".to_string()),
        },
        Type::FLOAT8_ARRAY => match row.try_get::<_, Option<Vec<Option<f64>>>>(idx) {
            Ok(Some(v)) => format_array(v, false),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("_float8 decode error".to_string()),
        },
        Type::TEXT_ARRAY | Type::VARCHAR_ARRAY | Type::BPCHAR_ARRAY | Type::NAME_ARRAY => {
            match row.try_get::<_, Option<Vec<Option<String>>>>(idx) {
                Ok(Some(v)) => format_array(v, true),
                Ok(None) => CellValue::Null,
                Err(_) => CellValue::Unsupported(format!("{} decode error", col_type.name())),
            }
        }
        Type::UUID_ARRAY => match row.try_get::<_, Option<Vec<Option<uuid::Uuid>>>>(idx) {
            Ok(Some(v)) => format_array(v, false),
            Ok(None) => CellValue::Null,
            Err(_) => CellValue::Unsupported("_uuid decode error".to_string()),
        },
        _ => {
            if col_type.name() == "xid8" {
                match row.try_get::<_, Option<PgU64>>(idx) {
                    Ok(Some(v)) => return CellValue::Text(v.0.to_string()),
                    Ok(None) => return CellValue::Null,
                    Err(_) => return CellValue::Unsupported("xid8 decode error".to_string()),
                }
            }
            if matches!(col_type.kind(), Kind::Enum(_)) {
                match row.try_get::<_, Option<PgEnumText>>(idx) {
                    Ok(Some(v)) => return CellValue::Text(v.0),
                    Ok(None) => return CellValue::Null,
                    Err(_) => return CellValue::Unsupported(format!("{} decode error", col_type.name())),
                }
            }
            if let Ok(Some(s)) = row.try_get::<_, Option<String>>(idx) {
                CellValue::Text(s)
            } else if let Ok(None) = row.try_get::<_, Option<String>>(idx) {
                CellValue::Null
            } else {
                CellValue::Unsupported(col_type.name().to_string())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::{ConnectionConfig, ManagedPool};

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
    async fn test_decode_numeric_oid_and_catalog_types() {
        let pool = ManagedPool::new(&get_test_config()).unwrap();
        let client = pool.get().await.unwrap();

        let row = client
            .query_one(
                "SELECT
                    0::numeric(10,2),
                    0.00::numeric(10,2),
                    0.0042::numeric(10,4),
                    0.000042::numeric(10,6),
                    -123456789012345678901234567890.1234567890::numeric,
                    12.5000::numeric(12,4),
                    'NaN'::numeric,
                    403::oid,
                    'i'::\"char\",
                    '127.0.0.1'::inet,
                    '10.0.0.0/8'::cidr,
                    'aa:bb:cc:dd:ee:ff'::macaddr",
                &[],
            )
            .await
            .unwrap();

        assert_eq!(map_cell_value(&row, 0), CellValue::Decimal("0.00".into()));
        assert_eq!(map_cell_value(&row, 1), CellValue::Decimal("0.00".into()));
        assert_eq!(map_cell_value(&row, 2), CellValue::Decimal("0.0042".into()));
        assert_eq!(map_cell_value(&row, 3), CellValue::Decimal("0.000042".into()));
        assert_eq!(
            map_cell_value(&row, 4),
            CellValue::Decimal("-123456789012345678901234567890.1234567890".into())
        );
        assert_eq!(map_cell_value(&row, 5), CellValue::Decimal("12.5000".into()));
        assert_eq!(map_cell_value(&row, 6), CellValue::Decimal("NaN".into()));
        assert_eq!(map_cell_value(&row, 7), CellValue::Integer(403));
        assert_eq!(map_cell_value(&row, 8), CellValue::Text("i".into()));
        assert_eq!(map_cell_value(&row, 9), CellValue::Text("127.0.0.1".into()));
        assert_eq!(map_cell_value(&row, 10), CellValue::Text("10.0.0.0/8".into()));
        assert_eq!(
            map_cell_value(&row, 11),
            CellValue::Text("aa:bb:cc:dd:ee:ff".into())
        );
    }

    #[tokio::test]
    async fn test_decode_pg_catalog_pg_am_without_placeholders() {
        let pool = ManagedPool::new(&get_test_config()).unwrap();
        let client = pool.get().await.unwrap();

        let page = crate::query::fetch_page(&client, "pg_catalog", "pg_am", 0, 10, None, false, true)
            .await
            .unwrap();

        assert!(!page.rows.is_empty());
        for row in &page.rows {
            // cells: [xmin, oid, amname, amhandler, amtype]
            assert!(matches!(row.cells[0], CellValue::Text(_)));
            assert!(matches!(row.cells[1], CellValue::Integer(_)));
            assert!(matches!(row.cells[2], CellValue::Text(_)));
            assert!(matches!(row.cells[3], CellValue::Integer(_)));
            assert!(matches!(row.cells[4], CellValue::Text(_)));
        }
    }

    #[tokio::test]
    async fn test_unsupported_type_returns_type_name_without_raw_display_placeholder() {
        let pool = ManagedPool::new(&get_test_config()).unwrap();
        let client = pool.get().await.unwrap();

        let row = client
            .query_one("SELECT '1 2 3'::int2vector", &[])
            .await
            .unwrap();

        assert_eq!(
            map_cell_value(&row, 0),
            CellValue::Unsupported("int2vector".into())
        );
    }
}
