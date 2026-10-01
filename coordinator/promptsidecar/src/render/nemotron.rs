//! Nemotron-specific mirror of ProviderCoreFoundation/NemotronTemplateFilters.
//! Transformers uses Python `str` and `json.dumps(ensure_ascii=False)` for
//! these filters; the pinned template depends on those exact bytes.

use super::{BoundedWriter, MAX_RENDERED_BYTES};
use minijinja::value::{Rest, ValueKind};
use minijinja::{Error, ErrorKind, Value};
use serde::Serialize;
use std::io::{self, Write};

mod number;
mod string;

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
    string::render(&value).map(Value::from)
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
    fn write_f64<W: ?Sized + Write>(&mut self, writer: &mut W, value: f64) -> io::Result<()> {
        writer.write_all(number::swift_float(value).as_bytes())
    }

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
    fn number_filters_match_actual_swift_double_oracle() {
        let corpus: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../fixtures/prompt-contract/v1/nemotron_number_vectors.json"
        ))
        .unwrap();
        let rows = corpus["vectors"].as_array().unwrap();
        assert!(rows.len() >= 512);
        let mut environment = Environment::new();
        environment.add_filter("string", string);
        environment.add_filter("tojson", tojson);
        for row in rows {
            let bits = u64::from_str_radix(row["bits"].as_str().unwrap(), 16).unwrap();
            let value = Value::from(f64::from_bits(bits));
            let expected = row["rendered"].as_str().unwrap();
            let actual = environment
                .render_str(
                    "{{ value|string }}|{{ value|tojson }}",
                    minijinja::context! { value => value },
                )
                .unwrap();
            assert_eq!(actual, format!("{expected}|{expected}"), "bits {bits:016x}");
        }
    }

    #[test]
    fn nullable_schema_types_keep_swift_string_description() {
        let mut environment = Environment::new();
        environment.add_filter("string", string);
        assert_eq!(
            environment
                .render_str("{{ value|string }}", json!({"value":["number","null"]}))
                .unwrap(),
            "['number', 'null']"
        );
    }

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
