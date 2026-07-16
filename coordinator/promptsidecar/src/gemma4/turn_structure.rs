use crate::normalize::NormalizeError;
use serde_json::{Map, Value};
use std::collections::HashMap;

pub(super) fn normalize(messages: Vec<Value>) -> Result<Vec<Value>, NormalizeError> {
    let repaired = repair_tool_result_placement(messages)?;
    Ok(merge_dangling_assistant_text(repaired))
}

fn repair_tool_result_placement(messages: Vec<Value>) -> Result<Vec<Value>, NormalizeError> {
    let mut owner_by_call_id = HashMap::<String, usize>::new();
    let mut last_tool_call_turn = None;
    let mut paired_results = HashMap::<usize, HashMap<String, Vec<Value>>>::new();
    let mut idless_results = HashMap::<usize, Vec<Value>>::new();
    let mut last_result_index_by_owner = HashMap::<usize, usize>::new();

    for (index, message) in messages.iter().enumerate() {
        let object = message.as_object().ok_or(NormalizeError::InvalidMessages)?;
        if object.get("role").and_then(Value::as_str) == Some("tool") {
            let owner = match object
                .get("tool_call_id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
            {
                Some(id) => *owner_by_call_id
                    .get(id)
                    .ok_or(NormalizeError::InvalidTools)?,
                None => last_tool_call_turn.ok_or(NormalizeError::InvalidTools)?,
            };
            if let Some(id) = object
                .get("tool_call_id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
            {
                paired_results
                    .entry(owner)
                    .or_default()
                    .entry(id.to_owned())
                    .or_default()
                    .push(message.clone());
            } else {
                idless_results
                    .entry(owner)
                    .or_default()
                    .push(message.clone());
            }
            last_result_index_by_owner.insert(owner, index);
            continue;
        }
        let calls = tool_calls(object);
        if !calls.is_empty() {
            last_tool_call_turn = Some(index);
            for call in calls {
                if let Some(id) = call_id(call) {
                    owner_by_call_id.insert(id.to_owned(), index);
                }
            }
        }
    }

    let mut output = Vec::with_capacity(messages.len());
    for (index, message) in messages.iter().enumerate() {
        let object = message.as_object().ok_or(NormalizeError::InvalidMessages)?;
        if object.get("role").and_then(Value::as_str) == Some("tool") {
            continue;
        }
        output.push(message.clone());
        let calls = tool_calls(object);
        if calls.is_empty() {
            continue;
        }

        let mut paired = paired_results.remove(&index).unwrap_or_default();
        let unanswered = calls
            .iter()
            .filter_map(|call| call_id(call))
            .filter(|id| !paired.contains_key(*id))
            .map(str::to_owned)
            .collect::<Vec<_>>();
        let idless_count = idless_results.get(&index).map_or(0, Vec::len);
        if unanswered.len().saturating_sub(idless_count) > 0 {
            let boundary = last_result_index_by_owner
                .get(&index)
                .copied()
                .unwrap_or(index)
                .max(index);
            if boundary < messages.len().saturating_sub(1) {
                return Err(NormalizeError::InvalidTools);
            }
        }

        for call in calls {
            if let Some(results) = call_id(call).and_then(|id| paired.remove(id)) {
                output.extend(results);
            }
        }
        let mut remaining_ids = paired.keys().cloned().collect::<Vec<_>>();
        remaining_ids.sort();
        for id in remaining_ids {
            if let Some(results) = paired.remove(&id) {
                output.extend(results);
            }
        }
        if let Some(results) = idless_results.remove(&index) {
            output.extend(results);
        }
    }
    Ok(output)
}

fn merge_dangling_assistant_text(mut messages: Vec<Value>) -> Vec<Value> {
    let mut output = Vec::with_capacity(messages.len());
    let mut index = 0;
    while index < messages.len() {
        if index + 1 < messages.len()
            && is_text_only_assistant(&messages[index])
            && messages[index + 1]
                .as_object()
                .and_then(|message| message.get("role"))
                .and_then(Value::as_str)
                == Some("assistant")
        {
            let earlier = messages[index].clone();
            merge_message(&earlier, &mut messages[index + 1]);
            index += 1;
            continue;
        }
        output.push(messages[index].clone());
        index += 1;
    }
    output
}

fn is_text_only_assistant(message: &Value) -> bool {
    let Some(message) = message.as_object() else {
        return false;
    };
    if message.get("role").and_then(Value::as_str) != Some("assistant") {
        return false;
    }
    if message
        .get("tool_calls")
        .and_then(Value::as_array)
        .is_some_and(|calls| !calls.is_empty())
        || message
            .get("tool_responses")
            .and_then(Value::as_array)
            .is_some_and(|responses| !responses.is_empty())
    {
        return false;
    }
    matches!(
        message.get("content"),
        None | Some(Value::Null | Value::String(_))
    )
}

fn merge_message(earlier: &Value, later: &mut Value) {
    let Some(earlier) = earlier.as_object() else {
        return;
    };
    let Some(later) = later.as_object_mut() else {
        return;
    };
    let prefix = earlier
        .get("content")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or_default();
    if !prefix.is_empty() {
        match later.get_mut("content") {
            Some(Value::String(content)) if content.is_empty() => *content = prefix.into(),
            Some(Value::String(content)) => *content = format!("{prefix}\n\n{content}"),
            Some(Value::Array(parts)) => {
                parts.insert(0, serde_json::json!({"type": "text", "text": prefix}));
            }
            _ => {
                later.insert("content".into(), Value::String(prefix.into()));
            }
        }
    }
    carry_reasoning(earlier, later);
}

fn carry_reasoning(earlier: &Map<String, Value>, later: &mut Map<String, Value>) {
    for key in ["thinking", "reasoning", "reasoning_content"] {
        let Some(carried) = earlier
            .get(key)
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
        else {
            continue;
        };
        let merged = match later.get(key).and_then(Value::as_str) {
            Some(existing) if !existing.is_empty() => format!("{carried}\n\n{existing}"),
            _ => carried.into(),
        };
        later.insert(key.into(), Value::String(merged));
    }
}

fn tool_calls(message: &Map<String, Value>) -> &[Value] {
    if message.get("role").and_then(Value::as_str) != Some("assistant") {
        return &[];
    }
    message
        .get("tool_calls")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
}

fn call_id(call: &Value) -> Option<&str> {
    call.as_object()?
        .get("id")?
        .as_str()
        .filter(|id| !id.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn repairs_results_and_consecutive_assistants() {
        let messages = vec![
            json!({"role":"assistant","content":"prefix"}),
            json!({"role":"assistant","content":"","tool_calls":[{
                "id":"a","type":"function","function":{"name":"f","arguments":{}}
            }]}),
            json!({"role":"user","content":"later"}),
            json!({"role":"tool","tool_call_id":"a","content":"ok"}),
        ];
        let normalized = normalize(messages).unwrap();
        assert_eq!(normalized[0]["content"], "prefix");
        assert_eq!(normalized[1]["role"], "tool");
        assert_eq!(normalized[2]["role"], "user");
    }

    #[test]
    fn rejects_unanswered_mid_history_tool_turn() {
        let messages = vec![
            json!({"role":"assistant","content":"","tool_calls":[{
                "id":"a","type":"function","function":{"name":"f","arguments":{}}
            }]}),
            json!({"role":"user","content":"later"}),
        ];
        assert!(normalize(messages).is_err());
    }
}
