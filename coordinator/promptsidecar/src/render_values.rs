//! Shared JSON-value coercions used when preparing template inputs. Keep these
//! separate from schema policy: scalar rendering and null removal have the same
//! semantics for the base normalizer, Harmony and Gemma tool arguments.

use serde_json::Value;

pub(crate) fn sanitize_array(values: Vec<Value>) -> Vec<Value> {
    values.into_iter().filter_map(sanitize).collect()
}

pub(crate) fn sanitize(value: Value) -> Option<Value> {
    match value {
        Value::Null => None,
        Value::Array(values) => Some(Value::Array(sanitize_array(values))),
        Value::Object(values) => Some(Value::Object(
            values
                .into_iter()
                .filter_map(|(key, value)| sanitize(value).map(|value| (key, value)))
                .collect(),
        )),
        value => Some(value),
    }
}

pub(crate) fn scalar_string(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        _ => String::new(),
    }
}
