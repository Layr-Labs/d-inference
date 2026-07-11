use serde_json::{Map, Value};

use super::AdapterError;

pub const MAX_BODY_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_JSON_VALUES: usize = 16_384;
pub const MAX_JSON_TOTAL_STRING_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_SSE_EVENT_BYTES: usize = 1024 * 1024;
pub const MAX_SSE_EVENTS: usize = 16_384;
pub const MAX_MESSAGES: usize = 256;
pub const MAX_TOOLS: usize = 128;
pub const MAX_CONTENT_PARTS: usize = 256;
pub const MAX_TOOL_CALLS_PER_MESSAGE: usize = 128;
pub const MAX_PROMPTS: usize = 256;
pub const MAX_MODEL_BYTES: usize = 256;
pub const MAX_OUTPUT_TOKENS: u64 = 32_768;

pub fn parse_request_object(bytes: &[u8]) -> Result<Map<String, Value>, AdapterError> {
    if bytes.len() > MAX_BODY_BYTES {
        return Err(AdapterError::payload_too_large());
    }
    parse_object(
        bytes,
        "request body must be valid JSON",
        "request body must be a JSON object",
    )
}

pub fn parse_response_object(bytes: &[u8]) -> Result<Map<String, Value>, AdapterError> {
    if bytes.len() > MAX_RESPONSE_BYTES {
        return Err(AdapterError::limit(
            format!("response exceeds the {MAX_RESPONSE_BYTES}-byte limit"),
            None,
        ));
    }
    parse_object(
        bytes,
        "provider returned malformed chat completion JSON",
        "provider returned a non-object chat completion",
    )
}

fn parse_object(
    bytes: &[u8],
    malformed_message: &'static str,
    object_message: &'static str,
) -> Result<Map<String, Value>, AdapterError> {
    crate::pilot::validate_json_structure(bytes)
        .map_err(|_| AdapterError::invalid(malformed_message, None))?;
    serde_json::from_slice::<Value>(bytes)
        .map_err(|_| AdapterError::invalid(malformed_message, None))?
        .as_object()
        .cloned()
        .ok_or_else(|| AdapterError::invalid(object_message, None))
}

pub fn validate_model(object: &Map<String, Value>) -> Result<String, AdapterError> {
    let model = object
        .get("model")
        .and_then(Value::as_str)
        .filter(|model| !model.is_empty())
        .ok_or_else(|| AdapterError::invalid("model is required", Some("model")))?;
    if model.len() > MAX_MODEL_BYTES || model.chars().any(char::is_control) {
        return Err(AdapterError::invalid(
            "model must be at most 256 bytes and contain no control characters",
            Some("model"),
        ));
    }
    Ok(model.to_owned())
}

pub fn validate_stream(object: &Map<String, Value>) -> Result<bool, AdapterError> {
    match object.get("stream") {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(stream)) => Ok(*stream),
        Some(_) => Err(AdapterError::invalid(
            "stream must be a boolean",
            Some("stream"),
        )),
    }
}

pub fn validate_single_choice(object: &Map<String, Value>) -> Result<(), AdapterError> {
    match object.get("n") {
        None | Some(Value::Null) => Ok(()),
        Some(Value::Number(number)) if number.as_u64() == Some(1) => Ok(()),
        Some(_) => Err(AdapterError::invalid("n must be the integer 1", Some("n"))),
    }
}

pub fn maximum_output_tokens(object: &Map<String, Value>) -> Result<u64, AdapterError> {
    let value = object
        .get("max_completion_tokens")
        .or_else(|| object.get("max_tokens"))
        .or_else(|| object.get("max_output_tokens"));
    let Some(value) = value else {
        return Ok(1_024);
    };
    let Some(tokens) = value.as_u64().filter(|tokens| *tokens > 0) else {
        return Err(AdapterError::invalid(
            "maximum output tokens must be a positive integer",
            Some("max_tokens"),
        ));
    };
    if tokens > MAX_OUTPUT_TOKENS {
        return Err(AdapterError::limit(
            format!("maximum output tokens may not exceed {MAX_OUTPUT_TOKENS}"),
            Some("max_tokens"),
        ));
    }
    Ok(tokens)
}

pub fn validate_canonical_cardinality(object: &Map<String, Value>) -> Result<(), AdapterError> {
    let messages = required_array(object, "messages")?;
    if messages.is_empty() {
        return Err(AdapterError::invalid(
            "messages must not be empty",
            Some("messages"),
        ));
    }
    enforce_count("messages", messages.len(), MAX_MESSAGES)?;

    if let Some(tools) = optional_array(object, "tools")? {
        enforce_count("tools", tools.len(), MAX_TOOLS)?;
    }

    for message in messages {
        let message = message.as_object().ok_or_else(|| {
            AdapterError::invalid("each message must be an object", Some("messages"))
        })?;
        if let Some(content) = message.get("content") {
            match content {
                Value::String(_) | Value::Null => {}
                Value::Array(parts) => {
                    enforce_count("message content", parts.len(), MAX_CONTENT_PARTS)?;
                }
                _ => {
                    return Err(AdapterError::invalid(
                        "message content must be a string, array, or null",
                        Some("messages"),
                    ));
                }
            }
        }
        if let Some(tool_calls) = optional_array(message, "tool_calls")? {
            enforce_count(
                "message tool_calls",
                tool_calls.len(),
                MAX_TOOL_CALLS_PER_MESSAGE,
            )?;
        }
    }
    Ok(())
}

pub fn required_array<'a>(
    object: &'a Map<String, Value>,
    field: &'static str,
) -> Result<&'a Vec<Value>, AdapterError> {
    object
        .get(field)
        .and_then(Value::as_array)
        .ok_or_else(|| AdapterError::invalid("required field must be an array", Some(field)))
}

pub fn optional_array<'a>(
    object: &'a Map<String, Value>,
    field: &'static str,
) -> Result<Option<&'a Vec<Value>>, AdapterError> {
    match object.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(values)) => Ok(Some(values)),
        Some(_) => Err(AdapterError::invalid("field must be an array", Some(field))),
    }
}

pub fn enforce_count(
    field: &'static str,
    actual: usize,
    maximum: usize,
) -> Result<(), AdapterError> {
    if actual > maximum {
        return Err(AdapterError::limit(
            format!("{field} may contain at most {maximum} entries"),
            Some(field),
        ));
    }
    Ok(())
}

pub fn serialize_canonical(value: &Value) -> Result<Vec<u8>, AdapterError> {
    let bytes = serde_json::to_vec(value)
        .map_err(|_| AdapterError::invalid("request could not be converted", None))?;
    if bytes.len() > MAX_BODY_BYTES {
        return Err(AdapterError::payload_too_large());
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_body_limit_and_structural_limits_are_enforced() {
        let mut exact = vec![b' '; MAX_BODY_BYTES];
        exact[0] = b'{';
        exact[1] = b'}';
        assert!(parse_request_object(&exact).is_ok());
        assert!(parse_request_object(&vec![b' '; MAX_BODY_BYTES + 1]).is_err());

        let mut at_depth = "0".to_owned();
        for _ in 0..31 {
            at_depth = format!("[{at_depth}]");
        }
        let at_depth = format!("{{\"value\":{at_depth}}}");
        assert!(parse_request_object(at_depth.as_bytes()).is_ok());
        let mut too_deep = "0".to_owned();
        for _ in 0..32 {
            too_deep = format!("[{too_deep}]");
        }
        let too_deep = format!("{{\"value\":{too_deep}}}");
        assert!(parse_request_object(too_deep.as_bytes()).is_err());

        let messages = vec![serde_json::json!({"role":"user","content":""}); MAX_MESSAGES];
        let object = serde_json::json!({"messages": messages});
        assert!(validate_canonical_cardinality(object.as_object().expect("object")).is_ok());
        let messages = vec![serde_json::json!({"role":"user","content":""}); MAX_MESSAGES + 1];
        let object = serde_json::json!({"messages": messages});
        assert!(validate_canonical_cardinality(object.as_object().expect("object")).is_err());
    }
}
