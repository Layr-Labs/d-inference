//! Mirror the provider filter's top-level Python booleans/null and Swift-Jinja
//! Value.description fallback, including nullable schema type arrays.

use super::{BoundedWriter, Error, ErrorKind, MAX_RENDERED_BYTES, Value, ValueKind, number};
use std::io::Write;

pub(super) fn render(value: &Value) -> Result<String, Error> {
    let mut output = BoundedWriter::new(MAX_RENDERED_BYTES);
    write_value(&mut output, value, 0)?;
    output.into_string().map_err(|_| invalid())
}

fn invalid() -> Error {
    Error::new(
        ErrorKind::InvalidOperation,
        "unsupported Nemotron string value or output bound",
    )
}

fn write_value(output: &mut BoundedWriter, value: &Value, depth: usize) -> Result<(), Error> {
    if depth > 128 {
        return Err(invalid());
    }
    match value.kind() {
        ValueKind::Bool => {
            let text = match (depth == 0, value.is_true()) {
                (true, true) => "True",
                (true, false) => "False",
                (false, true) => "true",
                (false, false) => "false",
            };
            output.write_all(text.as_bytes()).map_err(|_| invalid())?;
        }
        ValueKind::None if depth == 0 => output.write_all(b"None").map_err(|_| invalid())?,
        ValueKind::None | ValueKind::Undefined => {}
        ValueKind::Number if !value.is_integer() => {
            let number = f64::try_from(value.clone())?;
            if !number.is_finite() {
                return Err(invalid());
            }
            output
                .write_all(number::swift_float(number).as_bytes())
                .map_err(|_| invalid())?;
        }
        ValueKind::Number | ValueKind::String => {
            write!(output, "{value}").map_err(|_| invalid())?;
        }
        ValueKind::Seq => {
            output.write_all(b"[").map_err(|_| invalid())?;
            for (index, item) in value.try_iter()?.enumerate() {
                if index > 0 {
                    output.write_all(b", ").map_err(|_| invalid())?;
                }
                let quoted = item.kind() == ValueKind::String;
                if quoted {
                    output.write_all(b"'").map_err(|_| invalid())?;
                }
                write_value(output, &item, depth + 1)?;
                if quoted {
                    output.write_all(b"'").map_err(|_| invalid())?;
                }
            }
            output.write_all(b"]").map_err(|_| invalid())?;
        }
        ValueKind::Map => {
            output.write_all(b"{").map_err(|_| invalid())?;
            for (index, key) in value.try_iter()?.enumerate() {
                if index > 0 {
                    output.write_all(b", ").map_err(|_| invalid())?;
                }
                write!(output, "{key}: ").map_err(|_| invalid())?;
                write_value(output, &value.get_item(&key)?, depth + 1)?;
            }
            output.write_all(b"}").map_err(|_| invalid())?;
        }
        _ => return Err(invalid()),
    }
    Ok(())
}
