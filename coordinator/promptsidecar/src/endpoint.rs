use crate::api::Endpoint;
use serde_json::{Map, Value, json};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum EndpointError {
    #[error("request body must be a JSON object")]
    NotObject,
    #[error("request endpoint payload is invalid")]
    Invalid,
    #[error("request endpoint payload contains an unsupported item")]
    Unsupported,
}

pub fn lower(endpoint: Endpoint, body: Value) -> Result<Map<String, Value>, EndpointError> {
    let object = body.as_object().ok_or(EndpointError::NotObject)?;
    if contains_media(endpoint, object) {
        return Err(EndpointError::Unsupported);
    }
    match endpoint {
        Endpoint::ChatCompletions => Ok(object.clone()),
        Endpoint::Completions => lower_completions(object),
        Endpoint::Responses => lower_responses(object),
        Endpoint::Messages => lower_messages(object),
    }
}

fn contains_media(endpoint: Endpoint, body: &Map<String, Value>) -> bool {
    match endpoint {
        Endpoint::ChatCompletions => body
            .get("messages")
            .is_some_and(|messages| content_collection_has_media(messages, CHAT_MEDIA_TYPES)),
        Endpoint::Responses => body
            .get("input")
            .is_some_and(|input| content_collection_has_media(input, RESPONSES_MEDIA_TYPES)),
        Endpoint::Messages => body
            .get("messages")
            .is_some_and(|messages| content_collection_has_media(messages, MESSAGES_MEDIA_TYPES)),
        Endpoint::Completions => false,
    }
}

const CHAT_MEDIA_TYPES: &[&str] = &["image", "image_url", "video", "video_url"];
const RESPONSES_MEDIA_TYPES: &[&str] = &[
    "input_image",
    "input_file",
    "image",
    "image_url",
    "video",
    "video_url",
];
const MESSAGES_MEDIA_TYPES: &[&str] = &["image", "document"];

fn content_collection_has_media(value: &Value, media_types: &[&str]) -> bool {
    match value {
        Value::Array(values) => values
            .iter()
            .any(|value| content_collection_has_media(value, media_types)),
        Value::Object(object) => {
            object
                .get("type")
                .and_then(Value::as_str)
                .is_some_and(|kind| media_types.contains(&kind))
                || object
                    .get("content")
                    .is_some_and(|content| content_collection_has_media(content, media_types))
        }
        _ => false,
    }
}

fn lower_completions(input: &Map<String, Value>) -> Result<Map<String, Value>, EndpointError> {
    let prompt = match input.get("prompt") {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Array(values)) if values.len() == 1 => values[0]
            .as_str()
            .ok_or(EndpointError::Unsupported)?
            .to_owned(),
        Some(Value::Array(_)) => return Err(EndpointError::Unsupported),
        _ => return Err(EndpointError::Invalid),
    };
    let mut out = input.clone();
    out.remove("prompt");
    out.remove("endpoint");
    out.insert(
        "messages".into(),
        json!([{"role": "user", "content": prompt}]),
    );
    Ok(out)
}

fn lower_responses(input: &Map<String, Value>) -> Result<Map<String, Value>, EndpointError> {
    let messages = responses_messages(input.get("input").ok_or(EndpointError::Invalid)?)?;
    let mut out = input.clone();
    for key in ["input", "endpoint", "max_output_tokens", "text"] {
        out.remove(key);
    }
    out.insert("messages".into(), Value::Array(messages));
    if let Some(tokens) = explicit_max_tokens(input) {
        out.insert("max_tokens".into(), Value::from(tokens));
    }
    if let Some(tools) = responses_tools(input.get("tools"))? {
        out.insert("tools".into(), Value::Array(tools));
    }
    if let Some(choice) = responses_tool_choice(input.get("tool_choice"))? {
        out.insert("tool_choice".into(), choice);
    }
    if let Some(format) = responses_text_format(input.get("text")) {
        out.insert("response_format".into(), format);
    }
    Ok(out)
}

fn responses_messages(input: &Value) -> Result<Vec<Value>, EndpointError> {
    if let Some(text) = input.as_str() {
        return Ok(vec![json!({"role": "user", "content": text})]);
    }
    let items = input.as_array().ok_or(EndpointError::Invalid)?;
    let mut messages = Vec::new();
    for value in items {
        let Some(item) = value.as_object() else {
            continue;
        };
        match item.get("type").and_then(Value::as_str) {
            Some("message") => {
                let role =
                    canonical_role(item.get("role").and_then(Value::as_str).unwrap_or("user"))?;
                messages.push(json!({
                    "role": role,
                    "content": responses_content_text(item.get("content")),
                }));
            }
            Some("function_call") => {
                let call_id = string_field(item, "call_id")
                    .or_else(|| string_field(item, "id"))
                    .unwrap_or_default();
                let arguments = match item.get("arguments") {
                    None => "{}",
                    Some(Value::String(arguments)) => arguments,
                    Some(_) => return Err(EndpointError::Invalid),
                };
                messages.push(json!({
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [{
                        "id": call_id,
                        "type": "function",
                        "function": {
                            "name": string_field(item, "name").unwrap_or_default(),
                            "arguments": arguments,
                        }
                    }]
                }));
            }
            Some("function_call_output") => {
                messages.push(json!({
                    "role": "tool",
                    "tool_call_id": string_field(item, "call_id").unwrap_or_default(),
                    "content": responses_content_text(item.get("output")),
                }));
            }
            Some("reasoning") => {}
            Some(_) => return Err(EndpointError::Unsupported),
            None => {
                let Some(role) = item.get("role").and_then(Value::as_str) else {
                    continue;
                };
                messages.push(json!({
                    "role": canonical_role(role)?,
                    "content": responses_content_text(item.get("content")),
                }));
            }
        }
    }
    if messages.is_empty() {
        return Err(EndpointError::Invalid);
    }
    Ok(coalesce_responses_function_calls(messages))
}

fn coalesce_responses_function_calls(messages: Vec<Value>) -> Vec<Value> {
    let mut output: Vec<Value> = Vec::with_capacity(messages.len());
    for message in messages {
        let calls = message
            .as_object()
            .and_then(|message| message.get("tool_calls"))
            .and_then(Value::as_array)
            .filter(|calls| !calls.is_empty())
            .cloned();
        let Some(calls) = calls else {
            output.push(message);
            continue;
        };
        if let Some(previous) = output.last_mut().and_then(Value::as_object_mut)
            && previous.get("role").and_then(Value::as_str) == Some("assistant")
            && let Some(previous_calls) =
                previous.get_mut("tool_calls").and_then(Value::as_array_mut)
        {
            previous_calls.extend(calls);
            continue;
        }
        output.push(message);
    }
    output
}

fn responses_content_text(content: Option<&Value>) -> String {
    match content {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|part| match part {
                Value::String(text) if !text.is_empty() => Some(text.clone()),
                Value::Object(object) => object
                    .get("text")
                    .and_then(Value::as_str)
                    .filter(|text| !text.is_empty())
                    .map(str::to_owned)
                    .or_else(|| match object.get("type").and_then(Value::as_str) {
                        Some("input_image") => Some("[input_image omitted]".into()),
                        Some("input_file") => Some("[input_file omitted]".into()),
                        _ => None,
                    }),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Some(other) => serde_json::to_string(other).unwrap_or_default(),
    }
}

fn responses_tools(tools: Option<&Value>) -> Result<Option<Vec<Value>>, EndpointError> {
    let Some(items) = tools.and_then(Value::as_array) else {
        return Ok(None);
    };
    let mut output = Vec::new();
    for item in items {
        let Some(tool) = item.as_object() else {
            continue;
        };
        match tool.get("type").and_then(Value::as_str).unwrap_or("") {
            "" | "function" => {
                if let Some(function) = tool.get("function").and_then(Value::as_object) {
                    output.push(json!({"type": "function", "function": function}));
                    continue;
                }
                let name = tool
                    .get("name")
                    .and_then(Value::as_str)
                    .filter(|name| !name.is_empty())
                    .ok_or(EndpointError::Invalid)?;
                let mut function = Map::new();
                function.insert("name".into(), Value::String(name.into()));
                for key in ["description", "parameters"] {
                    if let Some(value) = tool.get(key) {
                        function.insert(key.into(), value.clone());
                    }
                }
                output.push(json!({"type": "function", "function": function}));
            }
            _ => return Err(EndpointError::Unsupported),
        }
    }
    Ok((!output.is_empty()).then_some(output))
}

fn responses_tool_choice(choice: Option<&Value>) -> Result<Option<Value>, EndpointError> {
    let Some(choice) = choice else {
        return Ok(None);
    };
    let Some(object) = choice.as_object() else {
        return Ok(Some(choice.clone()));
    };
    if object.get("type").and_then(Value::as_str) != Some("function") {
        return Ok(Some(choice.clone()));
    }
    let name = object
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
        .ok_or(EndpointError::Invalid)?;
    Ok(Some(
        json!({"type": "function", "function": {"name": name}}),
    ))
}

fn responses_text_format(text: Option<&Value>) -> Option<Value> {
    let format = text?.as_object()?.get("format")?.as_object()?;
    match format.get("type").and_then(Value::as_str) {
        Some("json_object") => Some(json!({"type": "json_object"})),
        Some("json_schema") => Some(json!({"type": "json_schema", "json_schema": format})),
        _ => None,
    }
}

fn lower_messages(input: &Map<String, Value>) -> Result<Map<String, Value>, EndpointError> {
    let raw_messages = input
        .get("messages")
        .and_then(Value::as_array)
        .ok_or(EndpointError::Invalid)?;
    let mut messages = Vec::new();
    if let Some(system) = input.get("system") {
        let text = anthropic_content_text(system);
        if !text.is_empty() {
            messages.push(json!({"role": "system", "content": text}));
        }
    }
    for raw in raw_messages {
        let message = raw.as_object().ok_or(EndpointError::Invalid)?;
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .ok_or(EndpointError::Invalid)?;
        let content = message.get("content").unwrap_or(&Value::Null);
        if let Some(parts) = content.as_array() {
            match role {
                "assistant" => messages.push(lower_anthropic_assistant(parts)?),
                "user" => lower_anthropic_user(parts, &mut messages)?,
                _ => return Err(EndpointError::Invalid),
            }
        } else if matches!(role, "user" | "assistant") {
            messages.push(json!({
                "role": canonical_role(role)?,
                "content": anthropic_content_text(content),
            }));
        } else {
            return Err(EndpointError::Invalid);
        }
    }

    let mut out = input.clone();
    out.remove("system");
    out.remove("endpoint");
    out.remove("stop_sequences");
    out.insert("messages".into(), Value::Array(messages));
    if let Some(raw_stops) = input.get("stop_sequences") {
        let stops = raw_stops.as_array().ok_or(EndpointError::Invalid)?;
        if stops.iter().any(|stop| !stop.is_string()) {
            return Err(EndpointError::Invalid);
        }
        out.insert("stop".into(), Value::Array(stops.clone()));
    }
    if let Some(tools) = anthropic_tools(input.get("tools"))? {
        out.insert("tools".into(), Value::Array(tools));
    }
    if let Some(choice) = anthropic_tool_choice(input.get("tool_choice"))? {
        out.insert("tool_choice".into(), choice);
    }
    if let Some(choice) = input.get("tool_choice").and_then(Value::as_object)
        && let Some(disable) = choice.get("disable_parallel_tool_use")
    {
        out.insert(
            "parallel_tool_calls".into(),
            Value::Bool(!disable.as_bool().ok_or(EndpointError::Invalid)?),
        );
    }
    Ok(out)
}

fn lower_anthropic_assistant(parts: &[Value]) -> Result<Value, EndpointError> {
    let mut texts = Vec::new();
    let mut reasoning = Vec::new();
    let mut calls = Vec::new();
    for part in parts {
        let object = part.as_object().ok_or(EndpointError::Invalid)?;
        match object.get("type").and_then(Value::as_str) {
            Some("text") => {
                if let Some(text) = object.get("text").and_then(Value::as_str) {
                    texts.push(text);
                }
            }
            Some("thinking") => {
                if let Some(text) = object.get("thinking").and_then(Value::as_str) {
                    reasoning.push(text);
                }
            }
            Some("tool_use") => {
                let id = string_field(object, "id")
                    .filter(|value| !value.is_empty())
                    .ok_or(EndpointError::Invalid)?;
                let name = string_field(object, "name")
                    .filter(|value| !value.is_empty())
                    .ok_or(EndpointError::Invalid)?;
                let arguments = serde_json::to_string(
                    object.get("input").unwrap_or(&Value::Object(Map::new())),
                )
                .map_err(|_| EndpointError::Invalid)?;
                calls.push(json!({
                    "id": id,
                    "type": "function",
                    "function": {"name": name, "arguments": arguments},
                }));
            }
            Some(_) | None => return Err(EndpointError::Unsupported),
        }
    }
    let mut message = Map::new();
    message.insert("role".into(), Value::String("assistant".into()));
    message.insert("content".into(), Value::String(texts.join("")));
    if !reasoning.is_empty() {
        message.insert(
            "reasoning_content".into(),
            Value::String(reasoning.join("")),
        );
    }
    if !calls.is_empty() {
        message.insert("tool_calls".into(), Value::Array(calls));
    }
    Ok(Value::Object(message))
}

fn lower_anthropic_user(parts: &[Value], messages: &mut Vec<Value>) -> Result<(), EndpointError> {
    let mut pending_text = Vec::new();
    let flush_text = |pending: &mut Vec<&str>, messages: &mut Vec<Value>| {
        if !pending.is_empty() {
            messages.push(json!({"role": "user", "content": pending.join("")}));
            pending.clear();
        }
    };
    for part in parts {
        let object = part.as_object().ok_or(EndpointError::Invalid)?;
        match object.get("type").and_then(Value::as_str) {
            Some("text") => {
                if let Some(text) = object.get("text").and_then(Value::as_str) {
                    pending_text.push(text);
                }
            }
            Some("tool_result") => {
                flush_text(&mut pending_text, messages);
                let call_id = string_field(object, "tool_use_id")
                    .filter(|value| !value.is_empty())
                    .ok_or(EndpointError::Invalid)?;
                messages.push(json!({
                    "role": "tool",
                    "tool_call_id": call_id,
                    "content": anthropic_content_text(
                        object.get("content").unwrap_or(&Value::Null)
                    ),
                }));
            }
            Some(_) | None => return Err(EndpointError::Unsupported),
        }
    }
    flush_text(&mut pending_text, messages);
    Ok(())
}

fn anthropic_content_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|part| {
                part.as_object()
                    .filter(|object| object.get("type").and_then(Value::as_str) == Some("text"))
                    .and_then(|object| object.get("text"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn anthropic_tools(tools: Option<&Value>) -> Result<Option<Vec<Value>>, EndpointError> {
    let Some(tools) = tools else {
        return Ok(None);
    };
    let tools = tools.as_array().ok_or(EndpointError::Invalid)?;
    let mut output = Vec::with_capacity(tools.len());
    for tool in tools {
        let tool = tool.as_object().ok_or(EndpointError::Invalid)?;
        let name = tool
            .get("name")
            .and_then(Value::as_str)
            .filter(|name| !name.is_empty())
            .ok_or(EndpointError::Invalid)?;
        output.push(json!({
            "type": "function",
            "function": {
                "name": name,
                "description": tool.get("description").cloned().unwrap_or(Value::String(String::new())),
                "parameters": tool.get("input_schema").cloned().unwrap_or_else(|| json!({"type": "object"})),
            }
        }));
    }
    Ok(Some(output))
}

fn anthropic_tool_choice(choice: Option<&Value>) -> Result<Option<Value>, EndpointError> {
    let Some(choice) = choice else {
        return Ok(None);
    };
    let object = choice.as_object().ok_or(EndpointError::Invalid)?;
    match object.get("type").and_then(Value::as_str) {
        Some("auto") => Ok(Some(Value::String("auto".into()))),
        Some("any") => Ok(Some(Value::String("required".into()))),
        Some("none") => Ok(Some(Value::String("none".into()))),
        Some("tool") => {
            let name = object
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
                .ok_or(EndpointError::Invalid)?;
            Ok(Some(
                json!({"type": "function", "function": {"name": name}}),
            ))
        }
        _ => Err(EndpointError::Invalid),
    }
}

fn canonical_role(role: &str) -> Result<&str, EndpointError> {
    match role {
        "developer" => Ok("system"),
        "function" => Ok("tool"),
        "system" | "user" | "assistant" | "tool" => Ok(role),
        _ => Err(EndpointError::Invalid),
    }
}

fn string_field<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

fn explicit_max_tokens(input: &Map<String, Value>) -> Option<u64> {
    ["max_tokens", "max_completion_tokens", "max_output_tokens"]
        .iter()
        .filter_map(|key| input.get(*key).and_then(Value::as_u64))
        .find(|value| *value > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lowers_responses_function_history() {
        let body = json!({
            "model": "m",
            "input": [
                {"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]},
                {"type":"function_call","call_id":"c1","name":"weather","arguments":"{}"},
                {"type":"function_call_output","call_id":"c1","output":"sunny"}
            ]
        });
        let lowered = lower(Endpoint::Responses, body).unwrap();
        assert_eq!(lowered["messages"][0]["role"], "system");
        assert_eq!(lowered["messages"][1]["tool_calls"][0]["id"], "c1");
        assert_eq!(lowered["messages"][2]["role"], "tool");
    }

    #[test]
    fn rejects_media_content() {
        let body = json!({
            "model": "m",
            "messages": [{
                "role": "user",
                "content": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,AA=="}}]
            }]
        });
        assert!(matches!(
            lower(Endpoint::ChatCompletions, body),
            Err(EndpointError::Unsupported)
        ));
    }

    #[test]
    fn does_not_treat_tool_schema_types_as_media() {
        let body = json!({
            "model": "m",
            "messages": [{"role": "user", "content": "describe"}],
            "tools": [{
                "type": "function",
                "function": {
                    "name": "render",
                    "parameters": {
                        "type": "object",
                        "properties": {"format": {"type": "image"}}
                    }
                }
            }]
        });
        assert!(lower(Endpoint::ChatCompletions, body).is_ok());
    }

    #[test]
    fn lowers_anthropic_tool_history_without_reordering_turns() {
        let body = json!({
            "model": "m",
            "messages": [
                {
                    "role": "assistant",
                    "content": [
                        {"type": "text", "text": "checking"},
                        {"type": "tool_use", "id": "c1", "name": "weather", "input": {"city": "Oslo"}}
                    ]
                },
                {
                    "role": "user",
                    "content": [
                        {"type": "tool_result", "tool_use_id": "c1", "content": "snow"},
                        {"type": "text", "text": "summarize"}
                    ]
                }
            ],
            "tools": [{"name": "weather", "input_schema": {"type": "object"}}],
            "tool_choice": {"type": "tool", "name": "weather"}
        });
        let lowered = lower(Endpoint::Messages, body).unwrap();
        assert_eq!(lowered["messages"][0]["content"], "checking");
        assert_eq!(lowered["messages"][0]["tool_calls"][0]["id"], "c1");
        assert_eq!(lowered["messages"][1]["role"], "tool");
        assert_eq!(lowered["messages"][2]["content"], "summarize");
        assert_eq!(
            lowered["tool_choice"],
            json!({"type":"function","function":{"name":"weather"}})
        );
    }

    #[test]
    fn lowers_anthropic_stop_sequences_to_provider_stop() {
        let body = json!({
            "model": "m",
            "messages": [],
            "stop_sequences": ["DONE", "END"]
        });
        let lowered = lower(Endpoint::Messages, body).unwrap();
        assert_eq!(lowered["stop"], json!(["DONE", "END"]));
        assert!(lowered.get("stop_sequences").is_none());

        let invalid = json!({"messages": [], "stop_sequences": ["DONE", 1]});
        assert!(matches!(
            lower(Endpoint::Messages, invalid),
            Err(EndpointError::Invalid)
        ));
    }
}
