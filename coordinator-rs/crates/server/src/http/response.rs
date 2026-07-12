use std::{collections::BTreeMap, io};

use axum::{
    body::{Body, Bytes},
    http::{
        HeaderName, HeaderValue, Response, StatusCode,
        header::{self, HeaderMap},
    },
};
use futures_util::stream;
use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::{
    crypto::X25519PublicKey,
    pilot::{PilotHandle, PilotResponse, RESPONSE_RESERVATION_BYTES},
    request::{BytePipeReceiver, OutputMode},
};

use super::body::SEALED_CONTENT_TYPE;

const X_EIGEN_SEALED: HeaderName = HeaderName::from_static("x-eigen-sealed");
const X_EIGEN_SEALED_KID: HeaderName = HeaderName::from_static("x-eigen-sealed-kid");
const MAX_SEALED_SSE_EVENTS: usize = 16_384;
const MAX_SEALED_SSE_EVENT_BYTES: usize = 1024 * 1024;
const SSE_WRAPPER_BYTES: usize = b"data: \n\n".len();
const NACL_SEAL_OVERHEAD_BYTES: usize = darkbloom_coordinator_protocol::crypto::NACL_BOX_NONCE_LEN
    + darkbloom_coordinator_protocol::crypto::NACL_BOX_TAG_LEN;

pub fn consumer_response(
    response: PilotResponse,
    pilot: PilotHandle,
    sender: Option<X25519PublicKey>,
) -> Response<Body> {
    let mode = response.output_mode;
    let body = match (mode, sender) {
        (OutputMode::Streaming, None) => plain_stream(response.body),
        (OutputMode::Streaming, Some(sender)) => {
            sealed_stream(response.body, pilot.clone(), sender)
        }
        (OutputMode::NonStreaming, sender) => nonstream_body(response.body, pilot.clone(), sender),
    };
    let mut result = Response::new(body);
    *result.status_mut() = StatusCode::OK;
    let headers = result.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    match (mode, sender) {
        (OutputMode::Streaming, None) => {
            headers.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("text/event-stream"),
            );
        }
        (OutputMode::Streaming, Some(_)) => {
            headers.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("text/event-stream"),
            );
            sealed_headers(headers, &pilot);
        }
        (OutputMode::NonStreaming, None) => {
            headers.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static("application/json"),
            );
        }
        (OutputMode::NonStreaming, Some(_)) => {
            headers.insert(
                header::CONTENT_TYPE,
                HeaderValue::from_static(SEALED_CONTENT_TYPE),
            );
            sealed_headers(headers, &pilot);
        }
    }
    result
}

fn plain_stream(body: BytePipeReceiver<Vec<u8>>) -> Body {
    Body::from_stream(stream::unfold(body, |mut body| async move {
        match body.recv().await {
            Ok(Some(bytes)) => Some((Ok::<Bytes, io::Error>(Bytes::from(bytes)), body)),
            Ok(None) => None,
            Err(error) => Some((Err(io::Error::other(error.to_string())), body)),
        }
    }))
}

struct SealedStreamState {
    body: BytePipeReceiver<Vec<u8>>,
    pilot: PilotHandle,
    sender: X25519PublicKey,
    events: SseEventBuffer,
    input_finished: bool,
    finished: bool,
}

#[derive(Default)]
struct SseEventBuffer {
    scratch: Vec<u8>,
    event_start: usize,
    scan_cursor: usize,
    event_count: usize,
    sealed_output_bytes: usize,
}

fn sealed_stream(
    body: BytePipeReceiver<Vec<u8>>,
    pilot: PilotHandle,
    sender: X25519PublicKey,
) -> Body {
    let state = SealedStreamState {
        body,
        pilot,
        sender,
        events: SseEventBuffer::default(),
        input_finished: false,
        finished: false,
    };
    Body::from_stream(stream::unfold(state, |mut state| async move {
        loop {
            if state.finished {
                return None;
            }
            match state.events.next_event(state.input_finished) {
                Ok(Some(event)) => {
                    let expected_bytes = sealed_event_wire_len(event.len())
                        .expect("event accounting validated the sealed wire length");
                    match seal_event_async(state.pilot.clone(), state.sender, event, expected_bytes)
                        .await
                    {
                        Ok(bytes) => {
                            return Some((Ok::<Bytes, io::Error>(Bytes::from(bytes)), state));
                        }
                        Err(error) => {
                            state.finished = true;
                            return Some((Err(io::Error::other(error)), state));
                        }
                    }
                }
                Ok(None) if state.input_finished => {
                    return None;
                }
                Ok(None) => {}
                Err(error) => {
                    state.finished = true;
                    return Some((Err(io::Error::other(error)), state));
                }
            }
            match state.body.recv().await {
                Ok(Some(bytes)) => {
                    state.events.push(&bytes);
                }
                Ok(None) => {
                    state.input_finished = true;
                }
                Err(error) => {
                    state.finished = true;
                    return Some((Err(io::Error::other(error.to_string())), state));
                }
            }
        }
    }))
}

impl SseEventBuffer {
    fn push(&mut self, bytes: &[u8]) {
        self.scratch.extend_from_slice(bytes);
    }

    fn next_event(&mut self, input_finished: bool) -> Result<Option<Vec<u8>>, String> {
        while self.scan_cursor + 1 < self.scratch.len() {
            if self.scratch[self.scan_cursor] == b'\n'
                && self.scratch[self.scan_cursor + 1] == b'\n'
            {
                let event_end = self.scan_cursor;
                let event_len = event_end.saturating_sub(self.event_start);
                self.reserve_event(event_len)?;
                let event = if event_len == 0 {
                    None
                } else {
                    Some(self.scratch[self.event_start..event_end].to_vec())
                };
                self.event_start = self.scan_cursor + 2;
                self.scan_cursor = self.event_start;
                self.compact_scratch();
                if event.is_some() {
                    return Ok(event);
                }
                continue;
            }
            self.scan_cursor += 1;
        }

        let pending_bytes = self.scratch.len().saturating_sub(self.event_start);
        if pending_bytes > MAX_SEALED_SSE_EVENT_BYTES {
            return Err(format!(
                "sealed SSE event exceeds {MAX_SEALED_SSE_EVENT_BYTES} bytes"
            ));
        }
        if !input_finished || pending_bytes == 0 {
            return Ok(None);
        }

        self.reserve_event(pending_bytes)?;
        let event = self.scratch[self.event_start..].to_vec();
        self.event_start = self.scratch.len();
        self.scan_cursor = self.event_start;
        self.compact_scratch();
        Ok(Some(event))
    }

    fn reserve_event(&mut self, event_bytes: usize) -> Result<(), String> {
        if event_bytes > MAX_SEALED_SSE_EVENT_BYTES {
            return Err(format!(
                "sealed SSE event exceeds {MAX_SEALED_SSE_EVENT_BYTES} bytes"
            ));
        }
        self.event_count = self
            .event_count
            .checked_add(1)
            .ok_or_else(|| "sealed SSE event count overflow".to_owned())?;
        if self.event_count > MAX_SEALED_SSE_EVENTS {
            return Err(format!(
                "sealed SSE stream exceeds {MAX_SEALED_SSE_EVENTS} events"
            ));
        }
        if event_bytes == 0 {
            return Ok(());
        }
        let sealed_bytes = sealed_event_wire_len(event_bytes)
            .ok_or_else(|| "sealed SSE output size overflow".to_owned())?;
        let total = self
            .sealed_output_bytes
            .checked_add(sealed_bytes)
            .ok_or_else(|| "sealed SSE output size overflow".to_owned())?;
        if total > RESPONSE_RESERVATION_BYTES {
            return Err(format!(
                "sealed SSE output exceeds {RESPONSE_RESERVATION_BYTES}-byte response reservation"
            ));
        }
        self.sealed_output_bytes = total;
        Ok(())
    }

    fn compact_scratch(&mut self) {
        if self.event_start == 0 {
            return;
        }
        if self.event_start == self.scratch.len() {
            self.scratch.clear();
            self.event_start = 0;
            self.scan_cursor = 0;
            return;
        }
        if self.event_start < self.scratch.len() / 2 {
            return;
        }
        let consumed = self.event_start;
        self.scratch.copy_within(consumed.., 0);
        self.scratch.truncate(self.scratch.len() - consumed);
        self.event_start = 0;
        self.scan_cursor = self.scan_cursor.saturating_sub(consumed);
    }
}

fn sealed_event_wire_len(event_bytes: usize) -> Option<usize> {
    let ciphertext_bytes = event_bytes.checked_add(NACL_SEAL_OVERHEAD_BYTES)?;
    let base64_bytes = ciphertext_bytes
        .checked_add(2)?
        .checked_div(3)?
        .checked_mul(4)?;
    base64_bytes.checked_add(SSE_WRAPPER_BYTES)
}

async fn seal_event_async(
    pilot: PilotHandle,
    sender: X25519PublicKey,
    event: Vec<u8>,
    expected_bytes: usize,
) -> Result<Vec<u8>, String> {
    tokio::task::spawn_blocking(move || {
        let ciphertext = pilot
            .seal_to_sender(sender, &event)
            .map_err(|error| error.to_string())?;
        let actual_bytes = ciphertext
            .len()
            .checked_add(SSE_WRAPPER_BYTES)
            .ok_or_else(|| "sealed SSE output size overflow".to_owned())?;
        if actual_bytes != expected_bytes {
            return Err("sealed SSE output violated preflight size accounting".to_owned());
        }
        let mut output = Vec::with_capacity(actual_bytes);
        output.extend_from_slice(b"data: ");
        output.extend_from_slice(ciphertext.as_bytes());
        output.extend_from_slice(b"\n\n");
        Ok(output)
    })
    .await
    .map_err(|error| format!("sealed SSE task failed: {error}"))?
}

fn nonstream_body(
    mut body: BytePipeReceiver<Vec<u8>>,
    pilot: PilotHandle,
    sender: Option<X25519PublicKey>,
) -> Body {
    Body::from_stream(stream::once(async move {
        let mut exact = Vec::new();
        loop {
            match body.recv().await {
                Ok(Some(bytes)) => exact.extend_from_slice(&bytes),
                Ok(None) => break,
                Err(error) => return Err(io::Error::other(error.to_string())),
            }
        }
        let json = parse_chat_completion_sse(&exact).map_err(io::Error::other)?;
        if let Some(sender) = sender {
            let ciphertext = pilot
                .seal_to_sender(sender, &json)
                .map_err(|error| io::Error::other(error.to_string()))?;
            serde_json::to_vec(&SealedResponse {
                kid: pilot.keyring().active().kid(),
                ciphertext: &ciphertext,
            })
            .map(Bytes::from)
            .map_err(|error| io::Error::other(error.to_string()))
        } else {
            Ok(Bytes::from(json))
        }
    }))
}

fn sealed_headers(headers: &mut HeaderMap, pilot: &PilotHandle) {
    headers.insert(X_EIGEN_SEALED, HeaderValue::from_static("true"));
    if let Ok(kid) = HeaderValue::from_str(pilot.keyring().active().kid()) {
        headers.insert(X_EIGEN_SEALED_KID, kid);
    }
}

#[derive(Serialize)]
struct SealedResponse<'a> {
    kid: &'a str,
    ciphertext: &'a str,
}

#[derive(Default)]
struct ChoiceAccumulator {
    role: Option<String>,
    content: String,
    reasoning_content: String,
    reasoning: String,
    refusal: String,
    tool_calls: BTreeMap<u64, Value>,
    finish_reason: Option<Value>,
    logprobs: Option<Value>,
}

pub(crate) fn parse_chat_completion_sse(exact: &[u8]) -> Result<Vec<u8>, String> {
    let payloads = sse_payloads(exact)?;
    if payloads.len() == 1
        && payloads[0]
            .get("object")
            .and_then(Value::as_str)
            .is_some_and(|object| object == "chat.completion")
    {
        return serde_json::to_vec(&payloads[0]).map_err(|error| error.to_string());
    }
    if payloads.is_empty() {
        return Err("provider returned no chat completion payload".to_owned());
    }

    let mut metadata = Map::new();
    let mut choices: BTreeMap<u64, ChoiceAccumulator> = BTreeMap::new();
    let mut usage = None;
    for payload in payloads {
        for field in [
            "id",
            "created",
            "model",
            "system_fingerprint",
            "service_tier",
        ] {
            if let Some(value) = payload.get(field)
                && !value.is_null()
            {
                metadata
                    .entry(field.to_owned())
                    .or_insert_with(|| value.clone());
            }
        }
        if let Some(value) = payload.get("usage")
            && !value.is_null()
        {
            usage = Some(value.clone());
        }
        let Some(chunk_choices) = payload.get("choices").and_then(Value::as_array) else {
            continue;
        };
        for chunk in chunk_choices {
            let index = chunk.get("index").and_then(Value::as_u64).unwrap_or(0);
            let choice = choices.entry(index).or_default();
            if let Some(reason) = chunk.get("finish_reason")
                && !reason.is_null()
            {
                choice.finish_reason = Some(reason.clone());
            }
            if let Some(logprobs) = chunk.get("logprobs")
                && !logprobs.is_null()
            {
                choice.logprobs = Some(logprobs.clone());
            }
            let Some(delta) = chunk.get("delta").and_then(Value::as_object) else {
                continue;
            };
            if let Some(role) = delta.get("role").and_then(Value::as_str) {
                choice.role = Some(role.to_owned());
            }
            append_string(delta, "content", &mut choice.content);
            append_string(delta, "reasoning_content", &mut choice.reasoning_content);
            append_string(delta, "reasoning", &mut choice.reasoning);
            append_string(delta, "refusal", &mut choice.refusal);
            if let Some(tool_calls) = delta.get("tool_calls").and_then(Value::as_array) {
                merge_tool_calls(&mut choice.tool_calls, tool_calls);
            }
        }
    }
    if choices.is_empty() {
        return Err("provider returned no completion choices".to_owned());
    }

    metadata.insert(
        "object".to_owned(),
        Value::String("chat.completion".to_owned()),
    );
    metadata.insert(
        "choices".to_owned(),
        Value::Array(
            choices
                .into_iter()
                .map(|(index, choice)| completed_choice(index, choice))
                .collect(),
        ),
    );
    if let Some(usage) = usage {
        metadata.insert("usage".to_owned(), usage);
    }
    serde_json::to_vec(&Value::Object(metadata)).map_err(|error| error.to_string())
}

fn sse_payloads(exact: &[u8]) -> Result<Vec<Value>, String> {
    let text = std::str::from_utf8(exact)
        .map_err(|_| "provider response is not valid UTF-8".to_owned())?;
    let mut values = Vec::new();
    let mut structure_budget = crate::pilot::JsonStructureBudget::default();
    for event in text.split("\n\n") {
        let mut payload = String::new();
        let mut found_data = false;
        for line in event.lines() {
            if let Some(data) = line.strip_prefix("data:") {
                if found_data {
                    payload.push('\n');
                }
                payload.push_str(data.strip_prefix(' ').unwrap_or(data));
                found_data = true;
            }
        }
        let payload = if found_data {
            payload.trim()
        } else {
            event.trim()
        };
        if payload.is_empty() || payload == "[DONE]" {
            continue;
        }
        structure_budget
            .validate_next(payload.as_bytes())
            .map_err(|error| format!("provider returned unbounded SSE JSON: {error}"))?;
        values.push(
            serde_json::from_str(payload)
                .map_err(|error| format!("provider returned malformed SSE JSON: {error}"))?,
        );
    }
    Ok(values)
}

fn append_string(delta: &Map<String, Value>, field: &str, destination: &mut String) {
    if let Some(fragment) = delta.get(field).and_then(Value::as_str) {
        destination.push_str(fragment);
    }
}

fn merge_tool_calls(destination: &mut BTreeMap<u64, Value>, fragments: &[Value]) {
    for fragment in fragments {
        let index = fragment.get("index").and_then(Value::as_u64).unwrap_or(0);
        let target = destination.entry(index).or_insert_with(|| {
            json!({
                "id": "",
                "type": "function",
                "function": {"name": "", "arguments": ""}
            })
        });
        let Some(target) = target.as_object_mut() else {
            continue;
        };
        for field in ["id", "type"] {
            if let Some(value) = fragment.get(field).and_then(Value::as_str)
                && !value.is_empty()
            {
                target.insert(field.to_owned(), Value::String(value.to_owned()));
            }
        }
        let Some(function) = fragment.get("function").and_then(Value::as_object) else {
            continue;
        };
        let target_function = target
            .entry("function")
            .or_insert_with(|| json!({"name": "", "arguments": ""}))
            .as_object_mut();
        let Some(target_function) = target_function else {
            continue;
        };
        for field in ["name", "arguments"] {
            if let Some(fragment) = function.get(field).and_then(Value::as_str) {
                let current = target_function
                    .entry(field.to_owned())
                    .or_insert_with(|| Value::String(String::new()));
                if let Some(existing) = current.as_str() {
                    let combined = format!("{existing}{fragment}");
                    *current = Value::String(combined);
                }
            }
        }
    }
}

fn completed_choice(index: u64, choice: ChoiceAccumulator) -> Value {
    let mut message = Map::new();
    message.insert(
        "role".to_owned(),
        Value::String(choice.role.unwrap_or_else(|| "assistant".to_owned())),
    );
    message.insert("content".to_owned(), Value::String(choice.content));
    if !choice.reasoning_content.is_empty() {
        message.insert(
            "reasoning_content".to_owned(),
            Value::String(choice.reasoning_content),
        );
    }
    if !choice.reasoning.is_empty() {
        message.insert("reasoning".to_owned(), Value::String(choice.reasoning));
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
        "message": Value::Object(message),
        "finish_reason": choice.finish_reason.unwrap_or(Value::Null),
        "logprobs": choice.logprobs.unwrap_or(Value::Null)
    })
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_SEALED_SSE_EVENT_BYTES, MAX_SEALED_SSE_EVENTS, SseEventBuffer,
        parse_chat_completion_sse,
    };

    #[test]
    fn nonstreaming_assembles_ordered_sse_deltas() {
        let exact = concat!(
            "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":1,",
            "\"model\":\"m\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},",
            "\"finish_reason\":null}]}\n\n",
            "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"choices\":[",
            "{\"index\":0,\"delta\":{\"content\":\"hello\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n"
        );
        let output = parse_chat_completion_sse(exact.as_bytes()).expect("valid SSE");
        let value: serde_json::Value = serde_json::from_slice(&output).expect("JSON");
        assert_eq!(value["object"], "chat.completion");
        assert_eq!(value["choices"][0]["message"]["content"], "hello");
        assert_eq!(value["choices"][0]["finish_reason"], "stop");
    }

    #[test]
    fn nonstreaming_enforces_one_structural_budget_across_events() {
        let tiny_array = format!(
            "[{}]",
            std::iter::repeat_n("{}", 4_096)
                .collect::<Vec<_>>()
                .join(",")
        );
        let exact = std::iter::repeat_n(format!("data: {tiny_array}\n\n"), 4).collect::<String>();
        assert!(parse_chat_completion_sse(exact.as_bytes()).is_err());
    }

    #[test]
    fn sealed_sse_cursor_reassembles_fragmented_events_exactly() {
        let mut events = SseEventBuffer::default();
        events.push(b"data: {\"choices\":[");
        assert!(events.next_event(false).expect("fragment").is_none());
        events.push(b"]}\n");
        assert!(
            events
                .next_event(false)
                .expect("delimiter fragment")
                .is_none()
        );
        events.push(b"\ndata: [DO");
        assert_eq!(
            events.next_event(false).expect("first event"),
            Some(br#"data: {"choices":[]}"#.to_vec())
        );
        assert!(events.next_event(false).expect("second fragment").is_none());
        events.push(b"NE]\n\n");
        assert_eq!(
            events.next_event(false).expect("DONE event"),
            Some(b"data: [DONE]".to_vec())
        );
        assert!(events.next_event(true).expect("finished").is_none());
    }

    #[test]
    fn sealed_sse_separator_flood_is_bounded_before_encryption() {
        let mut events = SseEventBuffer::default();
        events.push(&vec![b'\n'; 4 * 1024 * 1024]);
        let error = events
            .next_event(false)
            .expect_err("separator flood must exceed event count");
        assert!(error.contains("events"));
        assert_eq!(events.event_count, MAX_SEALED_SSE_EVENTS + 1);
        assert_eq!(events.sealed_output_bytes, 0);
    }

    #[test]
    fn sealed_sse_rejects_event_and_total_wire_bounds_before_sealing() {
        let mut oversized = SseEventBuffer::default();
        oversized.push(&vec![b'x'; MAX_SEALED_SSE_EVENT_BYTES + 1]);
        assert!(
            oversized
                .next_event(false)
                .expect_err("oversized event")
                .contains("event exceeds")
        );

        let mut total = SseEventBuffer::default();
        let event = vec![b'x'; MAX_SEALED_SSE_EVENT_BYTES];
        loop {
            total.push(&event);
            total.push(b"\n\n");
            match total.next_event(false) {
                Ok(Some(_)) => {}
                Err(error) => {
                    assert!(error.contains("response reservation"));
                    break;
                }
                Ok(None) => panic!("complete event was not returned"),
            }
        }
    }
}
