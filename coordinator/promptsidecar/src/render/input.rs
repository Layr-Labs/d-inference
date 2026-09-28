//! Conservative eligibility before normalization can discard input evidence.
//! Never rewrite values: ambiguous Unicode keys, unsupported numeric bridge
//! values use the ordinary cold path. Encoded argument representation is chosen
//! only after trusted model metadata; legacy families retain object-only rules.

use super::RenderError;
use serde_json::Value;
use std::borrow::Cow;
use std::collections::HashSet;
use unicode_normalization::UnicodeNormalization;

const MAX_KEY_BYTES: usize = 4096;
const MAX_KEY_WORK_BYTES: usize = 16 << 20;
const MAX_NODES: usize = 1_000_000;

pub(crate) fn validate_request_input(body: &Value) -> Result<(), RenderError> {
    validate_input(body, ArgumentPolicy::LegacyObjectOnly)
}

/// Only encoded argument representation is deferred until trusted metadata is
/// loaded. Raw-tree/resource eligibility still precedes artifact work.
pub(crate) fn validate_request_input_before_contract(body: &Value) -> Result<(), RenderError> {
    validate_input(body, ArgumentPolicy::Deferred)
}

pub(crate) fn validate_request_input_for_model(
    body: &Value,
    model_type: Option<&str>,
) -> Result<(), RenderError> {
    if crate::mimo_v26::applies(model_type) {
        validate_input(body, ArgumentPolicy::MiMoObjectOrOpaque)
    } else {
        validate_request_input(body)
    }
}

#[derive(Clone, Copy)]
enum ArgumentPolicy {
    LegacyObjectOnly,
    Deferred,
    MiMoObjectOrOpaque,
}

fn validate_input(body: &Value, policy: ArgumentPolicy) -> Result<(), RenderError> {
    let mut nodes = MAX_NODES;
    let mut work = MAX_KEY_WORK_BYTES;
    visit(body, 0, &mut nodes, &mut work)?;
    validate_encoded_arguments(body, &mut nodes, &mut work, policy)
}

fn validate_encoded_arguments(
    body: &Value,
    nodes: &mut usize,
    work: &mut usize,
    policy: ArgumentPolicy,
) -> Result<(), RenderError> {
    if let Some(messages) = body.get("messages").and_then(Value::as_array) {
        for message in messages {
            if let Some(calls) = message.get("tool_calls").and_then(Value::as_array) {
                for call in calls {
                    if let Some(function) = call.get("function") {
                        validate_argument(function, nodes, work, policy)?;
                    }
                }
            }
            if let Some(function) = message.get("function_call") {
                validate_argument(function, nodes, work, policy)?;
            }
        }
    }
    // Responses carries function calls directly in its input-item sequence.
    if let Some(items) = body.get("input").and_then(Value::as_array) {
        for item in items {
            if item.get("type").and_then(Value::as_str) == Some("function_call") {
                validate_argument(item, nodes, work, policy)?;
            }
        }
    }
    Ok(())
}

fn validate_argument(
    function: &Value,
    nodes: &mut usize,
    work: &mut usize,
    policy: ArgumentPolicy,
) -> Result<(), RenderError> {
    let Some(encoded) = function.get("arguments").and_then(Value::as_str) else {
        return Ok(());
    };
    validate_encoded_argument(encoded, nodes, work, policy)
}

/// The same bounded check is also used by direct MiMo normalization, not only
/// Planner. No fake request object/string clone is needed for that seam.
pub(crate) fn validate_mimo_encoded_argument(encoded: &str) -> Result<(), RenderError> {
    let mut nodes = MAX_NODES;
    let mut work = MAX_KEY_WORK_BYTES;
    validate_encoded_argument(
        encoded,
        &mut nodes,
        &mut work,
        ArgumentPolicy::MiMoObjectOrOpaque,
    )
}

fn validate_encoded_argument(
    encoded: &str,
    nodes: &mut usize,
    work: &mut usize,
    policy: ArgumentPolicy,
) -> Result<(), RenderError> {
    if encoded.len() > 4 << 20 {
        return Err(RenderError::UnsupportedInput);
    }
    if !matches!(policy, ArgumentPolicy::LegacyObjectOnly)
        && encoded.trim_start().starts_with(['{', '['])
    {
        validate_encoded_depth(encoded)?;
    }
    // Inspect before sanitize can remove a null member and conceal its
    // canonical collision. A parser resource/depth refusal must not turn valid
    // structured input into an apparently safe opaque string.
    if let Ok(decoded) = serde_json::from_str::<Value>(encoded) {
        // Swift decodeToolCallArguments decodes objects only. The current
        // normalizer decodes every valid JSON shape; do not pretend arrays or
        // scalars render identically until that contract is deliberately changed.
        if !decoded.is_object() {
            return if matches!(policy, ArgumentPolicy::LegacyObjectOnly) {
                Err(RenderError::UnsupportedInput)
            } else {
                // This remains an opaque STRING for MiMo. Do not interpret
                // an inner array/scalar's keys/numbers as typed parameter data.
                Ok(())
            };
        }
        visit(&decoded, 0, nodes, work)?;
    } else if encoded.trim_start().starts_with(['{', '['])
        && matches!(policy, ArgumentPolicy::LegacyObjectOnly)
    {
        // Both malformed and unsupported object/array-shaped arguments stay
        // cold. Ordinary non-JSON text keeps its existing opaque behavior.
        return Err(RenderError::UnsupportedInput);
    }
    Ok(())
}

/// Resource screening, not a second JSON parser. A shallow malformed encoded
/// string is legitimate opaque MiMo input; a recursive parser refusal is not.
/// Count only structural bytes outside strings and cap below serde's recursion
/// limit, so deep valid JSON cannot become raw after a parser stack refusal.
fn validate_encoded_depth(encoded: &str) -> Result<(), RenderError> {
    let (mut depth, mut quoted, mut escaped) = (0usize, false, false);
    for byte in encoded.bytes() {
        if quoted {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                quoted = false;
            }
        } else {
            match byte {
                b'"' => quoted = true,
                b'{' | b'[' => {
                    depth += 1;
                    if depth >= 128 {
                        return Err(RenderError::UnsupportedInput);
                    }
                }
                b'}' | b']' => depth = depth.saturating_sub(1),
                _ => {}
            }
        }
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
