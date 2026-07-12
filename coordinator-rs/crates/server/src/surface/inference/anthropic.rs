use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value, json};

use super::{
    AdaptedStreamFailure, AdapterContext, AdapterError, CanonicalChatRequest, CanonicalChatStream,
    ChatCompletion, ChatSseEvent, ChatUsage, InferenceSurface,
    canonical::{delta_object, delta_text, finish_reason, message_object, message_text},
    limits::{
        MAX_CONTENT_PARTS, MAX_MESSAGES, MAX_TOOLS, enforce_count, parse_request_object,
        required_array,
    },
};

/// Lowers an Anthropic Messages body to the chat-completions request consumed
/// by `RequestDispatcher`.
pub fn parse_anthropic_request(bytes: &[u8]) -> Result<CanonicalChatRequest, AdapterError> {
    let mut object = parse_request_object(bytes)?;
    let max_tokens = object
        .get("max_tokens")
        .and_then(Value::as_u64)
        .filter(|tokens| *tokens > 0)
        .ok_or_else(|| {
            AdapterError::invalid(
                "max_tokens is required and must be a positive integer",
                Some("max_tokens"),
            )
        })?;
    object.insert("max_completion_tokens".to_owned(), Value::from(max_tokens));

    let source_messages = required_array(&object, "messages")?.clone();
    enforce_count("messages", source_messages.len(), MAX_MESSAGES)?;
    let mut messages = Vec::new();
    if let Some(system) = object.remove("system") {
        let content = anthropic_content_to_chat(system, "system")?;
        if !content.is_null() {
            messages.push(json!({"role": "system", "content": content}));
        }
    }
    for message in source_messages {
        lower_anthropic_message(&message, &mut messages)?;
    }
    object.insert("messages".to_owned(), Value::Array(messages));

    if let Some(tools) = object.get("tools").cloned() {
        object.insert("tools".to_owned(), lower_anthropic_tools(tools)?);
    }
    if let Some(choice) = object.get("tool_choice").cloned() {
        let (choice, parallel) = lower_anthropic_tool_choice(choice)?;
        object.insert("tool_choice".to_owned(), choice);
        if let Some(parallel) = parallel {
            object.insert("parallel_tool_calls".to_owned(), Value::Bool(parallel));
        }
    }
    if let Some(stop) = object.remove("stop_sequences") {
        object.insert("stop".to_owned(), stop);
    }
    if let Some(thinking) = object.get("thinking").and_then(Value::as_object)
        && thinking.get("type").and_then(Value::as_str) == Some("enabled")
    {
        object.insert(
            "reasoning_effort".to_owned(),
            Value::String("high".to_owned()),
        );
    }
    object.remove("endpoint");
    CanonicalChatRequest::from_object(object, InferenceSurface::AnthropicMessages)
}

fn lower_anthropic_message(value: &Value, output: &mut Vec<Value>) -> Result<(), AdapterError> {
    let message = value.as_object().ok_or_else(|| {
        AdapterError::invalid("each Anthropic message must be an object", Some("messages"))
    })?;
    let role = message
        .get("role")
        .and_then(Value::as_str)
        .filter(|role| matches!(*role, "user" | "assistant"))
        .ok_or_else(|| {
            AdapterError::invalid(
                "Anthropic message role must be user or assistant",
                Some("messages"),
            )
        })?;
    let content = message
        .get("content")
        .cloned()
        .ok_or_else(|| AdapterError::invalid("message content is required", Some("messages")))?;
    let Value::Array(blocks) = content else {
        if !content.is_string() {
            return Err(AdapterError::invalid(
                "Anthropic message content must be a string or array",
                Some("messages"),
            ));
        }
        output.push(json!({"role": role, "content": content}));
        return Ok(());
    };
    enforce_count("message content", blocks.len(), MAX_CONTENT_PARTS)?;

    let mut chat_parts = Vec::new();
    let mut tool_calls = Vec::new();
    let mut reasoning = String::new();
    for block in blocks {
        let block = block.as_object().ok_or_else(|| {
            AdapterError::invalid("Anthropic content blocks must be objects", Some("messages"))
        })?;
        match block.get("type").and_then(Value::as_str) {
            Some("text") => chat_parts.push(json!({
                "type": "text",
                "text": block.get("text").and_then(Value::as_str).unwrap_or_default()
            })),
            Some("image") => chat_parts.push(lower_anthropic_image(block)?),
            Some("document") => chat_parts.push(lower_anthropic_document(block)?),
            Some("thinking" | "redacted_thinking") => {
                if let Some(text) = block
                    .get("thinking")
                    .or_else(|| block.get("data"))
                    .and_then(Value::as_str)
                {
                    reasoning.push_str(text);
                }
            }
            Some("tool_use") if role == "assistant" => {
                let id = required_nonempty(block, "id", "tool_use id is required")?;
                let name = required_nonempty(block, "name", "tool_use name is required")?;
                let arguments =
                    serde_json::to_string(block.get("input").unwrap_or(&Value::Object(Map::new())))
                        .map_err(|_| {
                            AdapterError::invalid(
                                "tool_use input could not be encoded",
                                Some("messages"),
                            )
                        })?;
                tool_calls.push(json!({
                    "id": id,
                    "type": "function",
                    "function": {"name": name, "arguments": arguments}
                }));
            }
            Some("tool_result") if role == "user" => {
                flush_chat_message(
                    role,
                    &mut chat_parts,
                    &mut tool_calls,
                    &mut reasoning,
                    output,
                );
                let tool_call_id =
                    required_nonempty(block, "tool_use_id", "tool_result tool_use_id is required")?;
                let tool_content = anthropic_content_to_chat(
                    block.get("content").cloned().unwrap_or(Value::Null),
                    "tool",
                )?;
                output.push(json!({
                    "role": "tool",
                    "tool_call_id": tool_call_id,
                    "content": tool_content,
                }));
            }
            Some(_) | None => {
                return Err(AdapterError::invalid(
                    "unsupported Anthropic content block type",
                    Some("messages"),
                ));
            }
        }
    }
    flush_chat_message(
        role,
        &mut chat_parts,
        &mut tool_calls,
        &mut reasoning,
        output,
    );
    Ok(())
}

fn flush_chat_message(
    role: &str,
    parts: &mut Vec<Value>,
    tool_calls: &mut Vec<Value>,
    reasoning: &mut String,
    output: &mut Vec<Value>,
) {
    if parts.is_empty() && tool_calls.is_empty() && reasoning.is_empty() {
        return;
    }
    let content = match parts.len() {
        0 => Value::String(String::new()),
        1 if parts[0].get("type").and_then(Value::as_str) == Some("text") => Value::String(
            parts[0]
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
        ),
        _ => Value::Array(std::mem::take(parts)),
    };
    parts.clear();
    let mut message = Map::new();
    message.insert("role".to_owned(), Value::String(role.to_owned()));
    message.insert("content".to_owned(), content);
    if !reasoning.is_empty() {
        message.insert(
            "reasoning_content".to_owned(),
            Value::String(std::mem::take(reasoning)),
        );
    }
    if !tool_calls.is_empty() {
        message.insert(
            "tool_calls".to_owned(),
            Value::Array(std::mem::take(tool_calls)),
        );
    }
    output.push(Value::Object(message));
}

fn anthropic_content_to_chat(content: Value, _role: &'static str) -> Result<Value, AdapterError> {
    match content {
        Value::Null | Value::String(_) => Ok(content),
        Value::Array(parts) => {
            enforce_count("message content", parts.len(), MAX_CONTENT_PARTS)?;
            let mut chat = Vec::new();
            for part in parts {
                let part = part.as_object().ok_or_else(|| {
                    AdapterError::invalid(
                        "Anthropic content blocks must be objects",
                        Some("messages"),
                    )
                })?;
                match part.get("type").and_then(Value::as_str) {
                    Some("text") => chat.push(json!({
                        "type": "text",
                        "text": part.get("text").and_then(Value::as_str).unwrap_or_default()
                    })),
                    Some("image") => chat.push(lower_anthropic_image(part)?),
                    Some("document") => chat.push(lower_anthropic_document(part)?),
                    _ => {
                        return Err(AdapterError::invalid(
                            "unsupported Anthropic content block type",
                            Some("messages"),
                        ));
                    }
                }
            }
            Ok(Value::Array(chat))
        }
        _ => Err(AdapterError::invalid(
            "Anthropic content must be a string or array",
            Some("messages"),
        )),
    }
}

fn lower_anthropic_image(block: &Map<String, Value>) -> Result<Value, AdapterError> {
    let source = block
        .get("source")
        .and_then(Value::as_object)
        .ok_or_else(|| AdapterError::invalid("image source is required", Some("messages")))?;
    let url = match source.get("type").and_then(Value::as_str) {
        Some("url") => required_nonempty(source, "url", "image URL is required")?.to_owned(),
        Some("base64") => {
            let media_type =
                required_nonempty(source, "media_type", "image media_type is required")?;
            let data = required_nonempty(source, "data", "image data is required")?;
            format!("data:{media_type};base64,{data}")
        }
        _ => {
            return Err(AdapterError::invalid(
                "image source type must be url or base64",
                Some("messages"),
            ));
        }
    };
    Ok(json!({"type": "image_url", "image_url": {"url": url}}))
}

fn lower_anthropic_document(block: &Map<String, Value>) -> Result<Value, AdapterError> {
    let source = block
        .get("source")
        .and_then(Value::as_object)
        .ok_or_else(|| AdapterError::invalid("document source is required", Some("messages")))?;
    Ok(json!({"type": "file", "file": source}))
}

fn lower_anthropic_tools(value: Value) -> Result<Value, AdapterError> {
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
            let name = required_nonempty(tool, "name", "tool name is required")?;
            Ok(json!({
                "type": "function",
                "function": {
                    "name": name,
                    "description": tool.get("description").cloned().unwrap_or(Value::Null),
                    "parameters": tool.get("input_schema").cloned().unwrap_or_else(|| json!({"type": "object"})),
                }
            }))
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Value::Array)
}

fn lower_anthropic_tool_choice(value: Value) -> Result<(Value, Option<bool>), AdapterError> {
    let choice = value.as_object().ok_or_else(|| {
        AdapterError::invalid("tool_choice must be an object", Some("tool_choice"))
    })?;
    let parallel = choice
        .get("disable_parallel_tool_use")
        .and_then(Value::as_bool)
        .map(|disabled| !disabled);
    let lowered = match choice.get("type").and_then(Value::as_str) {
        Some("auto") => Value::String("auto".to_owned()),
        Some("any") => Value::String("required".to_owned()),
        Some("none") => Value::String("none".to_owned()),
        Some("tool") => {
            let name = required_nonempty(choice, "name", "tool_choice name is required")?;
            json!({"type": "function", "function": {"name": name}})
        }
        _ => {
            return Err(AdapterError::invalid(
                "unsupported Anthropic tool_choice type",
                Some("tool_choice"),
            ));
        }
    };
    Ok((lowered, parallel))
}

fn required_nonempty<'a>(
    object: &'a Map<String, Value>,
    field: &'static str,
    message: &'static str,
) -> Result<&'a str, AdapterError> {
    object
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| AdapterError::invalid(message, Some(field)))
}

/// Converts canonical chat JSON to an Anthropic Message object.
pub fn adapt_anthropic_nonstream(
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
    let mut content = Vec::new();
    let reasoning = {
        let reasoning = message_text(message, "reasoning");
        if reasoning.is_empty() {
            message_text(message, "reasoning_content")
        } else {
            reasoning
        }
    };
    if !reasoning.is_empty() {
        content.push(json!({"type": "thinking", "thinking": reasoning, "signature": ""}));
    }
    let text = message_text(message, "content");
    if !text.is_empty() || message.get("tool_calls").is_none() {
        content.push(json!({"type": "text", "text": text}));
    }
    if let Some(calls) = message.get("tool_calls").and_then(Value::as_array) {
        for call in calls {
            content.push(anthropic_tool_use(call)?);
        }
    }
    let finish = choice
        .get("finish_reason")
        .and_then(Value::as_str)
        .unwrap_or("stop");
    let finish = effective_finish_reason(
        finish,
        message
            .get("tool_calls")
            .and_then(Value::as_array)
            .is_some_and(|calls| !calls.is_empty()),
    );
    let value = json!({
        "id": context.message_id(),
        "type": "message",
        "role": "assistant",
        "content": content,
        "model": if context.model.is_empty() { chat.model.as_str() } else { context.model.as_str() },
        "stop_reason": anthropic_stop_reason(finish),
        "stop_sequence": Value::Null,
        "usage": anthropic_usage(chat.usage),
    });
    serde_json::to_vec(&value)
        .map_err(|_| AdapterError::invalid("Anthropic response could not be encoded", None))
}

fn anthropic_tool_use(call: &Value) -> Result<Value, AdapterError> {
    let function = call.get("function").and_then(Value::as_object);
    let arguments = function
        .and_then(|function| function.get("arguments"))
        .and_then(Value::as_str)
        .unwrap_or("{}");
    let input =
        serde_json::from_str(arguments).unwrap_or_else(|_| Value::String(arguments.to_owned()));
    Ok(json!({
        "type": "tool_use",
        "id": call.get("id").and_then(Value::as_str).unwrap_or_default(),
        "name": function.and_then(|function| function.get("name")).and_then(Value::as_str).unwrap_or_default(),
        "input": input,
    }))
}

fn anthropic_stop_reason(reason: &str) -> &'static str {
    match reason {
        "length" => "max_tokens",
        "tool_calls" | "function_call" => "tool_use",
        "stop" => "end_turn",
        _ => "end_turn",
    }
}

fn effective_finish_reason(reason: &str, has_tools: bool) -> &str {
    if reason == "stop" && has_tools {
        "tool_calls"
    } else {
        reason
    }
}

fn anthropic_usage(usage: ChatUsage) -> Value {
    json!({
        "input_tokens": usage.prompt_tokens,
        "output_tokens": usage.completion_tokens,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": usage.cached_tokens,
    })
}

#[derive(Debug)]
struct ToolStreamState {
    block_index: usize,
    call: Value,
    started: bool,
}

/// Stateful chat-SSE to Anthropic Messages-SSE adapter.
#[derive(Debug)]
pub struct AnthropicStreamAdapter {
    context: AdapterContext,
    source: CanonicalChatStream,
    started: bool,
    text_block: Option<usize>,
    reasoning_block: Option<usize>,
    tools: BTreeMap<u64, ToolStreamState>,
    open_blocks: BTreeSet<usize>,
    next_block: usize,
    finish_reason: String,
    usage: ChatUsage,
    saw_tool: bool,
    terminal: bool,
}

impl AnthropicStreamAdapter {
    #[must_use]
    pub fn new(context: AdapterContext) -> Self {
        Self {
            context,
            source: CanonicalChatStream::default(),
            started: false,
            text_block: None,
            reasoning_block: None,
            tools: BTreeMap::new(),
            open_blocks: BTreeSet::new(),
            next_block: 0,
            finish_reason: "stop".to_owned(),
            usage: ChatUsage::default(),
            saw_tool: false,
            terminal: false,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Vec<u8>>, AdapterError> {
        let events = self.source.push(bytes)?;
        self.adapt_events(events)
    }

    fn adapt_events(&mut self, events: Vec<ChatSseEvent>) -> Result<Vec<Vec<u8>>, AdapterError> {
        let mut output = Vec::new();
        // Empty successful streams are released as one terminal batch. Capture
        // their held usage before constructing `message_start` so prompt usage
        // is not lost merely because no content committed earlier.
        for event in &events {
            if let ChatSseEvent::Chunk(chunk) = event
                && let Some(usage) = chunk.usage.as_ref()
            {
                self.usage = ChatUsage::from_value(Some(usage));
            }
        }
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

    fn start(&mut self, output: &mut Vec<Vec<u8>>) -> Result<(), AdapterError> {
        if self.started {
            return Ok(());
        }
        self.started = true;
        output.push(anthropic_sse(
            "message_start",
            json!({
                "type": "message_start",
                "message": {
                    "id": self.context.message_id(),
                    "type": "message",
                    "role": "assistant",
                    "content": [],
                    "model": self.context.model,
                    "stop_reason": Value::Null,
                    "stop_sequence": Value::Null,
                    "usage": anthropic_usage(self.usage),
                }
            }),
        )?);
        Ok(())
    }

    fn open_block(
        &mut self,
        block: Value,
        output: &mut Vec<Vec<u8>>,
    ) -> Result<usize, AdapterError> {
        let index = self.next_block;
        self.next_block += 1;
        self.open_blocks.insert(index);
        output.push(anthropic_sse(
            "content_block_start",
            json!({"type": "content_block_start", "index": index, "content_block": block}),
        )?);
        Ok(index)
    }

    fn text_delta(&mut self, text: &str, output: &mut Vec<Vec<u8>>) -> Result<(), AdapterError> {
        let index = match self.text_block {
            Some(index) => index,
            None => {
                let index = self.open_block(json!({"type": "text", "text": ""}), output)?;
                self.text_block = Some(index);
                index
            }
        };
        output.push(anthropic_sse(
            "content_block_delta",
            json!({
                "type": "content_block_delta",
                "index": index,
                "delta": {"type": "text_delta", "text": text}
            }),
        )?);
        Ok(())
    }

    fn reasoning_delta(
        &mut self,
        reasoning: &str,
        output: &mut Vec<Vec<u8>>,
    ) -> Result<(), AdapterError> {
        let index = match self.reasoning_block {
            Some(index) => index,
            None => {
                let index = self.open_block(
                    json!({"type": "thinking", "thinking": "", "signature": ""}),
                    output,
                )?;
                self.reasoning_block = Some(index);
                index
            }
        };
        output.push(anthropic_sse(
            "content_block_delta",
            json!({
                "type": "content_block_delta",
                "index": index,
                "delta": {"type": "thinking_delta", "thinking": reasoning}
            }),
        )?);
        Ok(())
    }

    fn tool_delta(
        &mut self,
        fragment: &Value,
        output: &mut Vec<Vec<u8>>,
    ) -> Result<(), AdapterError> {
        let source_index = fragment.get("index").and_then(Value::as_u64).unwrap_or(0);
        self.saw_tool = true;
        if !self.tools.contains_key(&source_index) {
            let block_index = self.next_block;
            self.next_block += 1;
            self.open_blocks.insert(block_index);
            self.tools.insert(
                source_index,
                ToolStreamState {
                    block_index,
                    call: json!({"id": "", "type": "function", "function": {"name": "", "arguments": ""}}),
                    started: false,
                },
            );
        }
        let state = self
            .tools
            .get_mut(&source_index)
            .expect("inserted tool state");
        merge_tool_value(&mut state.call, fragment);
        if !state.started {
            state.started = true;
            output.push(anthropic_sse(
                "content_block_start",
                json!({
                    "type": "content_block_start",
                    "index": state.block_index,
                    "content_block": {
                        "type": "tool_use",
                        "id": state.call.get("id").and_then(Value::as_str).unwrap_or_default(),
                        "name": state.call.pointer("/function/name").and_then(Value::as_str).unwrap_or_default(),
                        "input": {}
                    }
                }),
            )?);
        }
        if let Some(arguments) = fragment
            .pointer("/function/arguments")
            .and_then(Value::as_str)
            .filter(|arguments| !arguments.is_empty())
        {
            output.push(anthropic_sse(
                "content_block_delta",
                json!({
                    "type": "content_block_delta",
                    "index": state.block_index,
                    "delta": {"type": "input_json_delta", "partial_json": arguments}
                }),
            )?);
        }
        Ok(())
    }

    fn complete(&mut self, output: &mut Vec<Vec<u8>>) -> Result<(), AdapterError> {
        if self.terminal {
            return Err(AdapterError::invalid(
                "provider emitted duplicate completion",
                None,
            ));
        }
        if self.open_blocks.is_empty() {
            let index = self.open_block(json!({"type": "text", "text": ""}), output)?;
            self.text_block = Some(index);
        }
        for index in std::mem::take(&mut self.open_blocks) {
            output.push(anthropic_sse(
                "content_block_stop",
                json!({"type": "content_block_stop", "index": index}),
            )?);
        }
        output.push(anthropic_sse(
            "message_delta",
            json!({
                "type": "message_delta",
                "delta": {
                    "stop_reason": anthropic_stop_reason(effective_finish_reason(
                        &self.finish_reason,
                        self.saw_tool,
                    )),
                    "stop_sequence": Value::Null,
                },
                "usage": {
                    "output_tokens": self.usage.completion_tokens,
                }
            }),
        )?);
        output.push(anthropic_sse(
            "message_stop",
            json!({"type": "message_stop"}),
        )?);
        self.terminal = true;
        Ok(())
    }

    pub fn finish_input(&mut self) -> Result<Vec<Vec<u8>>, AdapterError> {
        let events = self.source.finish_input()?;
        self.adapt_events(events)
    }

    #[must_use]
    pub const fn is_committed(&self) -> bool {
        self.source.is_committed()
    }

    pub fn fail(&self, error: AdapterError) -> AdaptedStreamFailure {
        if !self.is_committed() {
            return AdaptedStreamFailure::PreCommit(error);
        }
        let event = anthropic_sse("error", error.anthropic_json()).unwrap_or_else(|_| {
            b"event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"stream failed\"}}\n\n".to_vec()
        });
        AdaptedStreamFailure::Committed(vec![event])
    }

    pub fn cancel(&self) -> AdaptedStreamFailure {
        self.fail(AdapterError::cancelled())
    }
}

fn merge_tool_value(target: &mut Value, fragment: &Value) {
    let Some(target) = target.as_object_mut() else {
        return;
    };
    if let Some(id) = fragment.get("id").and_then(Value::as_str)
        && !id.is_empty()
    {
        target.insert("id".to_owned(), Value::String(id.to_owned()));
    }
    let Some(piece) = fragment.get("function").and_then(Value::as_object) else {
        return;
    };
    let Some(function) = target.get_mut("function").and_then(Value::as_object_mut) else {
        return;
    };
    for field in ["name", "arguments"] {
        if let Some(value) = piece.get(field).and_then(Value::as_str) {
            let previous = function
                .get(field)
                .and_then(Value::as_str)
                .unwrap_or_default();
            function.insert(
                field.to_owned(),
                Value::String(format!("{previous}{value}")),
            );
        }
    }
}

fn anthropic_sse(event: &str, value: Value) -> Result<Vec<u8>, AdapterError> {
    let mut output = format!("event: {event}\ndata: ").into_bytes();
    output.extend_from_slice(
        &serde_json::to_vec(&value)
            .map_err(|_| AdapterError::invalid("Anthropic event could not be encoded", None))?,
    );
    output.extend_from_slice(b"\n\n");
    Ok(output)
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
    fn request_preserves_tools_images_reasoning_and_sampling() {
        let request = parse_anthropic_request(
            br#"{
              "model":"model-a","max_tokens":100,"stream":true,"temperature":0.2,"top_p":0.9,"top_k":10,
              "thinking":{"type":"enabled","budget_tokens":50},
              "system":"system",
              "messages":[{"role":"user","content":[
                {"type":"text","text":"look"},
                {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}
              ]}],
              "tools":[{"name":"weather","description":"weather","input_schema":{"type":"object"}}],
              "tool_choice":{"type":"tool","name":"weather","disable_parallel_tool_use":true}
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
        assert_eq!(chat["parallel_tool_calls"], false);
        assert_eq!(chat["reasoning_effort"], "high");
        assert_eq!(chat["thinking"]["budget_tokens"], 50);
    }

    #[test]
    fn nonstream_tools_and_usage_have_anthropic_shape() {
        let chat = br#"{"id":"chatcmpl-x","object":"chat.completion","created":2,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"weather","arguments":"{\"city\":\"SF\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}"#;
        let output = adapt_anthropic_nonstream(chat, &context()).expect("adapt");
        let output: Value = serde_json::from_slice(&output).expect("JSON");
        assert_eq!(output["type"], "message");
        assert_eq!(output["content"][0]["type"], "tool_use");
        assert_eq!(output["content"][0]["input"]["city"], "SF");
        assert_eq!(output["stop_reason"], "tool_use");
        assert_eq!(output["usage"]["input_tokens"], 2);
    }

    #[test]
    fn empty_success_has_message_shapes_and_prompt_usage() {
        let empty = br#"data: {"id":"chatcmpl-empty","object":"chat.completion.chunk","created":2,"model":"model-a","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"id":"chatcmpl-empty","object":"chat.completion.chunk","created":2,"model":"model-a","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":0,"total_tokens":3}}

data: [DONE]

"#;
        let output = adapt_anthropic_nonstream(empty, &context()).expect("empty nonstream");
        let output: Value = serde_json::from_slice(&output).expect("empty message JSON");
        assert_eq!(output["content"][0]["type"], "text");
        assert_eq!(output["content"][0]["text"], "");
        assert_eq!(output["stop_reason"], "end_turn");
        assert_eq!(output["usage"]["input_tokens"], 3);
        assert_eq!(output["usage"]["output_tokens"], 0);

        let mut stream = AnthropicStreamAdapter::new(context());
        assert!(stream.push(empty).expect("held empty stream").is_empty());
        let output = stream.finish_input().expect("finish empty stream");
        let text = output
            .iter()
            .map(|event| String::from_utf8_lossy(event))
            .collect::<String>();
        assert!(text.contains("event: message_start"));
        assert!(text.contains("\"input_tokens\":3"));
        assert!(text.contains("event: content_block_start"));
        assert!(text.contains("\"text\":\"\""));
        assert!(text.contains("\"output_tokens\":0"));
        assert!(text.contains("event: message_stop"));
    }

    #[test]
    fn streaming_emits_message_content_and_terminal_events_after_commit() {
        let mut adapter = AnthropicStreamAdapter::new(context());
        let role = br#"data: {"id":"c","object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}

"#;
        assert!(adapter.push(role).expect("role").is_empty());
        let output = adapter
            .push(br#"data: {"id":"c","object":"chat.completion.chunk","choices":[{"delta":{"content":"hello"},"finish_reason":"stop"}]}

data: [DONE]

"#)
            .expect("stream");
        let text = output
            .iter()
            .map(|event| String::from_utf8_lossy(event))
            .collect::<String>();
        assert!(text.contains("event: message_start"));
        assert!(text.contains("\"type\":\"text_delta\""));
        assert!(text.contains("\"text\":\"hello\""));
        assert!(text.contains("event: message_stop"));
    }

    #[test]
    fn required_fields_unknown_blocks_and_tool_limits_are_rejected() {
        assert!(parse_anthropic_request(br#"{"model":"m","messages":[]}"#).is_err());
        assert!(
            parse_anthropic_request(
                br#"{"model":"m","max_tokens":1,"messages":[{"role":"user","content":[{"type":"audio"}]}]}"#
            )
            .is_err()
        );
        let request = json!({
            "model": "m",
            "max_tokens": 1,
            "messages": [{"role":"user","content":"hello"}],
            "tools": (0..=MAX_TOOLS)
                .map(|index| json!({"name":format!("tool_{index}"),"input_schema":{"type":"object"}}))
                .collect::<Vec<_>>(),
        });
        let error =
            parse_anthropic_request(&serde_json::to_vec(&request).expect("oversized tools JSON"))
                .expect_err("tool count limit");
        assert!(error.message().contains("at most 128"));
    }
}
