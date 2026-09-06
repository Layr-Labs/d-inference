//! Swift-Jinja 2.3.6's tojson contract: Foundation JSONEncoder.sortedKeys,
//! fixed two-space pretty printing, slash escaping and optional UTF-16 escapes.
//! MiniJinja has no JSON dump policy and its built-in HTML-safe filter differs.
//! Keep this local to serialization; map iteration elsewhere remains unchanged.

use super::{BoundedWriter, MAX_RENDERED_BYTES};
use minijinja::value::{Kwargs, Rest, ValueKind, from_args};
use minijinja::{Error, ErrorKind, Value as JinjaValue};
use std::io::{self, Write};

pub(super) fn tojson(value: JinjaValue, args: Rest<JinjaValue>) -> Result<JinjaValue, Error> {
    let (positional, kwargs): (&[JinjaValue], Kwargs) = from_args(&args)?;
    let indent = argument(positional, &kwargs, 0, "indent")?;
    let ensure_ascii = argument(positional, &kwargs, 1, "ensure_ascii")?;
    kwargs.assert_all_used()?;
    // Swift only recognizes its integer case, not a bool or an integral Double.
    let pretty = indent.is_some_and(|v| v.is_integer() && v.as_i64().is_some_and(|n| n > 0));
    let ascii = ensure_ascii.is_none_or(|v| v.is_true());
    let mut output = BoundedWriter::new(MAX_RENDERED_BYTES);
    match write_value(&value, &mut output, pretty, ascii, 0) {
        // JSONEncoder refuses the complete value when any nested number is
        // nonfinite or a member cannot encode; Swift's filter then emits null.
        Err(WriteError::UnsupportedValue) => return Ok(JinjaValue::from("null")),
        Err(error) => return Err(json_error(error)),
        Ok(()) => {}
    }
    output
        .into_string()
        .map(JinjaValue::from)
        .map_err(json_error)
}

fn argument(
    positional: &[JinjaValue],
    kwargs: &Kwargs,
    index: usize,
    name: &str,
) -> Result<Option<JinjaValue>, Error> {
    // Option<Value> treats explicit none/undefined as absent in MiniJinja.
    // Swift distinguishes omission from a supplied false-like value.
    let keyword = if kwargs.has(name) {
        Some(kwargs.get::<JinjaValue>(name)?)
    } else {
        None
    };
    match (positional.get(index), keyword) {
        (Some(_), Some(_)) => Err(Error::new(
            ErrorKind::TooManyArguments,
            "duplicate tojson argument",
        )),
        (Some(value), None) => Ok(Some(value.clone())),
        (None, value) => Ok(value),
    }
}

fn json_error(error: impl std::fmt::Display) -> Error {
    Error::new(
        ErrorKind::InvalidOperation,
        format!("cannot serialize prompt JSON: {error}"),
    )
}

fn newline(output: &mut BoundedWriter, depth: usize) -> io::Result<()> {
    output.write_all(b"\n")?;
    for _ in 0..depth {
        output.write_all(b"  ")?;
    }
    Ok(())
}

#[derive(Debug, thiserror::Error)]
enum WriteError {
    #[error("value is not JSON encodable")]
    UnsupportedValue,
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Template(#[from] Error),
}

fn write_value(
    value: &JinjaValue,
    output: &mut BoundedWriter,
    pretty: bool,
    ascii: bool,
    depth: usize,
) -> Result<(), WriteError> {
    if depth > 128 {
        return Err(io::Error::other("prompt JSON nesting exceeds bound").into());
    }
    match value.kind() {
        ValueKind::None | ValueKind::Undefined => output.write_all(b"null")?,
        ValueKind::Bool => output.write_all(if value.is_true() { b"true" } else { b"false" })?,
        ValueKind::Number => {
            if value.is_integer() {
                write!(output, "{value}")?;
            } else {
                let number = f64::try_from(value.clone())?;
                if !number.is_finite() {
                    return Err(WriteError::UnsupportedValue);
                }
                write!(output, "{}", foundation_float(number))?;
            }
        }
        ValueKind::String => write_string(value.as_str().unwrap(), output, ascii)?,
        ValueKind::Seq | ValueKind::Iterable => {
            output.write_all(b"[")?;
            if pretty {
                output.write_all(b"\n")?;
            }
            for (index, value) in value.try_iter()?.enumerate() {
                item_start(output, pretty, depth, index)?;
                write_value(&value, output, pretty, ascii, depth + 1)?;
            }
            if pretty {
                newline(output, depth)?;
            }
            output.write_all(b"]")?;
        }
        ValueKind::Map => write_object(value, output, pretty, ascii, depth)?,
        _ => return Err(WriteError::UnsupportedValue),
    }
    Ok(())
}

fn item_start(
    output: &mut BoundedWriter,
    pretty: bool,
    depth: usize,
    index: usize,
) -> io::Result<()> {
    if index > 0 {
        output.write_all(b",")?;
        if pretty {
            output.write_all(b"\n")?;
        }
    }
    if pretty {
        for _ in 0..=depth {
            output.write_all(b"  ")?;
        }
    }
    Ok(())
}

fn write_object(
    value: &JinjaValue,
    output: &mut BoundedWriter,
    pretty: bool,
    ascii: bool,
    depth: usize,
) -> Result<(), WriteError> {
    let count = value.len().ok_or(WriteError::UnsupportedValue)?;
    // Only keys are collected; no second JSON tree/string is materialized.
    // Charge the temporary sort vector against the same bound as the output,
    // including nested objects' still-live vectors. A huge indent never allocates.
    let previous_limit = output.limit;
    let limit = count
        .checked_mul(std::mem::size_of::<JinjaValue>())
        .and_then(|bytes| previous_limit.checked_sub(bytes))
        .filter(|limit| *limit >= output.bytes.capacity());
    let Some(limit) = limit else {
        output.exceeded = true;
        return Err(io::Error::other("prompt JSON sort memory exceeds bound").into());
    };
    output.limit = limit;
    let result = (|| {
        let mut keys = Vec::with_capacity(count);
        for key in value.try_iter()? {
            if key.as_str().is_none() || keys.len() == count {
                return Err(WriteError::UnsupportedValue);
            }
            keys.push(key);
        }
        // Foundation sorts scalar strings, not UTF-16 units or locale collation.
        keys.sort_unstable_by(|left, right| left.as_str().cmp(&right.as_str()));
        output.write_all(b"{")?;
        if pretty {
            output.write_all(b"\n")?;
        }
        for (index, key) in keys.iter().enumerate() {
            item_start(output, pretty, depth, index)?;
            write_string(key.as_str().unwrap(), output, ascii)?;
            output.write_all(if pretty { b" : " } else { b":" })?;
            write_value(&value.get_item(key)?, output, pretty, ascii, depth + 1)?;
        }
        if pretty {
            newline(output, depth)?;
        }
        output.write_all(b"}")?;
        Ok(())
    })();
    output.limit = previous_limit;
    result
}

fn write_string(value: &str, output: &mut BoundedWriter, ascii: bool) -> io::Result<()> {
    output.write_all(b"\"")?;
    for ch in value.chars() {
        match ch {
            '"' => output.write_all(b"\\\"")?,
            '\\' => output.write_all(b"\\\\")?,
            '/' => output.write_all(b"\\/")?,
            '\u{8}' => output.write_all(b"\\b")?,
            '\u{c}' => output.write_all(b"\\f")?,
            '\n' => output.write_all(b"\\n")?,
            '\r' => output.write_all(b"\\r")?,
            '\t' => output.write_all(b"\\t")?,
            ch if ch < '\u{20}' || (ascii && !ch.is_ascii()) => {
                let mut units = [0; 2];
                for unit in ch.encode_utf16(&mut units) {
                    write!(output, "\\u{unit:04x}")?;
                }
            }
            ch => {
                let mut bytes = [0; 4];
                output.write_all(ch.encode_utf8(&mut bytes).as_bytes())?;
            }
        }
    }
    output.write_all(b"\"")
}

fn foundation_float(value: f64) -> String {
    // Both runtimes use shortest round-trippable digits. Foundation switches
    // to scientific notation outside [-4, 15] and pads signed exponents to two
    // digits. Integral doubles omit .0; negative zero keeps its sign.
    let scientific = format!("{value:e}");
    let (mantissa, exponent) = scientific.split_once('e').unwrap();
    let exponent = exponent.parse::<i32>().unwrap();
    if (-4..16).contains(&exponent) {
        value.to_string()
    } else {
        format!("{mantissa}e{exponent:+03}")
    }
}

#[cfg(test)]
mod tests;
