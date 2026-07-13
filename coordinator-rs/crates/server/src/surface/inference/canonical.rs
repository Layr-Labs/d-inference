use std::{collections::BTreeMap, fmt};

use serde_json::{Map, Value, json};

use super::{
    AdapterError,
    limits::{
        MAX_JSON_TOTAL_STRING_BYTES, MAX_JSON_VALUES, MAX_RESPONSE_BYTES, MAX_SSE_EVENT_BYTES,
        MAX_SSE_EVENTS, maximum_output_tokens, parse_response_object, serialize_canonical,
        validate_canonical_cardinality, validate_model, validate_single_choice, validate_stream,
    },
};

/// Public inference surface represented by a canonical chat request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InferenceSurface {
    Responses,
    Completions,
    AnthropicMessages,
}

/// The exact chat-completions JSON accepted by `Pilot`'s request dispatcher.
///
/// The body is intentionally omitted from `Debug`; it can contain prompt,
/// image, tool, and reasoning data.
pub struct CanonicalChatRequest {
    body: Vec<u8>,
    model: String,
    stream: bool,
    maximum_output_tokens: u64,
    source: InferenceSurface,
}

impl CanonicalChatRequest {
    pub(crate) fn from_object(
        object: Map<String, Value>,
        source: InferenceSurface,
    ) -> Result<Self, AdapterError> {
        validate_canonical_cardinality(&object)?;
        validate_single_choice(&object)?;
        let model = validate_model(&object)?;
        let stream = validate_stream(&object)?;
        let maximum_output_tokens = maximum_output_tokens(&object)?;
        let body = serialize_canonical(&Value::Object(object))?;
        Ok(Self {
            body,
            model,
            stream,
            maximum_output_tokens,
            source,
        })
    }

    #[must_use]
    pub fn body(&self) -> &[u8] {
        &self.body
    }

    #[must_use]
    pub fn into_body(self) -> Vec<u8> {
        self.body
    }

    #[must_use]
    pub fn model(&self) -> &str {
        &self.model
    }

    #[must_use]
    pub const fn stream(&self) -> bool {
        self.stream
    }

    #[must_use]
    pub const fn maximum_output_tokens(&self) -> u64 {
        self.maximum_output_tokens
    }

    #[must_use]
    pub const fn source(&self) -> InferenceSurface {
        self.source
    }
}

impl fmt::Debug for CanonicalChatRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CanonicalChatRequest")
            .field("body_bytes", &self.body.len())
            .field("model", &self.model)
            .field("stream", &self.stream)
            .field("maximum_output_tokens", &self.maximum_output_tokens)
            .field("source", &self.source)
            .finish()
    }
}

/// Stable metadata supplied by the HTTP integration layer.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdapterContext {
    pub request_id: String,
    pub model: String,
    pub created_at: i64,
    pub maximum_output_tokens: u64,
}

/// Endpoint-specific handling for an error after checking source commitment.
#[derive(Debug)]
pub enum AdaptedStreamFailure {
    /// No consumer bytes were emitted; the router can still return an HTTP
    /// error or retry another attempt.
    PreCommit(AdapterError),
    /// Consumer bytes were already committed; these terminal SSE frames must
    /// be written in-band and no retry is permitted.
    Committed(Vec<Vec<u8>>),
}

impl AdapterContext {
    #[must_use]
    pub fn response_id(&self) -> String {
        format!("resp_{}", compact_id(&self.request_id))
    }

    #[must_use]
    pub fn message_id(&self) -> String {
        format!("msg_{}", compact_id(&self.request_id))
    }
}

pub(crate) fn compact_id(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || *character == '_')
        .collect()
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ChatUsage {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub total_tokens: u64,
    pub reasoning_tokens: u64,
    pub cached_tokens: u64,
}

impl ChatUsage {
    #[must_use]
    pub fn from_value(value: Option<&Value>) -> Self {
        let Some(value) = value else {
            return Self::default();
        };
        let prompt_tokens = unsigned(value.get("prompt_tokens"));
        let completion_tokens = unsigned(value.get("completion_tokens"));
        let total_tokens = unsigned(value.get("total_tokens"))
            .max(prompt_tokens.saturating_add(completion_tokens));
        let reasoning_tokens = value
            .get("completion_tokens_details")
            .map_or(0, |details| unsigned(details.get("reasoning_tokens")));
        let cached_tokens = value
            .get("prompt_tokens_details")
            .map_or(0, |details| unsigned(details.get("cached_tokens")));
        Self {
            prompt_tokens,
            completion_tokens,
            total_tokens,
            reasoning_tokens,
            cached_tokens,
        }
    }
}

fn unsigned(value: Option<&Value>) -> u64 {
    value.and_then(Value::as_u64).unwrap_or(0)
}

/// Bounded canonical chat-completion object.
#[derive(Clone, Debug)]
pub struct ChatCompletion {
    pub object: Map<String, Value>,
    pub id: String,
    pub created: i64,
    pub model: String,
    pub choices: Vec<Value>,
    pub usage: ChatUsage,
}

impl ChatCompletion {
    pub fn parse(bytes: &[u8]) -> Result<Self, AdapterError> {
        if bytes
            .iter()
            .find(|byte| !byte.is_ascii_whitespace())
            .is_some_and(|byte| *byte != b'{')
        {
            return assemble_chat_completion_sse(bytes);
        }
        let object = parse_response_object(bytes)?;
        Self::from_object(object)
    }

    fn from_object(object: Map<String, Value>) -> Result<Self, AdapterError> {
        if object.get("object").and_then(Value::as_str) != Some("chat.completion") {
            return Err(AdapterError::invalid(
                "provider returned a non-chat completion object",
                None,
            ));
        }
        let choices = object
            .get("choices")
            .and_then(Value::as_array)
            .filter(|choices| !choices.is_empty())
            .cloned()
            .ok_or_else(|| {
                AdapterError::invalid("provider returned no completion choices", None)
            })?;
        let id = object
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let created = object.get("created").and_then(Value::as_i64).unwrap_or(0);
        let model = object
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let usage = ChatUsage::from_value(object.get("usage"));
        Ok(Self {
            object,
            id,
            created,
            model,
            choices,
            usage,
        })
    }
}

#[derive(Debug, Default)]
struct ChoiceAssembly {
    role: Option<String>,
    content: String,
    reasoning: String,
    reasoning_content: String,
    refusal: String,
    tool_calls: BTreeMap<u64, Value>,
    finish_reason: Option<Value>,
    logprobs: Option<Value>,
}

fn assemble_chat_completion_sse(bytes: &[u8]) -> Result<ChatCompletion, AdapterError> {
    let mut stream = CanonicalChatStream::default();
    let mut events = stream.push(bytes)?;
    events.extend(stream.finish_input()?);
    let mut id = String::new();
    let mut created = 0_i64;
    let mut model = String::new();
    let mut usage = None;
    let mut choices: BTreeMap<u64, ChoiceAssembly> = BTreeMap::new();
    for event in events {
        let ChatSseEvent::Chunk(chunk) = event else {
            continue;
        };
        if chunk.object.get("object").and_then(Value::as_str) == Some("chat.completion") {
            return ChatCompletion::from_object(chunk.object);
        }
        if id.is_empty() {
            id = chunk.id;
        }
        if created == 0 {
            created = chunk.created;
        }
        if model.is_empty() {
            model = chunk.model;
        }
        if chunk.usage.is_some() {
            usage = chunk.usage;
        }
        for source_choice in chunk.choices {
            let index = source_choice
                .get("index")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            let choice = choices.entry(index).or_default();
            if let Some(reason) = source_choice
                .get("finish_reason")
                .filter(|reason| !reason.is_null())
            {
                choice.finish_reason = Some(reason.clone());
            }
            if let Some(logprobs) = source_choice
                .get("logprobs")
                .filter(|logprobs| !logprobs.is_null())
            {
                choice.logprobs = Some(logprobs.clone());
            }
            let Some(delta) = delta_object(&source_choice) else {
                continue;
            };
            if let Some(role) = delta.get("role").and_then(Value::as_str) {
                choice.role = Some(role.to_owned());
            }
            append_delta(delta, "content", &mut choice.content);
            append_delta(delta, "reasoning", &mut choice.reasoning);
            append_delta(delta, "reasoning_content", &mut choice.reasoning_content);
            append_delta(delta, "refusal", &mut choice.refusal);
            if let Some(calls) = delta.get("tool_calls").and_then(Value::as_array) {
                for call in calls {
                    merge_tool_call(&mut choice.tool_calls, call)?;
                }
            }
        }
    }
    if choices.is_empty() {
        return Err(AdapterError::invalid(
            "provider returned no completion choices",
            None,
        ));
    }
    let choices = choices
        .into_iter()
        .map(|(index, choice)| assembled_choice(index, choice))
        .collect::<Vec<_>>();
    let mut object = Map::new();
    object.insert("id".to_owned(), Value::String(id));
    object.insert(
        "object".to_owned(),
        Value::String("chat.completion".to_owned()),
    );
    object.insert("created".to_owned(), Value::from(created));
    object.insert("model".to_owned(), Value::String(model));
    object.insert("choices".to_owned(), Value::Array(choices));
    if let Some(usage) = usage {
        object.insert("usage".to_owned(), usage);
    }
    ChatCompletion::from_object(object)
}

fn append_delta(delta: &Map<String, Value>, field: &str, target: &mut String) {
    if let Some(fragment) = delta.get(field).and_then(Value::as_str) {
        target.push_str(fragment);
    }
}

fn assembled_choice(index: u64, choice: ChoiceAssembly) -> Value {
    let mut message = Map::new();
    message.insert(
        "role".to_owned(),
        Value::String(choice.role.unwrap_or_else(|| "assistant".to_owned())),
    );
    message.insert("content".to_owned(), Value::String(choice.content));
    if !choice.reasoning.is_empty() {
        message.insert("reasoning".to_owned(), Value::String(choice.reasoning));
    }
    if !choice.reasoning_content.is_empty() {
        message.insert(
            "reasoning_content".to_owned(),
            Value::String(choice.reasoning_content),
        );
    }
    if !choice.refusal.is_empty() {
        message.insert("refusal".to_owned(), Value::String(choice.refusal));
    }
    if !choice.tool_calls.is_empty() {
        message.insert(
            "tool_calls".to_owned(),
            Value::Array(choice.tool_calls.into_values().collect()),
        );
    }
    json!({
        "index": index,
        "message": message,
        "finish_reason": choice.finish_reason.unwrap_or(Value::Null),
        "logprobs": choice.logprobs.unwrap_or(Value::Null),
    })
}

#[derive(Clone, Debug)]
pub enum ChatSseEvent {
    Chunk(ChatChunk),
    Done,
}

#[derive(Clone, Debug)]
pub struct ChatChunk {
    pub object: Map<String, Value>,
    pub id: String,
    pub created: i64,
    pub model: String,
    pub choices: Vec<Value>,
    pub usage: Option<Value>,
}

impl ChatChunk {
    fn from_value(value: Value) -> Result<Self, AdapterError> {
        let object = value.as_object().cloned().ok_or_else(|| {
            AdapterError::invalid("provider SSE payload must be a JSON object", None)
        })?;
        let kind = object.get("object").and_then(Value::as_str);
        if !matches!(kind, Some("chat.completion.chunk" | "chat.completion")) {
            return Err(AdapterError::invalid(
                "provider SSE payload is not a chat completion chunk",
                None,
            ));
        }
        let id = object
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let created = object.get("created").and_then(Value::as_i64).unwrap_or(0);
        let model = object
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let choices = object
            .get("choices")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let usage = object
            .get("usage")
            .filter(|usage| !usage.is_null())
            .cloned();
        Ok(Self {
            object,
            id,
            created,
            model,
            choices,
            usage,
        })
    }

    #[must_use]
    pub fn is_content_bearing(&self) -> bool {
        self.choices.iter().any(choice_has_content)
    }
}

fn choice_has_content(choice: &Value) -> bool {
    let Some(delta) = choice
        .get("delta")
        .or_else(|| choice.get("message"))
        .and_then(Value::as_object)
    else {
        return false;
    };
    for field in ["content", "reasoning", "reasoning_content", "refusal"] {
        if delta
            .get(field)
            .is_some_and(|value| value.as_str().is_some_and(|text| !text.is_empty()))
        {
            return true;
        }
    }
    delta
        .get("tool_calls")
        .and_then(Value::as_array)
        .is_some_and(|calls| calls.iter().any(tool_call_has_output))
}

fn tool_call_has_output(call: &Value) -> bool {
    ["id", "type"]
        .iter()
        .any(|field| nonempty_string(call.get(*field)))
        || call.get("function").is_some_and(|function| {
            ["name", "arguments"]
                .iter()
                .any(|field| nonempty_string(function.get(*field)))
        })
}

fn nonempty_string(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|text| !text.is_empty())
}

/// Incremental finite SSE parser plus the source commitment boundary.
#[derive(Debug, Default)]
pub struct CanonicalChatStream {
    decoder: SseDecoder,
    held: Vec<ChatSseEvent>,
    committed: bool,
    done: bool,
}

impl CanonicalChatStream {
    /// Accepts arbitrarily fragmented exact provider bytes. Nothing is returned
    /// before nonempty content, reasoning, refusal, or tool output commits the
    /// source attempt. Usage and lifecycle metadata remain held.
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<ChatSseEvent>, AdapterError> {
        if self.done {
            return Err(AdapterError::invalid(
                "provider emitted bytes after the SSE terminator",
                None,
            ));
        }
        let mut ready = Vec::new();
        for payload in self.decoder.push(bytes)? {
            self.accept_payload(payload, &mut ready)?;
        }
        Ok(ready)
    }

    /// Flushes a final event without a trailing blank line.
    pub fn finish_input(&mut self) -> Result<Vec<ChatSseEvent>, AdapterError> {
        let payloads = self.decoder.finish()?;
        let mut ready = Vec::new();
        for payload in payloads {
            self.accept_payload(payload, &mut ready)?;
        }
        if !self.done {
            return Err(AdapterError::invalid(
                "provider SSE stream is missing data: [DONE]",
                None,
            ));
        }
        if !self.committed {
            self.committed = true;
            ready.append(&mut self.held);
        }
        Ok(ready)
    }

    fn accept_payload(
        &mut self,
        payload: SsePayload,
        ready: &mut Vec<ChatSseEvent>,
    ) -> Result<(), AdapterError> {
        if self.done {
            return Err(AdapterError::invalid(
                "provider emitted an event after data: [DONE]",
                None,
            ));
        }
        let event = match payload {
            SsePayload::Done => {
                self.done = true;
                ChatSseEvent::Done
            }
            SsePayload::Json(value) => ChatSseEvent::Chunk(ChatChunk::from_value(value)?),
        };
        let first_content = matches!(
            &event,
            ChatSseEvent::Chunk(chunk) if chunk.is_content_bearing()
        ) && !self.committed;
        if first_content {
            self.committed = true;
            ready.append(&mut self.held);
        }
        if self.committed {
            ready.push(event);
        } else {
            self.held.push(event);
        }
        Ok(())
    }

    #[must_use]
    pub const fn is_committed(&self) -> bool {
        self.committed
    }

    #[must_use]
    pub const fn is_done(&self) -> bool {
        self.done
    }
}

#[derive(Debug)]
enum SsePayload {
    Json(Value),
    Done,
}

#[derive(Debug, Default)]
struct SseDecoder {
    buffer: Vec<u8>,
    events: usize,
    total_bytes: usize,
    json_values: usize,
    json_string_bytes: usize,
}

impl SseDecoder {
    fn push(&mut self, bytes: &[u8]) -> Result<Vec<SsePayload>, AdapterError> {
        self.total_bytes = self.total_bytes.checked_add(bytes.len()).ok_or_else(|| {
            AdapterError::limit("provider SSE byte count overflow".to_owned(), None)
        })?;
        if self.total_bytes > MAX_RESPONSE_BYTES {
            return Err(AdapterError::limit(
                format!("provider SSE exceeds {MAX_RESPONSE_BYTES} bytes"),
                None,
            ));
        }
        self.buffer.extend_from_slice(bytes);
        let mut payloads = Vec::new();
        let mut consumed = 0;
        while let Some((relative_end, separator)) = event_separator(&self.buffer[consumed..]) {
            let end = consumed + relative_end;
            let event = self.buffer[consumed..end].to_vec();
            consumed = end + separator;
            if let Some(payload) = self.decode_event(&event)? {
                payloads.push(payload);
            }
        }
        if consumed > 0 {
            self.buffer.drain(..consumed);
        }
        if self.buffer.len() > MAX_SSE_EVENT_BYTES {
            return Err(AdapterError::limit(
                format!("provider SSE event exceeds {MAX_SSE_EVENT_BYTES} bytes"),
                None,
            ));
        }
        Ok(payloads)
    }

    fn finish(&mut self) -> Result<Vec<SsePayload>, AdapterError> {
        if self.buffer.is_empty() {
            return Ok(Vec::new());
        }
        let event = std::mem::take(&mut self.buffer);
        Ok(self.decode_event(&event)?.into_iter().collect())
    }

    fn decode_event(&mut self, event: &[u8]) -> Result<Option<SsePayload>, AdapterError> {
        if event.len() > MAX_SSE_EVENT_BYTES {
            return Err(AdapterError::limit(
                format!("provider SSE event exceeds {MAX_SSE_EVENT_BYTES} bytes"),
                None,
            ));
        }
        self.events = self.events.checked_add(1).ok_or_else(|| {
            AdapterError::limit("provider SSE event count overflow".to_owned(), None)
        })?;
        if self.events > MAX_SSE_EVENTS {
            return Err(AdapterError::limit(
                format!("provider SSE exceeds {MAX_SSE_EVENTS} events"),
                None,
            ));
        }
        if event.iter().all(u8::is_ascii_whitespace) {
            return Ok(None);
        }
        let text = std::str::from_utf8(event)
            .map_err(|_| AdapterError::invalid("provider SSE is not valid UTF-8", None))?;
        let mut data = String::new();
        let mut found = false;
        for line in text.lines() {
            if let Some(value) = line.strip_prefix("data:") {
                if found {
                    data.push('\n');
                }
                data.push_str(value.strip_prefix(' ').unwrap_or(value));
                found = true;
            }
        }
        if !found {
            return Err(AdapterError::invalid(
                "provider SSE event has no data field",
                None,
            ));
        }
        let data = data.trim();
        if data == "[DONE]" {
            return Ok(Some(SsePayload::Done));
        }
        crate::pilot::validate_json_structure(data.as_bytes()).map_err(|_| {
            AdapterError::invalid("provider SSE data is malformed or exceeds limits", None)
        })?;
        let value: Value = serde_json::from_str(data).map_err(|_| {
            AdapterError::invalid("provider SSE data is malformed or exceeds limits", None)
        })?;
        self.reserve_json(&value)?;
        Ok(Some(SsePayload::Json(value)))
    }

    fn reserve_json(&mut self, value: &Value) -> Result<(), AdapterError> {
        let (values, string_bytes) = measure_json(value)?;
        self.json_values = self.json_values.checked_add(values).ok_or_else(|| {
            AdapterError::limit("provider SSE JSON value count overflow".to_owned(), None)
        })?;
        self.json_string_bytes = self
            .json_string_bytes
            .checked_add(string_bytes)
            .ok_or_else(|| {
                AdapterError::limit(
                    "provider SSE JSON string byte count overflow".to_owned(),
                    None,
                )
            })?;
        if self.json_values > MAX_JSON_VALUES {
            return Err(AdapterError::limit(
                format!("provider SSE JSON contains more than {MAX_JSON_VALUES} values"),
                None,
            ));
        }
        if self.json_string_bytes > MAX_JSON_TOTAL_STRING_BYTES {
            return Err(AdapterError::limit(
                format!(
                    "provider SSE JSON strings exceed {MAX_JSON_TOTAL_STRING_BYTES} total bytes"
                ),
                None,
            ));
        }
        Ok(())
    }
}

fn measure_json(value: &Value) -> Result<(usize, usize), AdapterError> {
    let mut values = 1_usize;
    let mut strings = 0_usize;
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
        Value::String(value) => strings = value.len(),
        Value::Array(items) => {
            for item in items {
                let (item_values, item_strings) = measure_json(item)?;
                values = values.checked_add(item_values).ok_or_else(|| {
                    AdapterError::limit("provider SSE JSON value count overflow".to_owned(), None)
                })?;
                strings = strings.checked_add(item_strings).ok_or_else(|| {
                    AdapterError::limit(
                        "provider SSE JSON string byte count overflow".to_owned(),
                        None,
                    )
                })?;
            }
        }
        Value::Object(object) => {
            for (key, item) in object {
                strings = strings.checked_add(key.len()).ok_or_else(|| {
                    AdapterError::limit(
                        "provider SSE JSON string byte count overflow".to_owned(),
                        None,
                    )
                })?;
                let (item_values, item_strings) = measure_json(item)?;
                values = values.checked_add(item_values).ok_or_else(|| {
                    AdapterError::limit("provider SSE JSON value count overflow".to_owned(), None)
                })?;
                strings = strings.checked_add(item_strings).ok_or_else(|| {
                    AdapterError::limit(
                        "provider SSE JSON string byte count overflow".to_owned(),
                        None,
                    )
                })?;
            }
        }
    }
    Ok((values, strings))
}

fn event_separator(buffer: &[u8]) -> Option<(usize, usize)> {
    let lf = buffer.windows(2).position(|window| window == b"\n\n");
    let crlf = buffer.windows(4).position(|window| window == b"\r\n\r\n");
    match (lf, crlf) {
        (Some(left), Some(right)) if left <= right => Some((left, 2)),
        (Some(_), Some(right)) => Some((right, 4)),
        (Some(left), None) => Some((left, 2)),
        (None, Some(right)) => Some((right, 4)),
        (None, None) => None,
    }
}

pub(crate) fn delta_object(choice: &Value) -> Option<&Map<String, Value>> {
    choice.get("delta").and_then(Value::as_object)
}

pub(crate) fn delta_text<'a>(delta: &'a Map<String, Value>, field: &str) -> &'a str {
    delta.get(field).and_then(Value::as_str).unwrap_or_default()
}

pub(crate) fn finish_reason(choice: &Value) -> Option<&str> {
    choice.get("finish_reason").and_then(Value::as_str)
}

pub(crate) fn message_object(choice: &Value) -> Option<&Map<String, Value>> {
    choice.get("message").and_then(Value::as_object)
}

pub(crate) fn message_text(message: &Map<String, Value>, field: &str) -> String {
    match message.get(field) {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|part| {
                part.get("text")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .collect::<Vec<_>>()
            .join(""),
        _ => String::new(),
    }
}

pub(crate) fn merge_tool_call(
    calls: &mut BTreeMap<u64, Value>,
    fragment: &Value,
) -> Result<(), AdapterError> {
    let index = fragment.get("index").and_then(Value::as_u64).unwrap_or(0);
    let target = calls.entry(index).or_insert_with(|| {
        serde_json::json!({
            "id": "",
            "type": "function",
            "function": {"name": "", "arguments": ""}
        })
    });
    let target = target.as_object_mut().ok_or_else(|| {
        AdapterError::invalid("provider emitted an invalid tool call fragment", None)
    })?;
    for field in ["id", "type"] {
        if let Some(value) = fragment.get(field).and_then(Value::as_str)
            && !value.is_empty()
        {
            target.insert(field.to_owned(), Value::String(value.to_owned()));
        }
    }
    if let Some(function) = fragment.get("function").and_then(Value::as_object) {
        let target_function = target
            .entry("function")
            .or_insert_with(|| serde_json::json!({"name": "", "arguments": ""}))
            .as_object_mut()
            .ok_or_else(|| {
                AdapterError::invalid("provider emitted an invalid tool function", None)
            })?;
        for field in ["name", "arguments"] {
            if let Some(piece) = function.get(field).and_then(Value::as_str) {
                let previous = target_function
                    .get(field)
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                target_function.insert(
                    field.to_owned(),
                    Value::String(format!("{previous}{piece}")),
                );
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_stream_waits_for_content_and_reassembles_fragmented_sse() {
        let mut stream = CanonicalChatStream::default();
        let role = br#"data: {"id":"c","object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}

"#;
        assert!(stream.push(&role[..17]).expect("fragment").is_empty());
        assert!(stream.push(&role[17..]).expect("role").is_empty());
        assert!(!stream.is_committed());

        let usage = br#"data: {"id":"c","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":2,"completion_tokens":0,"total_tokens":2}}

"#;
        assert!(stream.push(usage).expect("usage").is_empty());
        let finish = br#"data: {"id":"c","object":"chat.completion.chunk","choices":[{"delta":{},"finish_reason":"stop"}]}

"#;
        assert!(stream.push(finish).expect("finish metadata").is_empty());
        let empty_tool = br#"data: {"id":"c","object":"chat.completion.chunk","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":""}}]},"finish_reason":null}]}

"#;
        assert!(
            stream
                .push(empty_tool)
                .expect("empty tool metadata")
                .is_empty()
        );
        assert!(!stream.is_committed());

        let content = br#"data: {"id":"c","object":"chat.completion.chunk","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

"#;
        let ready = stream.push(content).expect("content");
        assert_eq!(ready.len(), 5);
        assert!(stream.is_committed());
        assert!(matches!(
            stream.push(b"data: [DONE]\n\n").expect("done").as_slice(),
            [ChatSseEvent::Done]
        ));
    }

    #[test]
    fn usage_only_done_commits_only_when_the_verified_source_finishes() {
        let mut stream = CanonicalChatStream::default();
        let usage = br#"data: {"id":"c","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":2,"completion_tokens":0,"total_tokens":2}}

"#;
        assert!(stream.push(usage).expect("usage").is_empty());
        assert!(
            stream
                .push(b"data: [DONE]\n\n")
                .expect("held done")
                .is_empty()
        );
        assert!(!stream.is_committed());
        let ready = stream.finish_input().expect("empty successful terminal");
        assert_eq!(ready.len(), 2);
        assert!(matches!(ready.last(), Some(ChatSseEvent::Done)));
        assert!(stream.is_committed());
    }

    #[test]
    fn separator_flood_is_bounded_by_event_count() {
        let mut stream = CanonicalChatStream::default();
        let separators = vec![b'\n'; (MAX_SSE_EVENTS + 1) * 2];
        let error = stream
            .push(&separators)
            .expect_err("empty events still consume the event budget");
        assert!(error.message().contains("events"));
    }

    #[test]
    fn structural_budget_is_cumulative_across_sse_events() {
        let choices = std::iter::repeat_n("{}", 4_096)
            .collect::<Vec<_>>()
            .join(",");
        let event =
            format!("data: {{\"object\":\"chat.completion.chunk\",\"choices\":[{choices}]}}\n\n");
        let mut stream = CanonicalChatStream::default();
        stream.push(event.as_bytes()).expect("first event");
        stream.push(event.as_bytes()).expect("second event");
        stream.push(event.as_bytes()).expect("third event");
        let error = stream
            .push(event.as_bytes())
            .expect_err("fourth event exceeds cumulative value budget");
        assert!(error.message().contains("values"));
    }

    #[test]
    fn existing_http_chat_fixture_is_accepted() {
        let fixture = include_str!("../../../../../../tests/contracts/http/core.json");
        let fixture: Value = serde_json::from_str(fixture).expect("fixture JSON");
        let body = fixture["response_shapes"]
            .as_array()
            .expect("shapes")
            .iter()
            .find(|shape| shape["name"] == "chat_non_streaming")
            .and_then(|shape| shape["body"].as_str())
            .expect("chat fixture");
        let response = ChatCompletion::parse(body.as_bytes()).expect("chat response");
        assert_eq!(response.usage.total_tokens, 3);
        assert_eq!(
            message_text(
                message_object(&response.choices[0]).expect("message"),
                "content"
            ),
            "hello"
        );
    }

    #[test]
    fn exact_sse_is_assembled_for_nonstream_adapters() {
        let exact = concat!(
            "data: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"created\":2,",
            "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},",
            "\"finish_reason\":null}]}\n\n",
            "data: {\"id\":\"c\",\"object\":\"chat.completion.chunk\",\"created\":2,",
            "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"},",
            "\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,",
            "\"completion_tokens\":1,\"total_tokens\":3}}\n\n",
            "data: [DONE]\n\n"
        );
        let response = ChatCompletion::parse(exact.as_bytes()).expect("assembled SSE");
        assert_eq!(response.object["object"], "chat.completion");
        assert_eq!(
            response.choices[0]["message"]["content"],
            Value::String("hello".to_owned())
        );
        assert_eq!(response.usage.total_tokens, 3);
    }
}
