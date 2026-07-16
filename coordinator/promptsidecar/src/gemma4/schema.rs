use serde_json::{Map, Value};

pub(super) fn normalize(tools: Vec<Value>) -> Vec<Value> {
    tools.into_iter().map(normalize_tool).collect()
}

fn normalize_tool(mut tool: Value) -> Value {
    let Some(tool_object) = tool.as_object_mut() else {
        return tool;
    };
    let Some(function) = tool_object
        .get_mut("function")
        .and_then(Value::as_object_mut)
    else {
        return tool;
    };
    normalize_string_field(function, "name");
    normalize_string_field(function, "description");
    if let Some(parameters) = function.remove("parameters")
        && let Some(parameters) = normalize_parameters(parameters)
    {
        function.insert("parameters".into(), Value::Object(parameters));
    }
    tool
}

fn normalize_parameters(parameters: Value) -> Option<Map<String, Value>> {
    let Value::Object(mut parameters) = parameters else {
        return None;
    };
    if parameters.is_empty() {
        return None;
    }
    enforce_schema_node(&mut parameters);
    if !parameters.get("type").is_some_and(Value::is_string) {
        parameters.insert("type".into(), Value::String("object".into()));
    }
    Some(parameters)
}

fn enforce_schema_node(node: &mut Map<String, Value>) {
    if node
        .get("description")
        .is_some_and(|value| !value.is_string())
    {
        normalize_string_field(node, "description");
    }
    if let Some(properties) = node.get_mut("properties") {
        if let Some(properties) = properties.as_object_mut() {
            for value in properties.values_mut() {
                enforce_property_value(value);
            }
        } else {
            *properties = Value::Object(Map::new());
        }
    }
    if node
        .get("type")
        .and_then(Value::as_str)
        .is_some_and(|kind| kind.eq_ignore_ascii_case("object"))
        && !node.get("properties").is_some_and(Value::is_object)
    {
        node.insert("properties".into(), Value::Object(Map::new()));
    }
    if let Some(required) = node.remove("required")
        && let Value::Array(required) = required
    {
        node.insert(
            "required".into(),
            Value::Array(required.into_iter().filter_map(required_member).collect()),
        );
    }
    if let Some(items) = node.get_mut("items").and_then(Value::as_object_mut) {
        enforce_schema_node(items);
    }
}

fn enforce_property_value(value: &mut Value) {
    let Some(property) = value.as_object_mut() else {
        *value = serde_json::json!({"type": "string"});
        return;
    };
    enforce_schema_node(property);
    if !property.get("type").is_some_and(Value::is_string) {
        property.insert(
            "type".into(),
            Value::String(inferred_property_type(property).into()),
        );
    }
}

fn inferred_property_type(property: &Map<String, Value>) -> &'static str {
    if ["properties", "patternProperties", "additionalProperties"]
        .iter()
        .any(|key| property.contains_key(*key))
    {
        "object"
    } else if ["items", "prefixItems"]
        .iter()
        .any(|key| property.contains_key(*key))
    {
        "array"
    } else {
        "string"
    }
}

fn required_member(value: Value) -> Option<Value> {
    match value {
        Value::String(_) => Some(value),
        Value::Bool(value) => Some(Value::String(value.to_string())),
        Value::Number(value) => Some(Value::String(value.to_string())),
        Value::Null | Value::Array(_) | Value::Object(_) => None,
    }
}

fn normalize_string_field(object: &mut Map<String, Value>, key: &str) {
    let value = object.remove(key);
    let normalized = match value {
        Some(Value::String(value)) => value,
        Some(Value::Bool(value)) => value.to_string(),
        Some(Value::Number(value)) => value.to_string(),
        _ => String::new(),
    };
    object.insert(key.into(), Value::String(normalized));
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn enforces_gemma_schema_shape() {
        let normalized = normalize(vec![json!({
            "type":"function",
            "function":{
                "name":"f",
                "parameters":{
                    "type":"object",
                    "patternProperties":{"^x":{}},
                    "required":["x", 1, null]
                }
            }
        })]);
        assert_eq!(normalized[0]["function"]["description"], "");
        assert_eq!(
            normalized[0]["function"]["parameters"]["properties"],
            json!({})
        );
        assert_eq!(
            normalized[0]["function"]["parameters"]["required"],
            json!(["x", "1"])
        );
    }
}
