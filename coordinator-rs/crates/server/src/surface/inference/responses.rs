use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::{
    AdaptedStreamFailure, AdapterContext, AdapterError, CanonicalChatRequest, CanonicalChatStream,
    ChatCompletion, ChatSseEvent, ChatUsage, InferenceSurface,
    canonical::{
        delta_object, delta_text, finish_reason, merge_tool_call, message_object, message_text,
    },
    limits::{MAX_CONTENT_PARTS, MAX_MESSAGES, MAX_TOOLS, enforce_count, parse_request_object},
};

/// Lowers an OpenAI Responses request to canonical chat-completions JSON while
/// retaining generation, tool, multimodal, reasoning, and streaming controls.
pub fn parse_responses_request(bytes: &[u8]) -> Result<CanonicalChatRequest, AdapterError> {
    let mut object = parse_request_object(bytes)?;
    let input = object
        .remove("input")
        .ok_or_else(|| AdapterError::invalid("input is required", Some("input")))?;
    let mut messages = Vec::new();
    if let Some(instructions) = object.remove("instructions")
        && !instructions.is_null()
    {
        messages.push(json!({
            "role": "system",
            "content": lower_responses_content(instructions)?
        }));
    }
    lower_responses_input(input, &mut messages)?;
    enforce_count("messages", messages.len(), MAX_MESSAGES)?;
    object.insert("messages".to_owned(), Value::Array(messages));

    if let Some(tokens) = object.remove("max_output_tokens") {
        object.insert("max_completion_tokens".to_owned(), tokens);
    }
    if let Some(tools) = object.get("tools").cloned() {
        object.insert("tools".to_owned(), lower_responses_tools(tools)?);
    }
    if let Some(choice) = object.get("tool_choice").cloned() {
        object.insert(
            "tool_choice".to_owned(),
            lower_responses_tool_choice(choice)?,
        );
    }
    if let Some(text) = object.remove("text")
        && let Some(format) = lower_responses_text_format(&text)
    {
        object.insert("response_format".to_owned(), format);
    }
    if let Some(reasoning) = object.get("reasoning").and_then(Value::as_object)
        && let Some(effort) = reasoning.get("effort").and_then(Value::as_str)
    {
        object.insert(
            "reasoning_effort".to_owned(),
            Value::String(effort.to_owned()),
        );
    }
    object.remove("endpoint");
    CanonicalChatRequest::from_object(object, InferenceSurface::Responses)
}

fn lower_responses_input(input: Value, messages: &mut Vec<Value>) -> Result<(), AdapterError> {
    match input {
        Value::String(text) => {
            messages.push(json!({"role": "user", "content": text}));
            Ok(())
        }
        Value::Array(items) => {
            enforce_count("input", items.len(), MAX_MESSAGES)?;
            for item in items {
                let item = item.as_object().ok_or_else(|| {
                    AdapterError::invalid("Responses input items must be objects", Some("input"))
                })?;
                match item.get("type").and_then(Value::as_str) {
                    Some("message") | None if item.get("role").is_some() => {
                        let role = item.get("role").and_then(Value::as_str).unwrap_or("user");
                        let role = if role == "developer" { "system" } else { role };
                        if !matches!(role, "system" | "user" | "assistant" | "tool") {
                            return Err(AdapterError::invalid(
                                "Responses message has an unsupported role",
                                Some("input"),
                            ));
                        }
                        messages.push(json!({
                            "role": role,
                            "content": lower_responses_content(
                                item.get("content").cloned().unwrap_or(Value::Null)
                            )?
                        }));
                    }
                    Some("function_call") => {
                        let call_id = item
                            .get("call_id")
                            .or_else(|| item.get("id"))
                            .and_then(Value::as_str)
                            .unwrap_or_default();
                        let name = item.get("name").and_then(Value::as_str).unwrap_or_default();
                        let arguments = item
                            .get("arguments")
                            .and_then(Value::as_str)
                            .unwrap_or("{}");
                        messages.push(json!({
                            "role": "assistant",
                            "content": "",
                            "tool_calls": [{
                                "id": call_id,
                                "type": "function",
                                "function": {"name": name, "arguments": arguments}
                            }]
                        }));
                    }
                    Some("function_call_output") => {
                        let call_id = item
                            .get("call_id")
                            .and_then(Value::as_str)
                            .unwrap_or_default();
                        messages.push(json!({
                            "role": "tool",
                            "tool_call_id": call_id,
                            "content": flatten_responses_text(
                                item.get("output").unwrap_or(&Value::Null)
                            ),
                        }));
                    }
                    Some("reasoning") => {
                        let reasoning = item
                            .get("summary")
                            .and_then(Value::as_array)
                            .map(|summary| {
                                summary
                                    .iter()
                                    .filter_map(|part| part.get("text").and_then(Value::as_str))
                                    .collect::<Vec<_>>()
                                    .join("")
                            })
                            .unwrap_or_default();
                        if !reasoning.is_empty() {
                            messages.push(json!({
                                "role": "assistant",
                                "content": "",
                                "reasoning_content": reasoning,
                            }));
                        }
                    }
                    Some(_) | None => {
                        return Err(AdapterError::invalid(
                            "unsupported Responses input item type",
                            Some("input"),
                        ));
                    }
                }
            }
            if messages.is_empty() {
                return Err(AdapterError::invalid(
                    "input did not contain any chat-compatible messages",
                    Some("input"),
                ));
            }
            Ok(())
        }
        _ => Err(AdapterError::invalid(
            "input must be a string or array",
            Some("input"),
        )),
    }
}

fn lower_responses_content(content: Value) -> Result<Value, AdapterError> {
    match content {
        Value::Null | Value::String(_) => Ok(content),
        Value::Array(parts) => {
            enforce_count("content", parts.len(), MAX_CONTENT_PARTS)?;
            let mut output = Vec::new();
            for part in parts {
                if let Value::String(text) = part {
                    output.push(json!({"type": "text", "text": text}));
                    continue;
                }
                let part = part.as_object().ok_or_else(|| {
                    AdapterError::invalid("Responses content parts must be objects", Some("input"))
                })?;
                match part.get("type").and_then(Value::as_str) {
                    Some("input_text" | "output_text" | "text") => output.push(json!({
                        "type": "text",
                        "text": part.get("text").and_then(Value::as_str).unwrap_or_default()
                    })),
                    Some("input_image" | "image_url") => {
                        let image = part
                            .get("image_url")
                            .or_else(|| part.get("url"))
                            .cloned()
                            .ok_or_else(|| {
                                AdapterError::invalid(
                                    "Responses image part requires image_url",
                                    Some("input"),
                                )
                            })?;
                        let image = if image.is_string() {
                            json!({"url": image})
                        } else {
                            image
                        };
                        output.push(json!({"type": "image_url", "image_url": image}));
                    }
                    Some("input_file") => {
                        let mut file = part.clone();
                        file.remove("type");
                        output.push(json!({"type": "file", "file": file}));
                    }
                    _ => {
                        return Err(AdapterError::invalid(
                            "unsupported Responses content part type",
                            Some("input"),
                        ));
                    }
                }
            }
            Ok(Value::Array(output))
        }
        _ => Err(AdapterError::invalid(
            "Responses content must be a string or array",
            Some("input"),
        )),
    }
}

fn flatten_responses_text(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|part| {
                part.as_str()
                    .or_else(|| part.get("text").and_then(Value::as_str))
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Value::Null => String::new(),
        _ => serde_json::to_string(content).unwrap_or_default(),
    }
}

fn lower_responses_tools(value: Value) -> Result<Value, AdapterError> {
    let tools = value
        .as_array()
        .ok_or_else(|| AdapterError::invalid("tools must be an array", Some("tools")))?;
    enforce_count("tools", tools.len(), MAX_TOOLS)?;
    tools
        .iter()
        .map(|tool| {
            let tool = tool.as_object().ok_or_else(|| {
                AdapterError::invalid("each tool must be an object", Some("tools"))
            })?;
            if let Some(function) = tool.get("function").and_then(Value::as_object) {
                return Ok(json!({"type": "function", "function": function}));
            }
            if !matches!(
                tool.get("type").and_then(Value::as_str),
                None | Some("function")
            ) {
                return Err(AdapterError::invalid(
                    "only function tools are supported",
                    Some("tools"),
                ));
            }
            let name = tool
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
                .ok_or_else(|| AdapterError::invalid("tool name is required", Some("tools")))?;
            Ok(json!({
                "type": "function",
                "function": {
                    "name": name,
                    "description": tool.get("description").cloned().unwrap_or(Value::Null),
                    "parameters": tool.get("parameters").cloned().unwrap_or_else(|| json!({"type": "object"})),
                    "strict": tool.get("strict").cloned().unwrap_or(Value::Bool(false)),
                }
            }))
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Value::Array)
}

fn lower_responses_tool_choice(value: Value) -> Result<Value, AdapterError> {
    let Some(choice) = value.as_object() else {
        return Ok(value);
    };
    if choice.get("type").and_then(Value::as_str) != Some("function") {
        return Ok(value);
    }
    let name = choice
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
        .ok_or_else(|| {
            AdapterError::invalid("function tool_choice requires name", Some("tool_choice"))
        })?;
    Ok(json!({"type": "function", "function": {"name": name}}))
}

fn lower_responses_text_format(text: &Value) -> Option<Value> {
    let format = text.get("format")?.as_object()?;
    match format.get("type").and_then(Value::as_str) {
        Some("json_object") => Some(json!({"type": "json_object"})),
        Some("json_schema") => Some(json!({"type": "json_schema", "json_schema": format})),
        _ => None,
    }
}

/// Converts one non-stream canonical chat response to a Responses object.
pub fn adapt_responses_nonstream(
    chat_json: &[u8],
    context: &AdapterContext,
) -> Result<Vec<u8>, AdapterError> {
    let chat = ChatCompletion::parse(chat_json)?;
    let choice = chat
        .choices
        .first()
        .ok_or_else(|| AdapterError::invalid("provider returned no completion choice", None))?;
    let message = message_object(choice)
        .ok_or_else(|| AdapterError::invalid("provider choice has no message", None))?;
    let output = responses_output_items(message, context)?;
    let finish = choice
        .get("finish_reason")
        .and_then(Value::as_str)
        .unwrap_or("stop");
    let value = responses_object(
        context,
        if context.model.is_empty() {
            &chat.model
        } else {
            &context.model
        },
        output,
        chat.usage,
        finish,
    );
    serde_json::to_vec(&value)
        .map_err(|_| AdapterError::invalid("Responses object could not be encoded", None))
}

fn responses_output_items(
    message: &Map<String, Value>,
    context: &AdapterContext,
) -> Result<Vec<Value>, AdapterError> {
    let mut output = Vec::new();
    let reasoning = {
        let reasoning = message_text(message, "reasoning");
        if reasoning.is_empty() {
            message_text(message, "reasoning_content")
        } else {
            reasoning
        }
    };
    if !reasoning.is_empty() {
        output.push(json!({
            "type": "reasoning",
            "id": item_id("rs", context, output.len()),
            "summary": [{"type": "summary_text", "text": reasoning}],
            "status": "completed",
        }));
    }
    let content = message_text(message, "content");
    if !content.is_empty() || message.get("tool_calls").is_none() {
        output.push(json!({
            "type": "message",
            "id": item_id("msg", context, output.len()),
            "role": "assistant",
            "content": [{
                "type": "output_text",
                "text": content,
                "annotations": [],
            }],
            "status": "completed",
        }));
    }
    if let Some(calls) = message.get("tool_calls").and_then(Value::as_array) {
        for call in calls {
            let function = call.get("function").and_then(Value::as_object);
            let index = output.len();
            output.push(json!({
                "type": "function_call",
                "id": item_id("fc", context, index),
                "call_id": call.get("id").and_then(Value::as_str)
                    .map_or_else(|| item_id("call", context, index), ToOwned::to_owned),
                "name": function.and_then(|value| value.get("name")).and_then(Value::as_str).unwrap_or_default(),
                "arguments": function.and_then(|value| value.get("arguments")).and_then(Value::as_str).unwrap_or_default(),
                "status": "completed",
            }));
        }
    }
    Ok(output)
}

fn responses_object(
    context: &AdapterContext,
    model: &str,
    output: Vec<Value>,
    usage: ChatUsage,
    finish_reason: &str,
) -> Value {
    let incomplete = incomplete_details(finish_reason);
    json!({
        "id": context.response_id(),
        "object": "response",
        "created_at": context.created_at,
        "status": if incomplete.is_null() { "completed" } else { "incomplete" },
        "error": Value::Null,
        "incomplete_details": incomplete,
        "instructions": Value::Null,
        "max_output_tokens": Value::Null,
        "model": model,
        "output": output,
        "parallel_tool_calls": true,
        "temperature": Value::Null,
        "tool_choice": "auto",
        "tools": [],
        "top_p": Value::Null,
        "metadata": {},
        "usage": responses_usage(usage),
    })
}

fn responses_usage(usage: ChatUsage) -> Value {
    json!({
        "input_tokens": usage.prompt_tokens,
        "input_tokens_details": {
            "cached_tokens": usage.cached_tokens,
            "reasoning_tokens": 0,
        },
        "output_tokens": usage.completion_tokens,
        "output_tokens_details": {
            "cached_tokens": 0,
            "reasoning_tokens": usage.reasoning_tokens,
        },
    })
}

fn incomplete_details(finish_reason: &str) -> Value {
    match finish_reason {
        "length" => json!({"reason": "max_output_tokens"}),
        "content_filter" => json!({"reason": "content_filter"}),
        _ => Value::Null,
    }
}

fn item_id(prefix: &str, context: &AdapterContext, index: usize) -> String {
    format!(
        "{prefix}_{}_{}",
        super::canonical::compact_id(&context.request_id),
        index
    )
}

#[derive(Debug)]
struct ToolState {
    output_index: usize,
    item_id: String,
    call: Value,
    started: bool,
}

/// Stateful exact chat-SSE to OpenAI Responses-SSE adapter.
#[derive(Debug)]
pub struct ResponsesStreamAdapter {
    context: AdapterContext,
    source: CanonicalChatStream,
    sequence: u64,
    started: bool,
    output: Vec<Value>,
    text_index: Option<usize>,
    text: String,
    reasoning_index: Option<usize>,
    reasoning: String,
    tools: BTreeMap<u64, ToolState>,
    finish_reason: String,
    usage: ChatUsage,
    terminal: bool,
}

impl ResponsesStreamAdapter {
    #[must_use]
    pub fn new(context: AdapterContext) -> Self {
        Self {
            context,
            source: CanonicalChatStream::default(),
            sequence: 0,
            started: false,
            output: Vec::new(),
            text_index: None,
            text: String::new(),
            reasoning_index: None,
            reasoning: String::new(),
            tools: BTreeMap::new(),
            finish_reason: "stop".to_owned(),
            usage: ChatUsage::default(),
            terminal: false,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Vec<u8>>, AdapterError> {
        let events = self.source.push(bytes)?;
        self.adapt_events(events)
    }

    fn adapt_events(&mut self, events: Vec<ChatSseEvent>) -> Result<Vec<Vec<u8>>, AdapterError> {
        let mut output = Vec::new();
        if !events.is_empty() {
            self.start(&mut output)?;
        }
        for event in events {
            match event {
                ChatSseEvent::Done => self.complete(&mut output)?,
                ChatSseEvent::Chunk(chunk) => {
                    if let Some(usage) = chunk.usage.as_ref() {
                        self.usage = ChatUsage::from_value(Some(usage));
                    }
                    for choice in &chunk.choices {
                        if let Some(reason) = finish_reason(choice) {
                            self.finish_reason = reason.to_owned();
                        }
                        let Some(delta) = delta_object(choice) else {
                            continue;
                        };
                        let reasoning = {
                            let reasoning = delta_text(delta, "reasoning");
                            if reasoning.is_empty() {
                                delta_text(delta, "reasoning_content")
                            } else {
                                reasoning
                            }
                        };
                        if !reasoning.is_empty() {
                            self.reasoning_delta(reasoning, &mut output)?;
                        }
                        let text = delta_text(delta, "content");
                        if !text.is_empty() {
                            self.text_delta(text, &mut output)?;
                        }
                        if let Some(calls) = delta.get("tool_calls").and_then(Value::as_array) {
                            for call in calls {
                                self.tool_delta(call, &mut output)?;
                            }
                        }
                    }
                }
            }
        }
        Ok(output)
    }

    fn emit(
        &mut self,
        kind: &'static str,
        mut fields: Map<String, Value>,
    ) -> Result<Vec<u8>, AdapterError> {
        fields.insert("type".to_owned(), Value::String(kind.to_owned()));
        fields.insert("sequence_number".to_owned(), Value::from(self.sequence));
        self.sequence = self.sequence.checked_add(1).ok_or_else(|| {
            AdapterError::limit("Responses event sequence overflow".to_owned(), None)
        })?;
        let mut output = format!("event: {kind}\ndata: ").into_bytes();
        output
            .extend_from_slice(&serde_json::to_vec(&Value::Object(fields)).map_err(|_| {
                AdapterError::invalid("Responses event could not be encoded", None)
            })?);
        output.extend_from_slice(b"\n\n");
        Ok(output)
    }

    fn start(&mut self, output: &mut Vec<Vec<u8>>) -> Result<(), AdapterError> {
        if self.started {
            return Ok(());
        }
        self.started = true;
        let snapshot = self.snapshot("in_progress", Vec::new(), ChatUsage::default(), "stop");
        output.push(self.emit("response.created", map([("response", snapshot.clone())]))?);
        output.push(self.emit("response.in_progress", map([("response", snapshot)]))?);
        Ok(())
    }

    fn reasoning_delta(
        &mut self,
        delta: &str,
        output: &mut Vec<Vec<u8>>,
    ) -> Result<(), AdapterError> {
        let index = match self.reasoning_index {
            Some(index) => index,
            None => {
                self.close_text(output)?;
                self.close_tools(output)?;
                let index = self.output.len();
                self.reasoning_index = Some(index);
                let id = item_id("rs", &self.context, index);
                output.push(self.emit(
                    "response.output_item.added",
                    map([
                        ("output_index", Value::from(index)),
                        (
                            "item",
                            json!({"type":"reasoning","id":id,"summary":[],"status":"in_progress"}),
                        ),
                    ]),
                )?);
                output.push(self.emit(
                    "response.reasoning_summary_part.added",
                    map([
                        ("item_id", Value::String(id)),
                        ("output_index", Value::from(index)),
                        ("summary_index", Value::from(0)),
                        ("part", json!({"type":"summary_text","text":""})),
                    ]),
                )?);
                index
            }
        };
        self.reasoning.push_str(delta);
        output.push(self.emit(
            "response.reasoning_summary_text.delta",
            map([
                (
                    "item_id",
                    Value::String(item_id("rs", &self.context, index)),
                ),
                ("output_index", Value::from(index)),
                ("summary_index", Value::from(0)),
                ("delta", Value::String(delta.to_owned())),
            ]),
        )?);
        Ok(())
    }

    fn text_delta(&mut self, delta: &str, output: &mut Vec<Vec<u8>>) -> Result<(), AdapterError> {
        let index = self.ensure_text_open(output)?;
        self.text.push_str(delta);
        output.push(self.emit(
            "response.output_text.delta",
            map([
                (
                    "item_id",
                    Value::String(item_id("msg", &self.context, index)),
                ),
                ("output_index", Value::from(index)),
                ("content_index", Value::from(0)),
                ("delta", Value::String(delta.to_owned())),
                ("logprobs", Value::Array(Vec::new())),
            ]),
        )?);
        Ok(())
    }

    fn ensure_text_open(&mut self, output: &mut Vec<Vec<u8>>) -> Result<usize, AdapterError> {
        let index = match self.text_index {
            Some(index) => index,
            None => {
                self.close_reasoning(output)?;
                self.close_tools(output)?;
                let index = self.output.len();
                self.text_index = Some(index);
                let id = item_id("msg", &self.context, index);
                output.push(self.emit(
                    "response.output_item.added",
                    map([
                        ("output_index", Value::from(index)),
                        (
                            "item",
                            json!({"type":"message","id":id,"role":"assistant","content":[],"status":"in_progress"}),
                        ),
                    ]),
                )?);
                output.push(self.emit(
                    "response.content_part.added",
                    map([
                        ("item_id", Value::String(id)),
                        ("output_index", Value::from(index)),
                        ("content_index", Value::from(0)),
                        (
                            "part",
                            json!({"type":"output_text","text":"","annotations":[]}),
                        ),
                    ]),
                )?);
                index
            }
        };
        Ok(index)
    }

    fn tool_delta(
        &mut self,
        fragment: &Value,
        output: &mut Vec<Vec<u8>>,
    ) -> Result<(), AdapterError> {
        self.close_reasoning(output)?;
        self.close_text(output)?;
        let source_index = fragment.get("index").and_then(Value::as_u64).unwrap_or(0);
        if !self.tools.contains_key(&source_index) {
            let index = self.output.len() + self.tools.len();
            self.tools.insert(
                source_index,
                ToolState {
                    output_index: index,
                    item_id: item_id("fc", &self.context, index),
                    call: json!({"id":"","type":"function","function":{"name":"","arguments":""}}),
                    started: false,
                },
            );
        }
        let mut call_map = BTreeMap::from([(
            source_index,
            self.tools
                .get(&source_index)
                .expect("tool state")
                .call
                .clone(),
        )]);
        merge_tool_call(&mut call_map, fragment)?;
        let call = call_map.remove(&source_index).expect("merged tool");
        let state = self.tools.get_mut(&source_index).expect("tool state");
        state.call = call;
        if !state.started {
            state.started = true;
            let fields = map([
                ("output_index", Value::from(state.output_index)),
                (
                    "item",
                    json!({
                        "type":"function_call",
                        "id":state.item_id,
                        "call_id":state.call.get("id").and_then(Value::as_str).unwrap_or_default(),
                        "name":state.call.pointer("/function/name").and_then(Value::as_str).unwrap_or_default(),
                        "arguments":"",
                        "status":"in_progress"
                    }),
                ),
            ]);
            output.push(self.emit("response.output_item.added", fields)?);
        }
        if let Some(arguments) = fragment
            .pointer("/function/arguments")
            .and_then(Value::as_str)
            .filter(|arguments| !arguments.is_empty())
        {
            let state = self.tools.get(&source_index).expect("tool state");
            output.push(self.emit(
                "response.function_call_arguments.delta",
                map([
                    ("item_id", Value::String(state.item_id.clone())),
                    ("output_index", Value::from(state.output_index)),
                    ("delta", Value::String(arguments.to_owned())),
                ]),
            )?);
        }
        Ok(())
    }

    fn close_reasoning(&mut self, output: &mut Vec<Vec<u8>>) -> Result<(), AdapterError> {
        let Some(index) = self.reasoning_index.take() else {
            return Ok(());
        };
        let id = item_id("rs", &self.context, index);
        let text = std::mem::take(&mut self.reasoning);
        output.push(self.emit(
            "response.reasoning_summary_text.done",
            map([
                ("item_id", Value::String(id.clone())),
                ("output_index", Value::from(index)),
                ("summary_index", Value::from(0)),
                ("text", Value::String(text.clone())),
            ]),
        )?);
        output.push(self.emit(
            "response.reasoning_summary_part.done",
            map([
                ("item_id", Value::String(id.clone())),
                ("output_index", Value::from(index)),
                ("summary_index", Value::from(0)),
                ("part", json!({"type":"summary_text","text":text})),
            ]),
        )?);
        let item = json!({
            "type":"reasoning",
            "id":id,
            "summary":[{"type":"summary_text","text":text}],
            "status":"completed"
        });
        output.push(self.emit(
            "response.output_item.done",
            map([("output_index", Value::from(index)), ("item", item.clone())]),
        )?);
        self.output.push(item);
        Ok(())
    }

    fn close_text(&mut self, output: &mut Vec<Vec<u8>>) -> Result<(), AdapterError> {
        let Some(index) = self.text_index.take() else {
            return Ok(());
        };
        let id = item_id("msg", &self.context, index);
        let text = std::mem::take(&mut self.text);
        output.push(self.emit(
            "response.output_text.done",
            map([
                ("item_id", Value::String(id.clone())),
                ("output_index", Value::from(index)),
                ("content_index", Value::from(0)),
                ("text", Value::String(text.clone())),
                ("logprobs", Value::Array(Vec::new())),
            ]),
        )?);
        output.push(self.emit(
            "response.content_part.done",
            map([
                ("item_id", Value::String(id.clone())),
                ("output_index", Value::from(index)),
                ("content_index", Value::from(0)),
                (
                    "part",
                    json!({"type":"output_text","text":text,"annotations":[]}),
                ),
            ]),
        )?);
        let item = json!({
            "type":"message",
            "id":id,
            "role":"assistant",
            "content":[{"type":"output_text","text":text,"annotations":[]}],
            "status":"completed"
        });
        output.push(self.emit(
            "response.output_item.done",
            map([("output_index", Value::from(index)), ("item", item.clone())]),
        )?);
        self.output.push(item);
        Ok(())
    }

    fn close_tools(&mut self, output: &mut Vec<Vec<u8>>) -> Result<(), AdapterError> {
        let mut tools = std::mem::take(&mut self.tools)
            .into_values()
            .collect::<Vec<_>>();
        tools.sort_by_key(|state| state.output_index);
        for state in tools {
            let arguments = state
                .call
                .pointer("/function/arguments")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            output.push(self.emit(
                "response.function_call_arguments.done",
                map([
                    ("item_id", Value::String(state.item_id.clone())),
                    ("output_index", Value::from(state.output_index)),
                    ("arguments", Value::String(arguments.clone())),
                ]),
            )?);
            let item = json!({
                "type":"function_call",
                "id":state.item_id,
                "call_id":state.call.get("id").and_then(Value::as_str).unwrap_or_default(),
                "name":state.call.pointer("/function/name").and_then(Value::as_str).unwrap_or_default(),
                "arguments":arguments,
                "status":"completed"
            });
            output.push(self.emit(
                "response.output_item.done",
                map([
                    ("output_index", Value::from(state.output_index)),
                    ("item", item.clone()),
                ]),
            )?);
            self.output.push(item);
        }
        self.output.sort_by_key(|item| {
            let id = item.get("id").and_then(Value::as_str).unwrap_or_default();
            id.rsplit('_')
                .next()
                .and_then(|index| index.parse::<usize>().ok())
                .unwrap_or(usize::MAX)
        });
        Ok(())
    }

    fn complete(&mut self, output: &mut Vec<Vec<u8>>) -> Result<(), AdapterError> {
        if self.terminal {
            return Err(AdapterError::invalid(
                "provider emitted duplicate completion",
                None,
            ));
        }
        self.close_reasoning(output)?;
        self.close_text(output)?;
        self.close_tools(output)?;
        if self.output.is_empty() {
            self.ensure_text_open(output)?;
            self.close_text(output)?;
        }
        if self.usage.reasoning_tokens == 0
            && self
                .output
                .iter()
                .any(|item| item.get("type").and_then(Value::as_str) == Some("reasoning"))
        {
            self.usage.reasoning_tokens = self.usage.completion_tokens;
        }
        let status = if incomplete_details(&self.finish_reason).is_null() {
            "completed"
        } else {
            "incomplete"
        };
        let kind = if status == "completed" {
            "response.completed"
        } else {
            "response.incomplete"
        };
        let snapshot = self.snapshot(status, self.output.clone(), self.usage, &self.finish_reason);
        output.push(self.emit(kind, map([("response", snapshot)]))?);
        self.terminal = true;
        Ok(())
    }

    fn snapshot(&self, status: &str, output: Vec<Value>, usage: ChatUsage, finish: &str) -> Value {
        let mut snapshot =
            responses_object(&self.context, &self.context.model, output, usage, finish);
        if let Some(snapshot) = snapshot.as_object_mut() {
            snapshot.insert("status".to_owned(), Value::String(status.to_owned()));
            snapshot.insert("background".to_owned(), Value::Bool(false));
            snapshot.insert("previous_response_id".to_owned(), Value::Null);
            snapshot.insert("store".to_owned(), Value::Bool(false));
            snapshot.insert("text".to_owned(), json!({"format":{"type":"text"}}));
            snapshot.insert(
                "truncation".to_owned(),
                Value::String("disabled".to_owned()),
            );
            snapshot.insert("user".to_owned(), Value::Null);
            snapshot.insert("service_tier".to_owned(), Value::Null);
            if status == "in_progress" {
                snapshot.insert("usage".to_owned(), Value::Null);
                snapshot.insert("incomplete_details".to_owned(), Value::Null);
            }
        }
        snapshot
    }

    pub fn finish_input(&mut self) -> Result<Vec<Vec<u8>>, AdapterError> {
        let events = self.source.finish_input()?;
        self.adapt_events(events)
    }

    #[must_use]
    pub const fn is_committed(&self) -> bool {
        self.source.is_committed()
    }

    pub fn fail(&mut self, error: AdapterError) -> AdaptedStreamFailure {
        if !self.is_committed() {
            return AdaptedStreamFailure::PreCommit(error);
        }
        let fields = map([(
            "error",
            json!({
                "type": error.kind(),
                "code": error.code(),
                "message": error.message(),
                "param": error.param(),
            }),
        )]);
        let event = self.emit("error", fields).unwrap_or_else(|_| {
            b"event: error\ndata: {\"type\":\"error\",\"sequence_number\":0,\"error\":{\"type\":\"server_error\",\"code\":\"server_error\",\"message\":\"stream failed\",\"param\":null}}\n\n".to_vec()
        });
        AdaptedStreamFailure::Committed(vec![event])
    }

    pub fn cancel(&mut self) -> AdaptedStreamFailure {
        self.fail(AdapterError::cancelled())
    }
}

fn map<const N: usize>(entries: [(&str, Value); N]) -> Map<String, Value> {
    entries
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> AdapterContext {
        AdapterContext {
            request_id: "request-1".to_owned(),
            model: "model-a".to_owned(),
            created_at: 1_700_000_000,
            maximum_output_tokens: 100,
        }
    }

    #[test]
    fn request_preserves_multimodal_tools_reasoning_and_stream_knobs() {
        let request = parse_responses_request(
            br#"{
              "model":"model-a","stream":true,"stream_options":{"include_usage":true},
              "max_output_tokens":100,"temperature":0.2,"top_p":0.9,
              "reasoning":{"effort":"high","summary":"auto"},
              "instructions":"system",
              "input":[{"type":"message","role":"user","content":[
                {"type":"input_text","text":"look"},
                {"type":"input_image","image_url":"data:image/png;base64,AAAA"}
              ]}],
              "tools":[{"type":"function","name":"weather","parameters":{"type":"object"}}],
              "tool_choice":{"type":"function","name":"weather"},
              "text":{"format":{"type":"json_schema","name":"answer","schema":{"type":"object"}}}
            }"#,
        )
        .expect("request");
        let chat: Value = serde_json::from_slice(request.body()).expect("chat");
        assert_eq!(chat["messages"][0]["role"], "system");
        assert_eq!(
            chat["messages"][1]["content"][1]["image_url"]["url"],
            "data:image/png;base64,AAAA"
        );
        assert_eq!(chat["tools"][0]["function"]["name"], "weather");
        assert_eq!(chat["tool_choice"]["function"]["name"], "weather");
        assert_eq!(chat["reasoning_effort"], "high");
        assert_eq!(chat["reasoning"]["summary"], "auto");
        assert_eq!(chat["stream_options"]["include_usage"], true);
        assert_eq!(chat["response_format"]["type"], "json_schema");
    }

    #[test]
    fn nonstream_matches_existing_responses_contract_shape() {
        let chat = br#"{"id":"chatcmpl-contract","object":"chat.completion","created":1700000000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}"#;
        let output = adapt_responses_nonstream(chat, &context()).expect("adapt");
        let output: Value = serde_json::from_slice(&output).expect("JSON");
        assert_eq!(output["object"], "response");
        assert_eq!(output["status"], "completed");
        assert_eq!(output["output"][0]["content"][0]["text"], "hello");
        assert_eq!(output["usage"]["input_tokens"], 2);
        assert_eq!(output["usage"]["output_tokens"], 1);
    }

    #[test]
    fn stream_has_canonical_lifecycle_tools_usage_and_errors() {
        let mut adapter = ResponsesStreamAdapter::new(context());
        assert!(
            adapter
                .push(br#"data: {"id":"c","object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}

"#)
                .expect("role")
                .is_empty()
        );
        let output = adapter
            .push(br#"data: {"id":"c","object":"chat.completion.chunk","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"weather","arguments":"{\"city\":"}}]},"finish_reason":null}]}

data: {"id":"c","object":"chat.completion.chunk","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"SF\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}

data: [DONE]

"#)
            .expect("stream");
        let text = output
            .iter()
            .map(|event| String::from_utf8_lossy(event))
            .collect::<String>();
        assert!(text.contains("event: response.created"));
        assert!(text.contains("event: response.function_call_arguments.delta"));
        assert!(text.contains("\"arguments\":\"{\\\"city\\\":\\\"SF\\\"}\""));
        assert!(text.contains("event: response.completed"));
        assert!(text.contains("\"input_tokens\":2"));

        let failure = adapter.fail(AdapterError::cancelled());
        assert!(matches!(failure, AdaptedStreamFailure::Committed(_)));
    }

    #[test]
    fn malformed_unknown_input_and_tool_limits_are_rejected() {
        assert!(parse_responses_request(br#"{"model":"m","input":"#).is_err());
        assert!(
            parse_responses_request(
                br#"{"model":"m","input":[{"type":"computer_call","id":"x"}]}"#
            )
            .is_err()
        );
        let request = json!({
            "model": "m",
            "input": "hello",
            "tools": (0..=MAX_TOOLS)
                .map(|index| json!({"type":"function","name":format!("tool_{index}")}))
                .collect::<Vec<_>>(),
        });
        let error =
            parse_responses_request(&serde_json::to_vec(&request).expect("oversized tools JSON"))
                .expect_err("tool count limit");
        assert!(error.message().contains("at most 128"));
    }
}
