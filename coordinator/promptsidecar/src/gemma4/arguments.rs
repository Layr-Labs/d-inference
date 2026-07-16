use crate::normalize::NormalizeError;
use serde_json::{Map, Value};

pub(super) fn normalize(mut messages: Vec<Value>) -> Result<Vec<Value>, NormalizeError> {
    for message in &mut messages {
        let Some(message) = message.as_object_mut() else {
            continue;
        };
        if message.get("role").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        let Some(calls) = message.get_mut("tool_calls").and_then(Value::as_array_mut) else {
            continue;
        };
        for call in calls {
            let Some(function) = call
                .as_object_mut()
                .and_then(|call| call.get_mut("function"))
                .and_then(Value::as_object_mut)
            else {
                continue;
            };
            let arguments = function.remove("arguments");
            let normalized = match arguments {
                None => Value::Object(Map::new()),
                Some(Value::Object(arguments)) => Value::Object(arguments),
                Some(Value::String(arguments)) if arguments.trim().is_empty() => {
                    Value::Object(Map::new())
                }
                Some(Value::String(arguments)) => {
                    let decoded: Value = serde_json::from_str(&arguments)
                        .map_err(|_| NormalizeError::InvalidTools)?;
                    let Value::Object(arguments) = decoded else {
                        return Err(NormalizeError::InvalidTools);
                    };
                    sanitize(Value::Object(arguments)).unwrap_or_else(|| Value::Object(Map::new()))
                }
                Some(_) => return Err(NormalizeError::InvalidTools),
            };
            function.insert("arguments".into(), normalized);
        }
    }
    Ok(messages)
}

fn sanitize(value: Value) -> Option<Value> {
    match value {
        Value::Null => None,
        Value::Array(values) => Some(Value::Array(
            values.into_iter().filter_map(sanitize).collect(),
        )),
        Value::Object(values) => Some(Value::Object(
            values
                .into_iter()
                .filter_map(|(key, value)| sanitize(value).map(|value| (key, value)))
                .collect(),
        )),
        value => Some(value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_objects_strips_nulls_and_defaults_empty_arguments() {
        let messages = vec![json!({
            "role":"assistant",
            "content":"",
            "tool_calls":[
                {"function":{"name":"a","arguments":"{\"x\":null,\"y\":1}"}},
                {"function":{"name":"b","arguments":" "}}
            ]
        })];
        let normalized = normalize(messages).unwrap();
        assert_eq!(
            normalized[0]["tool_calls"][0]["function"]["arguments"],
            json!({"y": 1})
        );
        assert_eq!(
            normalized[0]["tool_calls"][1]["function"]["arguments"],
            json!({})
        );
    }

    #[test]
    fn rejects_non_object_json_arguments() {
        for arguments in ["null", "[1]", "true", "{bad"] {
            let messages = vec![json!({
                "role":"assistant",
                "content":"",
                "tool_calls":[{"function":{"name":"f","arguments":arguments}}]
            })];
            assert!(normalize(messages).is_err(), "accepted {arguments:?}");
        }
    }
}
