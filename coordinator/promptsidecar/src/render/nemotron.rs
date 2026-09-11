//! Nemotron-specific mirror of ProviderCoreFoundation/NemotronTemplateFilters.
//! Transformers uses Python `str` and `json.dumps(ensure_ascii=False)` for
//! these filters; the pinned template depends on those exact bytes.

use super::{BoundedWriter, MAX_RENDERED_BYTES};
use minijinja::value::{Rest, ValueKind};
use minijinja::{Error, ErrorKind, Value};
use serde::Serialize;
use std::io::{self, Write};

pub(super) fn tojson(value: Value, args: Rest<Value>) -> Result<Value, Error> {
    require_defaults(&args)?;
    let mut output = BoundedWriter::new(MAX_RENDERED_BYTES);
    value
        .serialize(&mut serde_json::Serializer::with_formatter(
            &mut output,
            PythonFormatter,
        ))
        .map_err(|_| {
            Error::new(
                ErrorKind::InvalidOperation,
                "cannot serialize Nemotron prompt JSON",
            )
        })?;
    output.into_string().map(Value::from).map_err(|_| {
        Error::new(
            ErrorKind::InvalidOperation,
            "Nemotron prompt JSON exceeds its byte bound",
        )
    })
}

pub(super) fn string(value: Value, args: Rest<Value>) -> Result<Value, Error> {
    require_defaults(&args)?;
    Ok(Value::from(match value.kind() {
        ValueKind::Bool => if value.is_true() { "True" } else { "False" }.to_owned(),
        ValueKind::None => "None".to_owned(),
        ValueKind::Undefined => String::new(),
        _ => value.to_string(),
    }))
}

fn require_defaults(args: &[Value]) -> Result<(), Error> {
    if !args.is_empty() {
        return Err(Error::new(
            ErrorKind::InvalidOperation,
            "Nemotron reference filters only support their pinned default arguments",
        ));
    }
    Ok(())
}

struct PythonFormatter;

impl serde_json::ser::Formatter for PythonFormatter {
    fn begin_array_value<W: ?Sized + Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        if first {
            Ok(())
        } else {
            writer.write_all(b", ")
        }
    }

    fn begin_object_key<W: ?Sized + Write>(
        &mut self,
        writer: &mut W,
        first: bool,
    ) -> io::Result<()> {
        if first {
            Ok(())
        } else {
            writer.write_all(b", ")
        }
    }

    fn begin_object_value<W: ?Sized + Write>(&mut self, writer: &mut W) -> io::Result<()> {
        writer.write_all(b": ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use minijinja::Environment;
    use serde_json::json;

    #[test]
    fn matches_transformers_defaults_used_by_the_pinned_template() {
        let mut environment = Environment::new();
        environment.add_filter("string", string);
        environment.add_filter("tojson", tojson);
        let output = environment
            .render_str(
                "{{ flag|string }}|{{ values|tojson }}|{{ object|tojson }}",
                json!({
                    "flag": false,
                    "values": ["celsius", "fahrenheit"],
                    "object": {"city": "Montréal / 東京", "valid": true}
                }),
            )
            .unwrap();
        assert_eq!(
            output,
            "False|[\"celsius\", \"fahrenheit\"]|{\"city\": \"Montréal / 東京\", \"valid\": true}"
        );
    }

    #[test]
    fn rejects_filter_options_the_pinned_template_does_not_use() {
        let mut environment = Environment::new();
        environment.add_filter("tojson", tojson);
        assert!(
            environment
                .render_str("{{ [1]|tojson(indent=2) }}", ())
                .is_err()
        );
    }
}
