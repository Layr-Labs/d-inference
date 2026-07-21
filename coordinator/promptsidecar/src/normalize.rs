use serde_json::{Map, Value, json};
use std::collections::HashSet;
use thiserror::Error;

const ORIGINAL_BOOLEAN_SCHEMA_KEY: &str = "x-darkbloom-original-boolean-schema";

#[derive(Clone, Debug)]
pub struct NormalizedRequest {
    pub messages: Vec<Value>,
    pub tools: Option<Vec<Value>>,
    pub additional_context: Map<String, Value>,
    pub body: Value,
}

#[derive(Debug, Error)]
pub enum NormalizeError {
    #[error("request model is missing")]
    MissingModel,
    #[error("request messages are invalid")]
    InvalidMessages,
    #[error("request tool payload is invalid")]
    InvalidTools,
    #[error("request role is unsupported")]
    InvalidRole,
}

pub fn normalize(
    mut body: Map<String, Value>,
    model_type: Option<&str>,
) -> Result<NormalizedRequest, NormalizeError> {
    let model_id = body
        .get("model")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(NormalizeError::MissingModel)?
        .to_owned();

    validate_raw_auto_tool_schemas(&body)?;
    normalize_tool_parameter_types(&mut body);
    normalize_legacy_function_calls(&mut body)?;
    let mut messages = template_messages(&body)?;
    let mut tools = template_tools(&body)?;
    apply_tool_choice_policy(&body, &mut messages, &mut tools)?;
    messages = sanitize_array(messages);
    tools = tools.map(sanitize_array);
    validate_tool_history(&messages)?;

    if is_harmony(Some(&model_id), model_type) {
        messages = harmony_messages(messages)?;
        tools = tools.map(harmony_tools);
    } else if crate::gemma4::applies(&model_id, model_type) {
        messages = crate::gemma4::normalize_messages(messages)?;
        tools = tools.map(crate::gemma4::normalize_tools);
    }

    let mut additional_context = Map::new();
    if let Some(effort) = body
        .get("reasoning_effort")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        additional_context.insert("reasoning_effort".into(), Value::String(effort.into()));
    }
    match body.get("reasoning") {
        None | Some(Value::Null) => {}
        Some(Value::Object(reasoning)) => match reasoning.get("enabled") {
            None | Some(Value::Null) => {}
            Some(Value::Bool(enabled)) => {
                additional_context.insert("enable_thinking".into(), Value::Bool(*enabled));
            }
            Some(_) => return Err(NormalizeError::InvalidMessages),
        },
        Some(_) => return Err(NormalizeError::InvalidMessages),
    }

    let mut normalized_body = Map::new();
    normalized_body.insert("model".into(), Value::String(model_id.clone()));
    normalized_body.insert("messages".into(), Value::Array(messages.clone()));
    if let Some(tools) = &tools {
        normalized_body.insert("tools".into(), Value::Array(tools.clone()));
    }
    if !additional_context.is_empty() {
        normalized_body.insert(
            "additional_context".into(),
            Value::Object(additional_context.clone()),
        );
    }

    Ok(NormalizedRequest {
        messages,
        tools,
        additional_context,
        body: Value::Object(normalized_body),
    })
}

fn template_messages(body: &Map<String, Value>) -> Result<Vec<Value>, NormalizeError> {
    let messages = body
        .get("messages")
        .and_then(Value::as_array)
        .ok_or(NormalizeError::InvalidMessages)?;
    messages
        .iter()
        .map(|value| {
            let input = value.as_object().ok_or(NormalizeError::InvalidMessages)?;
            let role = match input.get("role").and_then(Value::as_str) {
                Some("developer") => "system",
                Some("function") => "tool",
                Some(value @ ("system" | "user" | "assistant" | "tool")) => value,
                _ => return Err(NormalizeError::InvalidRole),
            };
            let mut message = Map::new();
            message.insert("role".into(), Value::String(role.into()));
            message.insert(
                "content".into(),
                Value::String(message_text(input.get("content"))?),
            );
            for key in ["name", "tool_call_id", "reasoning_content"] {
                match input.get(key) {
                    None | Some(Value::Null) => {}
                    Some(Value::String(value)) => {
                        message.insert(key.into(), Value::String(value.clone()));
                    }
                    Some(_) => return Err(NormalizeError::InvalidMessages),
                }
            }
            match input.get("tool_calls") {
                None | Some(Value::Null) => {}
                Some(Value::Array(calls)) if calls.is_empty() => {}
                Some(Value::Array(calls)) => {
                    message.insert(
                        "tool_calls".into(),
                        Value::Array(
                            calls
                                .iter()
                                .map(template_tool_call)
                                .collect::<Result<Vec<_>, _>>()?,
                        ),
                    );
                }
                Some(_) => return Err(NormalizeError::InvalidTools),
            }
            Ok(Value::Object(message))
        })
        .collect()
}

fn template_tool_call(value: &Value) -> Result<Value, NormalizeError> {
    let call = value.as_object().ok_or(NormalizeError::InvalidTools)?;
    let function = call
        .get("function")
        .and_then(Value::as_object)
        .ok_or(NormalizeError::InvalidTools)?;
    let name = function
        .get("name")
        .and_then(Value::as_str)
        .ok_or(NormalizeError::InvalidTools)?;
    let encoded = function
        .get("arguments")
        .and_then(Value::as_str)
        .ok_or(NormalizeError::InvalidTools)?;
    let arguments =
        serde_json::from_str(encoded).unwrap_or_else(|_| Value::String(encoded.to_owned()));
    let id = call
        .get("id")
        .and_then(Value::as_str)
        .ok_or(NormalizeError::InvalidTools)?;
    let kind = call
        .get("type")
        .and_then(Value::as_str)
        .ok_or(NormalizeError::InvalidTools)?;
    match call.get("index") {
        None | Some(Value::Null) => {}
        Some(Value::Number(index)) if index.as_i64().is_some() || index.as_u64().is_some() => {}
        Some(_) => return Err(NormalizeError::InvalidTools),
    };
    Ok(json!({
        "id": id,
        "type": kind,
        "function": {"name": name, "arguments": arguments},
    }))
}

fn message_text(content: Option<&Value>) -> Result<String, NormalizeError> {
    match content {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(text)) => Ok(text.clone()),
        Some(Value::Array(parts)) => {
            let mut text = String::new();
            for part in parts {
                let object = part.as_object().ok_or(NormalizeError::InvalidMessages)?;
                let kind = object
                    .get("type")
                    .and_then(Value::as_str)
                    .ok_or(NormalizeError::InvalidMessages)?;
                if matches!(kind, "text" | "input_text") {
                    text.push_str(
                        object
                            .get("text")
                            .and_then(Value::as_str)
                            .ok_or(NormalizeError::InvalidMessages)?,
                    );
                }
            }
            Ok(text)
        }
        Some(_) => Err(NormalizeError::InvalidMessages),
    }
}

fn template_tools(body: &Map<String, Value>) -> Result<Option<Vec<Value>>, NormalizeError> {
    let raw = match body.get("tools") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Array(raw)) => raw,
        Some(_) => return Err(NormalizeError::InvalidTools),
    };
    let mut tools = Vec::new();
    for value in raw {
        let Some(tool) = value.as_object() else {
            continue;
        };
        let function = match tool.get("function").and_then(Value::as_object) {
            Some(function) => validate_function_definition(function)
                .or_else(|_| top_level_function_definition(tool))?,
            None => match top_level_function_definition(tool) {
                Ok(function) => function,
                Err(_) => continue,
            },
        };
        tools.push(json!({
            "type": tool.get("type").and_then(Value::as_str).unwrap_or("function"),
            "function": function,
        }));
    }
    Ok(Some(tools))
}

fn top_level_function_definition(
    tool: &Map<String, Value>,
) -> Result<Map<String, Value>, NormalizeError> {
    let name = tool
        .get("name")
        .and_then(Value::as_str)
        .ok_or(NormalizeError::InvalidTools)?;
    let mut function = Map::new();
    function.insert("name".into(), Value::String(name.into()));
    match tool.get("description") {
        None | Some(Value::Null) => {}
        Some(Value::String(description)) => {
            function.insert("description".into(), Value::String(description.clone()));
        }
        Some(_) => return Err(NormalizeError::InvalidTools),
    }
    if let Some(parameters) = tool.get("parameters").or_else(|| tool.get("input_schema")) {
        function.insert("parameters".into(), parameters.clone());
    }
    Ok(function)
}

fn validate_function_definition(
    function: &Map<String, Value>,
) -> Result<Map<String, Value>, NormalizeError> {
    function
        .get("name")
        .and_then(Value::as_str)
        .ok_or(NormalizeError::InvalidTools)?;
    match function.get("description") {
        None | Some(Value::Null | Value::String(_)) => {}
        Some(_) => return Err(NormalizeError::InvalidTools),
    }
    Ok(function.clone())
}

fn validate_raw_auto_tool_schemas(body: &Map<String, Value>) -> Result<(), NormalizeError> {
    let choice = body.get("tool_choice");
    let mode = choice.and_then(Value::as_str).or_else(|| {
        choice
            .and_then(Value::as_object)
            .and_then(|object| object.get("type"))
            .and_then(Value::as_str)
    });
    if choice.is_some() && mode != Some("auto") {
        return Ok(());
    }
    let tools = body
        .get("tools")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    crate::tool_constraint::validate_auto_tool_patterns(tools)
}

fn normalize_legacy_function_calls(body: &mut Map<String, Value>) -> Result<(), NormalizeError> {
    let Some(messages) = body.get_mut("messages").and_then(Value::as_array_mut) else {
        return Ok(());
    };
    for (index, message) in messages.iter_mut().enumerate() {
        let Some(object) = message.as_object_mut() else {
            continue;
        };
        if object.get("role").and_then(Value::as_str) != Some("assistant")
            || object.contains_key("tool_calls")
        {
            continue;
        }
        let Some(function_call) = object.remove("function_call") else {
            continue;
        };
        if function_call.is_null() {
            continue;
        }
        let function = function_call
            .as_object()
            .ok_or(NormalizeError::InvalidTools)?;
        let name = function
            .get("name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .ok_or(NormalizeError::InvalidTools)?;
        let arguments = match function.get("arguments") {
            None | Some(Value::Null) => "{}".into(),
            Some(Value::String(value)) => value.clone(),
            Some(value @ (Value::Object(_) | Value::Array(_))) => {
                serde_json::to_string(value).map_err(|_| NormalizeError::InvalidTools)?
            }
            _ => return Err(NormalizeError::InvalidTools),
        };
        object.insert(
            "content".into(),
            object.get("content").cloned().unwrap_or(Value::Null),
        );
        object.insert(
            "tool_calls".into(),
            json!([{
                "id": format!("call_legacy_{index}"),
                "type": "function",
                "function": {"name": name, "arguments": arguments},
            }]),
        );
    }
    Ok(())
}

fn normalize_tool_parameter_types(body: &mut Map<String, Value>) {
    let Some(tools) = body.get_mut("tools").and_then(Value::as_array_mut) else {
        return;
    };
    for tool in tools {
        let Some(function) = tool
            .as_object_mut()
            .and_then(|tool| tool.get_mut("function"))
            .and_then(Value::as_object_mut)
        else {
            continue;
        };
        if let Some(parameters) = function.get_mut("parameters") {
            inject_schema_types(parameters, false);
        }
    }
}

fn inject_schema_types(node: &mut Value, positional: bool) {
    if positional && let Some(accepts) = node.as_bool() {
        *node = json!({
            "type": "string",
            (ORIGINAL_BOOLEAN_SCHEMA_KEY): accepts
        });
        return;
    }
    if let Some(array) = node.as_array_mut() {
        for child in array {
            inject_schema_types(child, positional);
        }
        return;
    }
    let Some(object) = node.as_object_mut() else {
        return;
    };
    for key in ["properties", "patternProperties"] {
        if let Some(properties) = object.get_mut(key).and_then(Value::as_object_mut) {
            for child in properties.values_mut() {
                inject_schema_types(child, true);
            }
        }
    }
    if let Some(items) = object.get_mut("items") {
        inject_schema_types(items, true);
    }
    if let Some(prefix_items) = object.get_mut("prefixItems").and_then(Value::as_array_mut) {
        for child in prefix_items {
            inject_schema_types(child, true);
        }
    }
    if let Some(additional) = object
        .get_mut("additionalProperties")
        .filter(|value| value.is_object())
    {
        inject_schema_types(additional, true);
    }
    for key in ["anyOf", "oneOf", "allOf"] {
        if let Some(variants) = object.get_mut(key).and_then(Value::as_array_mut) {
            for variant in variants {
                inject_schema_types(variant, true);
            }
        }
    }
    if !object.contains_key("type")
        && nullable_combinator_union(object)
        && object.get("nullable") != Some(&Value::Bool(true))
    {
        object.insert("nullable".into(), Value::Bool(true));
    }
    // A typeless node whose const/enum admits null beside a concrete value
    // keeps null validity through the standard `nullable` key, exactly like
    // the array-form type collapse below.
    if !object.contains_key("type")
        && let Some((concrete, saw_null)) = finite_value_types(object)
        && saw_null
        && !concrete.is_empty()
        && object.get("nullable") != Some(&Value::Bool(true))
    {
        object.insert("nullable".into(), Value::Bool(true));
    }
    if let Some(Value::Array(types)) = object.get("type") {
        let members = types
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_ascii_lowercase)
            .collect::<Vec<_>>();
        if members.iter().any(|value| value == "null")
            && members.iter().any(|value| value != "null")
            && object.get("nullable") != Some(&Value::Bool(true))
        {
            object.insert("nullable".into(), Value::Bool(true));
        }
        object.insert(
            "type".into(),
            Value::String(
                members
                    .iter()
                    .find(|value| value.as_str() != "null")
                    .or_else(|| members.first())
                    .cloned()
                    .unwrap_or_else(|| inferred_schema_type(object)),
            ),
        );
    } else if object.get("type").is_some_and(|value| !value.is_string()) {
        let inferred = inferred_schema_type(object);
        object.insert("type".into(), Value::String(inferred));
    }
    let looks_like_schema = [
        "properties",
        "patternProperties",
        "items",
        "prefixItems",
        "additionalProperties",
        "enum",
        "description",
        "anyOf",
        "oneOf",
        "allOf",
    ]
    .iter()
    .any(|key| object.contains_key(*key));
    if !object.contains_key("type") && (positional || looks_like_schema) {
        let inferred = inferred_schema_type(object);
        object.insert("type".into(), Value::String(inferred));
    }
    if object
        .get("type")
        .and_then(Value::as_str)
        .is_some_and(|kind| kind.eq_ignore_ascii_case("object"))
        && !object.get("properties").is_some_and(Value::is_object)
    {
        object.insert("properties".into(), Value::Object(Map::new()));
    }
}

fn nullable_combinator_union(object: &Map<String, Value>) -> bool {
    for key in ["anyOf", "oneOf"] {
        let Some(variants) = object.get(key).and_then(Value::as_array) else {
            continue;
        };
        let mut has_null = false;
        let mut has_concrete = false;
        for variant in variants {
            let Some(variant) = variant.as_object() else {
                continue;
            };
            has_null |= variant.get("nullable") == Some(&Value::Bool(true));
            match variant.get("type") {
                Some(Value::String(member)) => {
                    has_null |= member.eq_ignore_ascii_case("null");
                    has_concrete |= !member.eq_ignore_ascii_case("null");
                }
                Some(Value::Array(members)) => {
                    for member in members.iter().filter_map(Value::as_str) {
                        has_null |= member.eq_ignore_ascii_case("null");
                        has_concrete |= !member.eq_ignore_ascii_case("null");
                    }
                }
                _ => {}
            }
        }
        if has_null && has_concrete {
            return true;
        }
    }
    false
}

fn inferred_schema_type(object: &Map<String, Value>) -> String {
    if object.contains_key("properties")
        || object.contains_key("patternProperties")
        || object.contains_key("additionalProperties")
    {
        return "object".into();
    }
    if object.contains_key("items") || object.contains_key("prefixItems") {
        return "array".into();
    }
    for key in ["anyOf", "oneOf", "allOf"] {
        if let Some(variants) = object.get(key).and_then(Value::as_array)
            && let Some(kind) = variants.iter().find_map(|variant| {
                variant
                    .as_object()?
                    .get("type")?
                    .as_str()
                    .filter(|kind| *kind != "null")
            })
        {
            return kind.into();
        }
    }
    // A typeless `{"const":1}` accepts 1, so the injected render type must be
    // "number", not "string" — the string default would make every
    // schema-valid emission fail post-generation validation.
    if let Some((concrete, saw_null)) = finite_value_types(object) {
        if concrete.len() == 1 {
            return concrete.into_iter().next().expect("single member");
        }
        if concrete.is_empty() && saw_null {
            return "null".into();
        }
    }
    "string".into()
}

/// JSON type names of a node's const/enum values: the set of concrete
/// (non-null) member types plus whether null appears. `None` when the node
/// carries no const and no non-empty enum array.
pub(crate) fn finite_value_types(object: &Map<String, Value>) -> Option<(HashSet<String>, bool)> {
    let values: Vec<&Value> = if let Some(constant) = object.get("const") {
        vec![constant]
    } else if let Some(members) = object.get("enum").and_then(Value::as_array) {
        if members.is_empty() {
            return None;
        }
        members.iter().collect()
    } else {
        return None;
    };
    let mut concrete = HashSet::new();
    let mut saw_null = false;
    for value in values {
        match value {
            Value::Null => saw_null = true,
            Value::Bool(_) => {
                concrete.insert("boolean".to_owned());
            }
            Value::Number(_) => {
                concrete.insert("number".to_owned());
            }
            Value::String(_) => {
                concrete.insert("string".to_owned());
            }
            Value::Array(_) => {
                concrete.insert("array".to_owned());
            }
            Value::Object(_) => {
                concrete.insert("object".to_owned());
            }
        }
    }
    Some((concrete, saw_null))
}

fn apply_tool_choice_policy(
    body: &Map<String, Value>,
    messages: &mut Vec<Value>,
    tools: &mut Option<Vec<Value>>,
) -> Result<(), NormalizeError> {
    validate_tool_names(tools.as_deref().unwrap_or_default())?;
    if let Some(parallel) = body.get("parallel_tool_calls")
        && !parallel.is_boolean()
        && !parallel.is_null()
    {
        return Err(NormalizeError::InvalidTools);
    }
    let choice = body.get("tool_choice");
    let mode = choice.and_then(Value::as_str).or_else(|| {
        choice
            .and_then(Value::as_object)
            .and_then(|object| object.get("type"))
            .and_then(Value::as_str)
    });
    if choice.is_none() || mode == Some("auto") {
        return Ok(());
    }
    if mode == Some("none") {
        add_instruction(
            messages,
            "Do not call any tool. Answer the user directly without emitting a tool call.",
            false,
        );
        *tools = None;
        return Ok(());
    }
    if !matches!(mode, Some("required" | "function")) {
        return Err(NormalizeError::InvalidTools);
    }
    let selected_name = if mode == Some("function") {
        let object = choice
            .and_then(Value::as_object)
            .ok_or(NormalizeError::InvalidTools)?;
        let top_level = object.get("name").and_then(Value::as_str);
        let nested = object
            .get("function")
            .and_then(Value::as_object)
            .and_then(|function| function.get("name"))
            .and_then(Value::as_str);
        if top_level.is_some() && nested.is_some() && top_level != nested {
            return Err(NormalizeError::InvalidTools);
        }
        Some(top_level.or(nested).ok_or(NormalizeError::InvalidTools)?)
    } else {
        None
    };
    let declared = tools
        .as_ref()
        .filter(|tools| !tools.is_empty())
        .ok_or(NormalizeError::InvalidTools)?;
    let instruction = if let Some(name) = selected_name {
        if !declared.iter().any(|tool| tool_name(tool) == Some(name)) {
            return Err(NormalizeError::InvalidTools);
        }
        crate::tool_constraint::validate_selected_constrained_tool(declared, name)?;
        *tools = Some(
            declared
                .iter()
                .filter(|tool| tool_name(tool) == Some(name))
                .cloned()
                .collect(),
        );
        format!(
            "Call the declared function '{name}' now. You must emit a '{name}' tool call with valid arguments before any final answer, even when another function seems more relevant. Your entire response must be that tool call; a text answer is forbidden. For any required string argument without an obvious value, use the user's request text."
        )
    } else if declared.len() == 1 {
        crate::tool_constraint::validate_constrained_tools(declared)?;
        let name = tool_name(&declared[0]).ok_or(NormalizeError::InvalidTools)?;
        format!(
            "Call the declared function '{name}' now. You must emit a tool call with valid arguments before any final answer, even when the user's request does not require the tool. Your entire response must be the tool call; a text answer is forbidden. For any required string argument without an obvious value, use the user's request text."
        )
    } else {
        crate::tool_constraint::validate_constrained_tools(declared)?;
        "Call one of the declared tools now. You must emit a tool call with valid arguments before any final answer, even when the user's request does not require a tool. Your entire response must be the tool call; a text answer is forbidden.".into()
    };
    add_instruction(messages, &instruction, true);
    Ok(())
}

fn add_instruction(messages: &mut Vec<Value>, instruction: &str, repeat_user: bool) {
    if messages
        .first()
        .and_then(Value::as_object)
        .and_then(|message| message.get("role"))
        .and_then(Value::as_str)
        == Some("system")
    {
        append_content(&mut messages[0], instruction);
    } else {
        messages.insert(0, json!({"role": "system", "content": instruction}));
    }
    if repeat_user
        && let Some(index) = messages.iter().rposition(|message| {
            message
                .as_object()
                .and_then(|message| message.get("role"))
                .and_then(Value::as_str)
                == Some("user")
        })
    {
        append_content(&mut messages[index], instruction);
    }
}

fn append_content(message: &mut Value, instruction: &str) {
    let object = message.as_object_mut().expect("normalized message");
    let content = object
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default();
    object.insert(
        "content".into(),
        Value::String(if content.is_empty() {
            instruction.into()
        } else {
            format!("{content}\n\n{instruction}")
        }),
    );
}

fn validate_tool_names(tools: &[Value]) -> Result<(), NormalizeError> {
    let mut names = HashSet::new();
    for tool in tools {
        let name = tool_name(tool).ok_or(NormalizeError::InvalidTools)?;
        if name.is_empty()
            || name.len() > 64
            || !name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
        {
            return Err(NormalizeError::InvalidTools);
        }
        if !names.insert(name) {
            return Err(NormalizeError::InvalidTools);
        }
    }
    Ok(())
}

fn tool_name(tool: &Value) -> Option<&str> {
    tool.as_object()?
        .get("function")?
        .as_object()?
        .get("name")?
        .as_str()
}

fn sanitize_array(values: Vec<Value>) -> Vec<Value> {
    values.into_iter().filter_map(sanitize).collect()
}

fn sanitize(value: Value) -> Option<Value> {
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

fn validate_tool_history(messages: &[Value]) -> Result<(), NormalizeError> {
    let mut allowed = false;
    for message in messages {
        let object = message.as_object().ok_or(NormalizeError::InvalidMessages)?;
        match object.get("role").and_then(Value::as_str) {
            Some("assistant") => {
                let calls = object.get("tool_calls").and_then(Value::as_array);
                allowed = calls.is_some_and(|calls| !calls.is_empty());
                if allowed
                    && calls
                        .and_then(|calls| calls.first())
                        .and_then(first_call_name)
                        .is_none()
                {
                    return Err(NormalizeError::InvalidTools);
                }
            }
            Some("tool") if !allowed => return Err(NormalizeError::InvalidTools),
            Some("tool") => {}
            _ => allowed = false,
        }
    }
    Ok(())
}

fn first_call_name(call: &Value) -> Option<&str> {
    let object = call.as_object()?;
    object
        .get("function")
        .and_then(Value::as_object)
        .and_then(|function| function.get("name"))
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
        .or_else(|| {
            object
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
        })
}

fn is_harmony(model_id: Option<&str>, model_type: Option<&str>) -> bool {
    [model_id, model_type].into_iter().flatten().any(|hint| {
        let hint = hint.to_ascii_lowercase();
        hint.contains("gpt-oss") || hint.contains("gpt_oss") || hint.contains("gptoss")
    })
}

fn harmony_messages(messages: Vec<Value>) -> Result<Vec<Value>, NormalizeError> {
    let mut bridged = messages;
    for message in &mut bridged {
        let object = message
            .as_object_mut()
            .ok_or(NormalizeError::InvalidMessages)?;
        if object.get("role").and_then(Value::as_str) == Some("assistant")
            && !object.contains_key("thinking")
            && let Some(reasoning) = object
                .get("reasoning_content")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
        {
            object.insert("thinking".into(), Value::String(reasoning.into()));
        }
    }
    split_harmony_tool_calls(bridged)
}

fn split_harmony_tool_calls(messages: Vec<Value>) -> Result<Vec<Value>, NormalizeError> {
    let mut output = Vec::with_capacity(messages.len());
    let mut index = 0;
    while index < messages.len() {
        let object = messages[index]
            .as_object()
            .ok_or(NormalizeError::InvalidMessages)?;
        let Some(calls) = object
            .get("tool_calls")
            .and_then(Value::as_array)
            .filter(|calls| {
                object.get("role").and_then(Value::as_str) == Some("assistant") && !calls.is_empty()
            })
        else {
            output.push(messages[index].clone());
            index += 1;
            continue;
        };
        let content = object
            .get("content")
            .and_then(Value::as_str)
            .filter(|content| !content.is_empty());
        let thinking = object
            .get("thinking")
            .or_else(|| object.get("reasoning_content"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty());
        if calls.len() == 1 && !(content.is_some() && thinking.is_some()) {
            output.push(messages[index].clone());
            index += 1;
            continue;
        }

        let mut results = Map::new();
        let mut result_order = Vec::new();
        let mut next = index + 1;
        while next < messages.len() {
            let Some(result) = messages[next].as_object() else {
                break;
            };
            if result.get("role").and_then(Value::as_str) != Some("tool") {
                break;
            }
            if let Some(id) = result.get("tool_call_id").and_then(Value::as_str) {
                results.insert(id.into(), messages[next].clone());
                result_order.push(id.to_owned());
            }
            next += 1;
        }
        if let Some(thinking) = thinking {
            output.push(json!({"role": "assistant", "thinking": thinking}));
        }
        let mut consumed = std::collections::HashSet::new();
        for (call_index, call) in calls.iter().enumerate() {
            let mut turn = json!({"role": "assistant", "tool_calls": [call]});
            if call_index == 0
                && let Some(content) = content
            {
                turn.as_object_mut()
                    .unwrap()
                    .insert("content".into(), Value::String(content.into()));
            }
            output.push(turn);
            if let Some(id) = call
                .as_object()
                .and_then(|call| call.get("id"))
                .and_then(Value::as_str)
                && let Some(result) = results.get(id)
            {
                output.push(result.clone());
                consumed.insert(id.to_owned());
            }
        }
        if result_order.iter().any(|id| !consumed.contains(id)) {
            return Err(NormalizeError::InvalidTools);
        }
        index = next;
    }
    Ok(output)
}

fn harmony_tools(tools: Vec<Value>) -> Vec<Value> {
    tools.into_iter().map(harmony_tool).collect()
}

fn harmony_tool(mut tool: Value) -> Value {
    let Some(function) = tool
        .as_object_mut()
        .and_then(|tool| tool.get_mut("function"))
        .and_then(Value::as_object_mut)
    else {
        return tool;
    };
    if !function.get("description").is_some_and(Value::is_string) {
        function.insert("description".into(), Value::String(String::new()));
    }
    if let Some(parameters) = function.get_mut("parameters") {
        normalize_harmony_schema(parameters);
    }
    tool
}

fn normalize_harmony_schema(value: &mut Value) {
    let Some(object) = value.as_object_mut() else {
        if let Some(array) = value.as_array_mut() {
            for item in array {
                normalize_harmony_schema(item);
            }
        }
        return;
    };
    if object.contains_key("description")
        && !object.get("description").is_some_and(Value::is_string)
    {
        object.insert("description".into(), Value::String(String::new()));
    }
    if let Some(properties) = object.get_mut("properties").and_then(Value::as_object_mut) {
        for child in properties.values_mut() {
            normalize_harmony_schema(child);
        }
    } else if object.contains_key("properties") {
        object.remove("properties");
    }
    if let Some(items) = object.get_mut("items") {
        if items.is_object() {
            normalize_harmony_schema(items);
        } else {
            object.remove("items");
        }
    }
    if let Some(required) = object.get_mut("required") {
        if let Some(values) = required.as_array_mut() {
            values.retain(Value::is_string);
        } else {
            object.remove("required");
        }
    }
    if let Some(values) = object.get_mut("enum") {
        if let Some(values) = values.as_array_mut() {
            for value in values {
                normalize_harmony_schema(value);
            }
        } else {
            object.remove("enum");
        }
    }
    for key in ["oneOf", "anyOf", "allOf"] {
        if let Some(values) = object.get_mut(key) {
            if let Some(values) = values.as_array_mut() {
                values.retain(Value::is_object);
                for value in values {
                    normalize_harmony_schema(value);
                }
            } else {
                object.remove(key);
            }
        }
    }
    let has_variants = ["enum", "oneOf"].iter().any(|key| {
        object
            .get(*key)
            .and_then(Value::as_array)
            .is_some_and(|values| !values.is_empty())
    });
    if has_variants
        && object
            .get("default")
            .is_some_and(|value| !value.is_string())
    {
        let rendered = scalar_string(object.get("default").unwrap());
        object.insert("default".into(), Value::String(rendered));
    }
}

fn scalar_string(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn sanitizes_nulls_and_decodes_tool_arguments() {
        let body = json!({
            "model":"m",
            "messages":[
                {"role":"assistant","content":null,"tool_calls":[{
                    "id":"c","type":"function",
                    "function":{"name":"f","arguments":"{\"x\":null,\"y\":1}"}
                }]},
                {"role":"tool","tool_call_id":"c","content":"ok"}
            ]
        })
        .as_object()
        .unwrap()
        .clone();
        let normalized = normalize(body, None).unwrap();
        assert_eq!(
            normalized.messages[0]["tool_calls"][0]["function"]["arguments"],
            json!({"y": 1})
        );
    }

    #[test]
    fn harmony_splits_parallel_calls_by_id() {
        let body = json!({
            "model":"gpt-oss-20b",
            "messages":[
                {"role":"assistant","content":"","tool_calls":[
                    {"id":"a","type":"function","function":{"name":"f","arguments":"{}"}},
                    {"id":"b","type":"function","function":{"name":"g","arguments":"{}"}}
                ]},
                {"role":"tool","tool_call_id":"b","content":"B"},
                {"role":"tool","tool_call_id":"a","content":"A"}
            ]
        })
        .as_object()
        .unwrap()
        .clone();
        let normalized = normalize(body, Some("gpt_oss")).unwrap();
        assert_eq!(normalized.messages[1]["tool_call_id"], "a");
        assert_eq!(normalized.messages[3]["tool_call_id"], "b");
    }

    #[test]
    fn injects_types_into_nested_tool_properties() {
        let body = json!({
            "model":"gemma-4-fixture",
            "messages":[{"role":"user","content":"weather"}],
            "tools":[{
                "type":"function",
                "function":{
                    "name":"weather",
                    "parameters":{
                        "properties":{
                            "city":{"description":"city name"},
                            "days":{"items":{"enum":[1,2]}},
                            "optional":{
                                "type":["STRING","NULL"],
                                "nullable":false,
                                "enum":[null]
                            }
                        }
                    }
                }
            }]
        })
        .as_object()
        .unwrap()
        .clone();
        let normalized = normalize(body, Some("gemma4_text")).unwrap();
        let parameters = &normalized.tools.as_ref().unwrap()[0]["function"]["parameters"];
        assert_eq!(parameters["type"], "object");
        assert_eq!(parameters["properties"]["city"]["type"], "string");
        assert_eq!(parameters["properties"]["days"]["type"], "array");
        // A typeless enum node keeps its value semantics: `[1,2]` is a number
        // enum, so the injected render type must be "number" — the old string
        // default made every schema-valid numeric emission fail validation.
        assert_eq!(parameters["properties"]["days"]["items"]["type"], "number");
        assert_eq!(parameters["properties"]["optional"]["type"], "string");
        assert_eq!(parameters["properties"]["optional"]["nullable"], true);
    }

    #[test]
    fn typeless_finite_values_keep_original_semantics() {
        let body = json!({
            "model":"gemma-4-fixture",
            "messages":[{"role":"user","content":"x"}],
            "tools":[{"type":"function","function":{
                "name":"pick",
                "parameters":{"type":"object","properties":{
                    "count":{"const":1},
                    "level":{"enum":[1,2,null]},
                    "flag":{"const":true},
                    "tag":{"enum":["a","b"]},
                    "none":{"const":null}
                }}
            }}],
            "tool_choice":"auto"
        });
        let normalized = normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).unwrap();
        let tools = normalized.tools.unwrap();
        let properties = &tools[0]["function"]["parameters"]["properties"];
        assert_eq!(properties["count"]["type"], "number");
        assert!(properties["count"].get("nullable").is_none());
        assert_eq!(properties["level"]["type"], "number");
        assert_eq!(properties["level"]["nullable"], true);
        assert_eq!(properties["flag"]["type"], "boolean");
        assert_eq!(properties["tag"]["type"], "string");
        assert_eq!(properties["none"]["type"], "null");
    }

    #[test]
    fn typeless_mixed_finite_values_are_rejected_before_normalization() {
        for value in [json!({"enum":["a",1]}), json!({"enum":[true,"on"]})] {
            let body = json!({
                "model":"gemma-4-fixture",
                "messages":[{"role":"user","content":"x"}],
                "tools":[{"type":"function","function":{
                    "name":"pick",
                    "parameters":{"type":"object","properties":{"value":value}}
                }}],
                "tool_choice":"auto"
            });
            assert!(normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).is_err());
        }
    }

    #[test]
    fn unevaluated_assertions_are_rejected_before_inference() {
        for value in [
            json!({"type":"object","unevaluatedProperties":false}),
            json!({"type":"array","items":{"type":"string"},"unevaluatedItems":false}),
        ] {
            let body = json!({
                "model":"gemma-4-fixture",
                "messages":[{"role":"user","content":"x"}],
                "tools":[{"type":"function","function":{
                    "name":"pick",
                    "parameters":{"type":"object","properties":{"value":value}}
                }}],
                "tool_choice":"auto"
            });
            assert!(normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).is_err());
        }
    }

    #[test]
    fn rejects_shapes_the_swift_request_decoder_rejects() {
        for body in [
            json!({
                "model":"m",
                "messages":[{"role":"user","content":[7]}]
            }),
            json!({
                "model":"m",
                "messages":[{"role":"assistant","content":null,"tool_calls":[{
                    "type":"function","function":{"name":"f","arguments":"{}"}
                }]}]
            }),
            json!({
                "model":"m",
                "messages":[{"role":"user","content":"x"}],
                "tools":{"type":"function"}
            }),
        ] {
            assert!(normalize(body.as_object().unwrap().clone(), None).is_err());
        }
    }

    #[test]
    fn constrained_schema_subset_matches_swift_policy() {
        let supported = json!({
            "model":"gemma-4-fixture",
            "messages":[{"role":"user","content":"weather"}],
            "parallel_tool_calls":false,
            "tools":[{"type":"function","function":{
                "name":"weather",
                "parameters":{
                    "type":"object",
                    "properties":{
                        "city":{"type":"string","enum":["Paris","Tokyo"]},
                        "days":{"type":["integer","null"]},
                        "units":{"type":"array","items":{"type":"string"},"maxItems":3}
                    },
                    "required":["city"],
                    "additionalProperties":false
                }
            }}],
            "tool_choice":"required"
        });
        assert!(normalize(supported.as_object().unwrap().clone(), Some("gemma4_text")).is_ok());

        for unsupported in [
            json!({"oneOf":[{"type":"string"},{"type":"integer"}]}),
            json!({"type":"string","pattern":"^x$"}),
            json!({"type":"array","items":{"type":"string"},"maxItems":17}),
        ] {
            let body = json!({
                "model":"gemma-4-fixture",
                "messages":[{"role":"user","content":"x"}],
                "tools":[{"type":"function","function":{
                    "name":"f",
                    "parameters":{"type":"object","properties":{"x":unsupported}}
                }}],
                "tool_choice":"required"
            });
            assert!(normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).is_err());
        }
    }

    #[test]
    fn preserves_boolean_schema_semantics_for_provider_validation() {
        let body = json!({
            "model":"gemma-4-fixture",
            "messages":[{"role":"user","content":"x"}],
            "tools":[{"type":"function","function":{
                "name":"f",
                "parameters":{"type":"object","properties":{
                    "allow":true,
                    "deny":false
                }}
            }}]
        });
        let normalized = normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).unwrap();
        let properties = &normalized.tools.unwrap()[0]["function"]["parameters"]["properties"];
        assert_eq!(properties["allow"]["type"], "string");
        assert_eq!(properties["allow"][ORIGINAL_BOOLEAN_SCHEMA_KEY], true);
        assert_eq!(properties["deny"]["type"], "string");
        assert_eq!(properties["deny"][ORIGINAL_BOOLEAN_SCHEMA_KEY], false);
    }

    #[test]
    fn combinator_union_preserves_nullability() {
        let body = json!({
            "model":"gemma-4-fixture",
            "messages":[{"role":"user","content":"x"}],
            "tools":[{"type":"function","function":{
                "name":"lookup",
                "parameters":{"type":"object","properties":{
                    "value":{"anyOf":[{"type":"string"},{"type":"null"}]},
                    "explicit":{
                        "type":"string",
                        "anyOf":[{"type":"string"},{"type":"null"}]
                    }
                }}
            }}],
            "tool_choice":"auto"
        });
        let normalized = normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).unwrap();
        let tools = normalized.tools.unwrap();
        let properties = &tools[0]["function"]["parameters"]["properties"];
        let value = &properties["value"];
        assert_eq!(value["type"], "string");
        assert_eq!(value["nullable"], true);
        assert!(properties["explicit"].get("nullable").is_none());
    }

    #[test]
    fn auto_regex_support_is_rejected_before_inference() {
        let body = |pattern: &str| {
            json!({
                "model":"gemma-4-fixture",
                "messages":[{"role":"user","content":"x"}],
                "tools":[{"type":"function","function":{
                    "name":"lookup",
                    "parameters":{"type":"object","properties":{
                        "code":{"type":"string","pattern":pattern}
                    }}
                }}],
                "tool_choice":"auto"
            })
        };
        assert!(
            normalize(
                body("^city$").as_object().unwrap().clone(),
                Some("gemma4_text")
            )
            .is_ok()
        );
        assert!(
            normalize(
                body("^[a-z]+$").as_object().unwrap().clone(),
                Some("gemma4_text")
            )
            .is_err()
        );
    }

    #[test]
    fn auto_pattern_validation_distinguishes_keywords_from_property_names() {
        let body = json!({
            "model":"gemma-4-fixture",
            "messages":[{"role":"user","content":"x"}],
            "tools":[{"type":"function","function":{
                "name":"lookup",
                "parameters":{"type":"object","properties":{
                    "pattern":{"type":"string","pattern":"^city$"}
                }}
            }}],
            "tool_choice":"auto"
        });
        assert!(normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).is_ok());
    }

    #[test]
    fn auto_pattern_validation_does_not_double_count_tuple_containers() {
        let mut item = json!({"type":"string","pattern":"^city$"});
        for _ in 0..17 {
            item = json!({"type":"array","items":[item]});
        }
        let body = json!({
            "model":"gemma-4-fixture",
            "messages":[{"role":"user","content":"x"}],
            "tools":[{"type":"function","function":{
                "name":"lookup",
                "parameters":{"type":"object","properties":{"value":item}}
            }}],
            "tool_choice":"auto"
        });
        assert!(normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).is_ok());
    }

    #[test]
    fn auto_pattern_validation_bounds_malformed_nested_tuple_arrays() {
        let mut items = json!({"type":"string","pattern":"^city$"});
        for _ in 0..40 {
            items = json!([items]);
        }
        let body = json!({
            "model":"gemma-4-fixture",
            "messages":[{"role":"user","content":"x"}],
            "tools":[{"type":"function","function":{
                "name":"lookup",
                "parameters":{"type":"array","items":items}
            }}],
            "tool_choice":"auto"
        });
        assert!(normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).is_err());
    }

    #[test]
    fn unsupported_auto_semantics_fail_before_render_normalization() {
        for property_schema in [
            json!({"type":["string","integer"]}),
            json!({"oneOf":[{"type":"string"},{"type":"integer"}]}),
            json!({"$ref":"#/$defs/Address"}),
            json!({
                "if":{"properties":{"kind":{"const":"business"}}},
                "then":{"required":["tax_id"]}
            }),
            json!({
                "type":"object",
                "properties":{
                    "credit_card":{"type":"string"},
                    "billing_address":{"type":"string"}
                },
                "dependentSchemas":{
                    "credit_card":{"required":["billing_address"]}
                }
            }),
            json!({
                "type":"object",
                "dependencies":{"credit_card":["billing_address"]}
            }),
            json!({
                "type":"object",
                "dependentRequired":{"credit_card":["billing_address"]}
            }),
            json!({
                "type":"object",
                "propertyNames":{"const":"allowed"}
            }),
        ] {
            let body = json!({
                "model":"gemma-4-fixture",
                "messages":[{"role":"user","content":"x"}],
                "tools":[{"type":"function","function":{
                    "name":"lookup",
                    "parameters":{"type":"object","properties":{"value":property_schema}}
                }}],
                "tool_choice":"auto"
            });
            assert!(normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).is_err());
        }
    }

    #[test]
    fn supported_decimal_multiple_schemas_survive_preflight() {
        for multiple in [
            json!(1),
            json!(0.1),
            json!(2.5),
            json!(1e-200),
            json!(3e-40),
        ] {
            let body = json!({
                "model":"gemma-4-fixture",
                "messages":[{"role":"user","content":"x"}],
                "tools":[{"type":"function","function":{
                    "name":"lookup",
                    "parameters":{"type":"object","properties":{
                        "value":{"type":"number","multipleOf":multiple}
                    }}
                }}],
                "tool_choice":"auto"
            });
            assert!(normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).is_ok());
        }
    }

    #[test]
    fn named_choice_ignores_unsupported_unselected_schema() {
        let body = json!({
            "model":"gemma-4-fixture",
            "messages":[{"role":"user","content":"x"}],
            "tools":[
                {"type":"function","function":{
                    "name":"selected",
                    "parameters":{"type":"object","properties":{
                        "value":{"type":"string"}
                    }}
                }},
                {"type":"function","function":{
                    "name":"unused",
                    "parameters":{"type":"object","properties":{
                        "value":{"pattern":"^x$"}
                    }}
                }}
            ],
            "tool_choice":{"type":"function","function":{"name":"selected"}}
        });
        let normalized = normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).unwrap();
        let tools = normalized.tools.expect("selected tool");
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0]["function"]["name"], "selected");

        let mut unsupported = body;
        unsupported["tool_choice"]["function"]["name"] = json!("unused");
        assert!(
            normalize(
                unsupported.as_object().unwrap().clone(),
                Some("gemma4_text")
            )
            .is_err()
        );
    }

    #[test]
    fn constrained_parallel_policy_is_typed() {
        let malformed = json!({
            "model":"gemma-4-fixture",
            "messages":[{"role":"user","content":"x"}],
            "tools":[{"type":"function","function":{
                "name":"f","parameters":{"type":"object"}
            }}],
            "tool_choice":"required",
            "parallel_tool_calls":"false"
        });
        assert!(normalize(malformed.as_object().unwrap().clone(), Some("gemma4_text")).is_err());
    }

    #[test]
    fn constrained_enum_and_named_choice_validation_matches_swift() {
        for body in [
            json!({
                "model":"gemma-4-fixture",
                "messages":[{"role":"user","content":"x"}],
                "tools":[{"type":"function","function":{
                    "name":"safe",
                    "parameters":{"type":"object","properties":{
                        "x":{"type":"string","enum":[1]}
                    }}
                }}],
                "tool_choice":"required"
            }),
            json!({
                "model":"gemma-4-fixture",
                "messages":[{"role":"user","content":"x"}],
                "tools":[{"type":"function","function":{"name":"safe"}}],
                "tool_choice":{
                    "type":"function",
                    "name":"safe",
                    "function":{"name":"other"}
                }
            }),
        ] {
            assert!(normalize(body.as_object().unwrap().clone(), Some("gemma4_text")).is_err());
        }
    }

    proptest! {
        #[test]
        fn normalization_is_deterministic_for_unicode(content in "\\PC{0,2048}") {
            let body = json!({
                "model": "fixture",
                "messages": [{"role": "user", "content": content}],
                "reasoning_effort": " medium "
            }).as_object().unwrap().clone();
            let first = normalize(body.clone(), None).unwrap();
            let second = normalize(body, None).unwrap();
            prop_assert_eq!(first.body, second.body);
            prop_assert_eq!(first.messages, second.messages);
        }

        #[test]
        fn arbitrary_json_and_tool_shapes_never_panic(
            content in arbitrary_json(),
            tools in prop::collection::vec(arbitrary_json(), 0..8)
        ) {
            let body = json!({
                "model": "fixture",
                "messages": [{"role": "user", "content": content}],
                "tools": tools,
            }).as_object().unwrap().clone();
            let _ = normalize(body, Some("gpt_oss"));
        }
    }

    fn arbitrary_json() -> impl Strategy<Value = Value> {
        let leaf = prop_oneof![
            Just(Value::Null),
            any::<bool>().prop_map(Value::Bool),
            any::<i64>().prop_map(|value| Value::Number(value.into())),
            "\\PC{0,64}".prop_map(Value::String),
        ];
        leaf.prop_recursive(4, 64, 8, |inner| {
            prop_oneof![
                prop::collection::vec(inner.clone(), 0..8).prop_map(Value::Array),
                prop::collection::hash_map("[a-z_]{1,16}", inner, 0..8)
                    .prop_map(|values| Value::Object(values.into_iter().collect())),
            ]
        })
    }
}
