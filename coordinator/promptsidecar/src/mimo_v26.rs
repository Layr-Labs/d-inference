//! Native MiMo prompt input parity with ProviderCore's MiMoV26TemplateFix.
//! This is normalization, not a replacement renderer/serializer or a model gate.
//! Preserve nulls and raw strings; the pinned template has no XML entity repair.

use crate::normalize::NormalizeError;
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use unicode_normalization::UnicodeNormalization;

pub(crate) fn applies(model_type: Option<&str>) -> bool {
    model_type == Some("mimo_v2")
}

fn boolean(value: Option<&Value>) -> Result<Option<bool>, NormalizeError> {
    match value {
        None => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        _ => Err(NormalizeError::InvalidMessages),
    }
}

fn effort(value: Option<&Value>) -> Result<Option<bool>, NormalizeError> {
    match value {
        None => Ok(None),
        Some(Value::String(value))
            if matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "none" | "off" | "0"
            ) =>
        {
            Ok(Some(false))
        }
        _ => Err(NormalizeError::InvalidMessages),
    }
}

/// Validate every supplied control, including shadowed values. Only established
/// API OFF aliases project to false; ON is an actual Boolean or native absence.
pub(crate) fn additional_context(
    body: &Map<String, Value>,
) -> Result<Map<String, Value>, NormalizeError> {
    if body.contains_key("preserve_thinking") {
        return Err(NormalizeError::InvalidMessages);
    }
    let top = boolean(body.get("enable_thinking"))?;
    let raw_effort = effort(body.get("reasoning_effort"))?;
    let kwargs = match body.get("chat_template_kwargs") {
        None => None,
        Some(Value::Object(values)) if values.keys().all(|key| key == "enable_thinking") => {
            boolean(values.get("enable_thinking"))?
        }
        _ => return Err(NormalizeError::InvalidMessages),
    };
    let (nested, nested_effort) = match body.get("reasoning") {
        None | Some(Value::Null) => (None, None),
        Some(Value::Object(values))
            if values.keys().all(|key| key == "enabled" || key == "effort") =>
        {
            (
                boolean(values.get("enabled"))?,
                effort(values.get("effort"))?,
            )
        }
        _ => return Err(NormalizeError::InvalidMessages),
    };
    let mut context = Map::new();
    if let Some(enabled) = nested.or(top).or(kwargs).or(nested_effort).or(raw_effort) {
        context.insert("enable_thinking".into(), Value::Bool(enabled));
    }
    Ok(context)
}

/// Foundation's decodeToolCallArguments consumes objects only. Arrays, JSON
/// scalars and malformed input strings are not reinterpreted or reserialized.
pub(crate) fn decode_arguments(encoded: &str) -> Result<Value, NormalizeError> {
    crate::render::validate_mimo_encoded_argument(encoded)
        .map_err(|_| NormalizeError::InvalidTools)?;
    Ok(match serde_json::from_str::<Value>(encoded) {
        Ok(value @ Value::Object(_)) => value,
        _ => Value::String(encoded.to_owned()),
    })
}

/// The sidecar is text-only. Known media is refused by endpoint lowering;
/// unsupported/audio parts must not quietly become an empty text prompt.
pub(crate) fn message_text(content: Option<&Value>) -> Result<String, NormalizeError> {
    match content {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(text)) => Ok(text.clone()),
        Some(Value::Array(parts)) => {
            let mut output = String::new();
            for part in parts {
                let object = part.as_object().ok_or(NormalizeError::InvalidMessages)?;
                match object.get("type").and_then(Value::as_str) {
                    Some("text" | "input_text" | "output_text") => output.push_str(
                        object
                            .get("text")
                            .and_then(Value::as_str)
                            .ok_or(NormalizeError::InvalidMessages)?,
                    ),
                    _ => return Err(NormalizeError::InvalidMessages),
                }
            }
            Ok(output)
        }
        _ => Err(NormalizeError::InvalidMessages),
    }
}

fn valid_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

/// Match typed OpenAITool.toolSpec's declared fields, not arbitrary unknown
/// function fields. Nested schema nulls remain values. Root parameters:null is
/// omitted by the current optional Swift decoder; it is not a nested-null case.
pub(crate) fn normalize_tools(
    tools: Option<Vec<Value>>,
) -> Result<Option<Vec<Value>>, NormalizeError> {
    let Some(tools) = tools else { return Ok(None) };
    let mut names = HashSet::new();
    let mut output = Vec::with_capacity(tools.len());
    for tool in tools {
        let tool = tool.as_object().ok_or(NormalizeError::InvalidTools)?;
        let function = tool
            .get("function")
            .and_then(Value::as_object)
            .ok_or(NormalizeError::InvalidTools)?;
        let name = function
            .get("name")
            .and_then(Value::as_str)
            .filter(|name| valid_name(name))
            .ok_or(NormalizeError::InvalidTools)?;
        if tool.get("type").and_then(Value::as_str) != Some("function")
            || !names.insert(name.to_owned())
        {
            return Err(NormalizeError::InvalidTools);
        }
        let mut fields = Map::new();
        fields.insert("name".into(), Value::String(name.into()));
        for key in ["description", "parameters"] {
            if let Some(value) = function.get(key).filter(|value| !value.is_null()) {
                fields.insert(key.into(), value.clone());
            }
        }
        output.push(serde_json::json!({"type":"function", "function":fields}));
    }
    Ok(Some(sort_array_for_swift(output)?))
}

/// A complete contiguous parallel result batch may arrive in any order. The
/// native prompt drops IDs, so reorder entire result values by the original call
/// sequence. Never cross a non-tool turn or validate history against new tools.
pub(crate) fn normalize_history(messages: Vec<Value>) -> Result<Vec<Value>, NormalizeError> {
    let mut output = Vec::with_capacity(messages.len());
    let mut seen = HashSet::new();
    let mut pending: Vec<(String, String)> = Vec::new();
    let mut results = HashMap::new();
    for message in messages {
        let object = message.as_object().ok_or(NormalizeError::InvalidMessages)?;
        let role = object
            .get("role")
            .and_then(Value::as_str)
            .ok_or(NormalizeError::InvalidRole)?;
        if !matches!(role, "system" | "user" | "assistant" | "tool") {
            return Err(NormalizeError::InvalidRole);
        }
        if role == "tool" {
            let id = object
                .get("tool_call_id")
                .and_then(Value::as_str)
                .ok_or(NormalizeError::InvalidTools)?;
            let (_, name) = pending
                .iter()
                .find(|(call_id, _)| call_id == id)
                .ok_or(NormalizeError::InvalidTools)?;
            if results.contains_key(id)
                || object.contains_key("tool_calls")
                || object
                    .get("name")
                    .is_some_and(|value| value.as_str() != Some(name.as_str()))
            {
                return Err(NormalizeError::InvalidTools);
            }
            results.insert(id.to_owned(), message);
            continue;
        }
        flush_results(&mut output, &pending, &mut results)?;
        pending.clear();
        if let Some(calls) = object.get("tool_calls") {
            if role != "assistant" {
                return Err(NormalizeError::InvalidTools);
            }
            for call in calls.as_array().ok_or(NormalizeError::InvalidTools)? {
                let call = call.as_object().ok_or(NormalizeError::InvalidTools)?;
                let id = call
                    .get("id")
                    .and_then(Value::as_str)
                    .filter(|id| !id.is_empty())
                    .ok_or(NormalizeError::InvalidTools)?;
                let function = call
                    .get("function")
                    .and_then(Value::as_object)
                    .ok_or(NormalizeError::InvalidTools)?;
                let name = function
                    .get("name")
                    .and_then(Value::as_str)
                    .filter(|name| valid_name(name))
                    .ok_or(NormalizeError::InvalidTools)?;
                if call.get("type").and_then(Value::as_str) != Some("function")
                    || !seen.insert(id.to_owned())
                {
                    return Err(NormalizeError::InvalidTools);
                }
                match function.get("arguments") {
                    Some(Value::Object(arguments)) => {
                        for (key, value) in arguments {
                            if key.is_empty()
                                || key.contains(['<', '>', '\n', '\r'])
                                || value
                                    .as_str()
                                    .is_some_and(|raw| raw.contains("</parameter>"))
                            {
                                return Err(NormalizeError::InvalidTools);
                            }
                            // </function> and </tool_call> inside a parameter
                            // string are opaque. Only its own closer collides.
                        }
                    }
                    Some(Value::String(raw))
                        if !raw.contains("</function>") && !raw.contains("</tool_call>") => {}
                    _ => return Err(NormalizeError::InvalidTools),
                }
                pending.push((id.to_owned(), name.to_owned()));
            }
        }
        output.push(message);
    }
    flush_results(&mut output, &pending, &mut results)?;
    sort_array_for_swift(output)
}

fn flush_results(
    output: &mut Vec<Value>,
    pending: &[(String, String)],
    results: &mut HashMap<String, Value>,
) -> Result<(), NormalizeError> {
    if results.len() != pending.len() {
        return Err(NormalizeError::InvalidTools);
    }
    for (id, _) in pending {
        output.push(results.remove(id).ok_or(NormalizeError::InvalidTools)?);
    }
    Ok(())
}

fn sort_array_for_swift(values: Vec<Value>) -> Result<Vec<Value>, NormalizeError> {
    match sort_for_swift(Value::Array(values))? {
        Value::Array(values) => Ok(values),
        _ => Err(NormalizeError::InvalidMessages),
    }
}

/// Swift-Jinja Value(any:) sorts dictionary keys using Swift String comparison.
/// Preserve the original key bytes; NFC is only a comparison identity. Native
/// array order and string values are never normalized. tojson remains the shared
/// Foundation-compatible serializer in render/json.rs.
fn sort_for_swift(value: Value) -> Result<Value, NormalizeError> {
    fn visit(value: Value, depth: usize, remaining: &mut usize) -> Result<Value, NormalizeError> {
        if depth > 128 || *remaining == 0 {
            return Err(NormalizeError::InvalidMessages);
        }
        *remaining -= 1;
        match value {
            Value::Object(object) => {
                let mut entries = object
                    .into_iter()
                    .map(|(key, value)| {
                        let identity = key.nfc().collect::<String>();
                        (identity, key, value)
                    })
                    .collect::<Vec<_>>();
                entries.sort_by(|a, b| a.0.cmp(&b.0));
                if entries.windows(2).any(|pair| pair[0].0 == pair[1].0) {
                    return Err(NormalizeError::InvalidMessages);
                }
                let object = entries
                    .into_iter()
                    .map(|(_, key, value)| Ok((key, visit(value, depth + 1, remaining)?)))
                    .collect::<Result<Map<_, _>, _>>()?;
                Ok(Value::Object(object))
            }
            Value::Array(values) => Ok(Value::Array(
                values
                    .into_iter()
                    .map(|value| visit(value, depth + 1, remaining))
                    .collect::<Result<Vec<_>, _>>()?,
            )),
            value => Ok(value),
        }
    }
    visit(value, 0, &mut 1_000_000)
}

#[cfg(test)]
mod tests;
