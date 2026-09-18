//! Conservative eligibility before normalization can discard input evidence.
//! Never rewrite values: ambiguous Unicode keys, unsupported numeric bridge
//! values and nonobject JSON tool arguments use the ordinary cold path.

use super::RenderError;
use serde_json::Value;
use std::borrow::Cow;
use std::collections::HashSet;
use unicode_normalization::UnicodeNormalization;

const MAX_KEY_BYTES: usize = 4096;
const MAX_KEY_WORK_BYTES: usize = 16 << 20;
const MAX_NODES: usize = 1_000_000;

pub(crate) fn validate_request_input(body: &Value) -> Result<(), RenderError> {
    let mut nodes = MAX_NODES;
    let mut work = MAX_KEY_WORK_BYTES;
    visit(body, 0, &mut nodes, &mut work)?;
    validate_encoded_arguments(body, &mut nodes, &mut work)
}

fn validate_encoded_arguments(
    body: &Value,
    nodes: &mut usize,
    work: &mut usize,
) -> Result<(), RenderError> {
    if let Some(messages) = body.get("messages").and_then(Value::as_array) {
        for message in messages {
            if let Some(calls) = message.get("tool_calls").and_then(Value::as_array) {
                for call in calls {
                    if let Some(function) = call.get("function") {
                        validate_argument(function, nodes, work)?;
                    }
                }
            }
            if let Some(function) = message.get("function_call") {
                validate_argument(function, nodes, work)?;
            }
        }
    }
    // Responses carries function calls directly in its input-item sequence.
    if let Some(items) = body.get("input").and_then(Value::as_array) {
        for item in items {
            if item.get("type").and_then(Value::as_str) == Some("function_call") {
                validate_argument(item, nodes, work)?;
            }
        }
    }
    Ok(())
}

fn validate_argument(
    function: &Value,
    nodes: &mut usize,
    work: &mut usize,
) -> Result<(), RenderError> {
    let Some(encoded) = function.get("arguments").and_then(Value::as_str) else {
        return Ok(());
    };
    if encoded.len() > 4 << 20 {
        return Err(RenderError::UnsupportedInput);
    }
    // Inspect before sanitize can remove a null member and conceal its
    // canonical collision. A parser resource/depth refusal must not turn valid
    // structured input into an apparently safe opaque string.
    if let Ok(decoded) = serde_json::from_str::<Value>(encoded) {
        // Swift decodeToolCallArguments decodes objects only. The current
        // normalizer decodes every valid JSON shape; do not pretend arrays or
        // scalars render identically until that contract is deliberately changed.
        if !decoded.is_object() {
            return Err(RenderError::UnsupportedInput);
        }
        visit(&decoded, 0, nodes, work)?;
    } else if encoded.trim_start().starts_with(['{', '[']) {
        // Both malformed and unsupported object/array-shaped arguments stay
        // cold. Ordinary non-JSON text keeps its existing opaque behavior.
        return Err(RenderError::UnsupportedInput);
    }
    Ok(())
}

fn visit(
    value: &Value,
    depth: usize,
    nodes: &mut usize,
    work: &mut usize,
) -> Result<(), RenderError> {
    if depth > 128 || *nodes == 0 {
        return Err(RenderError::UnsupportedInput);
    }
    *nodes -= 1;
    match value {
        Value::Array(values) => {
            for value in values {
                visit(value, depth + 1, nodes, work)?;
            }
        }
        Value::Object(values) => {
            let mut has_unicode = false;
            for key in values.keys() {
                if key.len() > MAX_KEY_BYTES {
                    return Err(RenderError::UnsupportedInput);
                }
                has_unicode |= !key.is_ascii();
            }
            if has_unicode {
                let mut seen = HashSet::new();
                for key in values.keys() {
                    // Each input key is bounded before NFC's combining-mark
                    // buffer is created. Account conservatively for expansion
                    // and hash-table metadata across the entire traversal.
                    let charge = key.len().saturating_mul(3).saturating_add(64);
                    *work = work
                        .checked_sub(charge)
                        .ok_or(RenderError::UnsupportedInput)?;
                    let identity = if key.is_ascii() {
                        Cow::Borrowed(key.as_str())
                    } else {
                        Cow::Owned(key.nfc().collect::<String>())
                    };
                    if !seen.insert(identity) {
                        return Err(RenderError::UnsupportedInput);
                    }
                }
            }
            // Drop the parent's key table before descending into child maps.
            for value in values.values() {
                visit(value, depth + 1, nodes, work)?;
            }
        }
        Value::Number(number) => {
            // JSONValue and Foundation bridge signed integer literals exactly.
            // Larger unsigned literals or large integral doubles have different
            // runtime types/precision; negative zero becomes Swift Int(0).
            if number.is_u64() && number.as_i64().is_none() {
                return Err(RenderError::UnsupportedInput);
            }
            if number.is_f64() {
                let value = number.as_f64().ok_or(RenderError::UnsupportedInput)?;
                if value.abs() >= 1e16 || (value == 0.0 && value.is_sign_negative()) {
                    return Err(RenderError::UnsupportedInput);
                }
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests;
