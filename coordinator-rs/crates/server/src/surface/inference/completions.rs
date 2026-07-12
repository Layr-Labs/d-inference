use serde_json::{Value, json};

use super::{
    AdaptedStreamFailure, AdapterContext, AdapterError, CanonicalChatRequest, CanonicalChatStream,
    ChatCompletion, ChatSseEvent, InferenceSurface,
    canonical::{delta_object, delta_text, finish_reason, message_object, message_text},
    limits::{MAX_PROMPTS, enforce_count, parse_request_object},
};

/// Lowers one legacy `/v1/completions` request into dispatcher chat JSON.
pub fn parse_completions_request(bytes: &[u8]) -> Result<CanonicalChatRequest, AdapterError> {
    let mut object = parse_request_object(bytes)?;
    let prompt = object
        .remove("prompt")
        .ok_or_else(|| AdapterError::invalid("prompt is required", Some("prompt")))?;
    let prompt = match prompt {
        Value::String(prompt) => prompt,
        Value::Array(prompts) => {
            enforce_count("prompt", prompts.len(), MAX_PROMPTS)?;
            if prompts.len() != 1 {
                return Err(AdapterError::invalid(
                    "this endpoint accepts exactly one prompt per request",
                    Some("prompt"),
                ));
            }
            prompts
                .into_iter()
                .next()
                .and_then(|prompt| prompt.as_str().map(ToOwned::to_owned))
                .ok_or_else(|| {
                    AdapterError::invalid("prompt entries must be strings", Some("prompt"))
                })?
        }
        _ => {
            return Err(AdapterError::invalid(
                "prompt must be a string or an array of strings",
                Some("prompt"),
            ));
        }
    };
    if let Some(logprobs) = object.remove("logprobs") {
        let count = logprobs
            .as_u64()
            .filter(|count| *count <= 20)
            .ok_or_else(|| {
                AdapterError::invalid(
                    "logprobs must be an integer between 0 and 20",
                    Some("logprobs"),
                )
            })?;
        object.insert("logprobs".to_owned(), Value::Bool(true));
        object.insert("top_logprobs".to_owned(), Value::from(count));
    }
    object.remove("echo");
    object.remove("suffix");
    object.remove("best_of");
    object.remove("endpoint");
    object.insert(
        "messages".to_owned(),
        json!([{"role": "user", "content": prompt}]),
    );
    CanonicalChatRequest::from_object(object, InferenceSurface::Completions)
}

/// Converts a non-stream chat completion into OpenAI's legacy text-completion
/// object without changing usage or choice ordering.
pub fn adapt_completions_nonstream(
    chat_json: &[u8],
    context: &AdapterContext,
) -> Result<Vec<u8>, AdapterError> {
    let chat = ChatCompletion::parse(chat_json)?;
    let choices = chat
        .choices
        .iter()
        .map(|choice| {
            let message = message_object(choice);
            json!({
                "text": message.map_or_else(String::new, |message| message_text(message, "content")),
                "index": choice.get("index").and_then(Value::as_u64).unwrap_or(0),
                "logprobs": choice.get("logprobs").cloned().unwrap_or(Value::Null),
                "finish_reason": choice.get("finish_reason").cloned().unwrap_or(Value::Null),
            })
        })
        .collect::<Vec<_>>();
    let value = json!({
        "id": completion_id(if chat.id.is_empty() { &context.request_id } else { &chat.id }),
        "object": "text_completion",
        "created": if chat.created == 0 { context.created_at } else { chat.created },
        "model": if context.model.is_empty() { chat.model.as_str() } else { context.model.as_str() },
        "choices": choices,
        "usage": chat.object.get("usage").cloned().unwrap_or_else(|| usage_value(chat.usage)),
    });
    serde_json::to_vec(&value)
        .map_err(|_| AdapterError::invalid("completion response could not be encoded", None))
}

/// Stateful exact-SSE adapter for legacy completions.
#[derive(Debug)]
pub struct CompletionsStreamAdapter {
    context: AdapterContext,
    source: CanonicalChatStream,
    emitted_choice: bool,
    pending_usage: Vec<Vec<u8>>,
    source_id: String,
    source_created: i64,
    source_model: String,
}

impl CompletionsStreamAdapter {
    #[must_use]
    pub fn new(context: AdapterContext) -> Self {
        Self {
            context,
            source: CanonicalChatStream::default(),
            emitted_choice: false,
            pending_usage: Vec::new(),
            source_id: String::new(),
            source_created: 0,
            source_model: String::new(),
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Vec<u8>>, AdapterError> {
        let events = self.source.push(bytes)?;
        self.adapt_events(events)
    }

    fn adapt_events(&mut self, events: Vec<ChatSseEvent>) -> Result<Vec<Vec<u8>>, AdapterError> {
        let mut output = Vec::new();
        for event in events {
            match event {
                ChatSseEvent::Done => {
                    if !self.emitted_choice {
                        output.push(sse_data(json!({
                            "id": completion_id(source_id(&self.source_id, &self.context)),
                            "object": "text_completion",
                            "created": source_created(self.source_created, &self.context),
                            "model": source_model(&self.source_model, &self.context),
                            "choices": [{
                                "text": "",
                                "index": 0,
                                "logprobs": Value::Null,
                                "finish_reason": "stop",
                            }],
                        }))?);
                        self.emitted_choice = true;
                    }
                    output.append(&mut self.pending_usage);
                    output.push(b"data: [DONE]\n\n".to_vec());
                }
                ChatSseEvent::Chunk(chunk) => {
                    if self.source_id.is_empty() && !chunk.id.is_empty() {
                        self.source_id.clone_from(&chunk.id);
                    }
                    if self.source_created == 0 && chunk.created != 0 {
                        self.source_created = chunk.created;
                    }
                    if self.source_model.is_empty() && !chunk.model.is_empty() {
                        self.source_model.clone_from(&chunk.model);
                    }
                    if chunk.choices.is_empty() {
                        if let Some(usage) = chunk.usage {
                            let event = sse_data(json!({
                                "id": completion_id(source_id(&chunk.id, &self.context)),
                                "object": "text_completion",
                                "created": source_created(chunk.created, &self.context),
                                "model": source_model(&chunk.model, &self.context),
                                "choices": [],
                                "usage": usage,
                            }))?;
                            if self.emitted_choice {
                                output.push(event);
                            } else {
                                self.pending_usage.push(event);
                            }
                        }
                        continue;
                    }
                    let mut choices = Vec::new();
                    for choice in &chunk.choices {
                        let delta = delta_object(choice);
                        let text = delta.map_or("", |delta| delta_text(delta, "content"));
                        let reason = finish_reason(choice);
                        if text.is_empty() && reason.is_none() {
                            continue;
                        }
                        choices.push(json!({
                            "text": text,
                            "index": choice.get("index").and_then(Value::as_u64).unwrap_or(0),
                            "logprobs": choice.get("logprobs").cloned().unwrap_or(Value::Null),
                            "finish_reason": reason,
                        }));
                    }
                    if choices.is_empty() {
                        continue;
                    }
                    output.append(&mut self.pending_usage);
                    self.emitted_choice = true;
                    let mut event = json!({
                        "id": completion_id(source_id(&chunk.id, &self.context)),
                        "object": "text_completion",
                        "created": source_created(chunk.created, &self.context),
                        "model": source_model(&chunk.model, &self.context),
                        "choices": choices,
                    });
                    if let Some(usage) = chunk.usage
                        && let Some(event) = event.as_object_mut()
                    {
                        event.insert("usage".to_owned(), usage);
                    }
                    output.push(sse_data(event)?);
                }
            }
        }
        Ok(output)
    }

    pub fn finish_input(&mut self) -> Result<Vec<Vec<u8>>, AdapterError> {
        let events = self.source.finish_input()?;
        self.adapt_events(events)
    }

    #[must_use]
    pub const fn is_committed(&self) -> bool {
        self.source.is_committed()
    }

    /// Returns an HTTP-safe pre-commit error or an in-band OpenAI error plus
    /// `[DONE]` once output has committed.
    pub fn fail(&self, error: AdapterError) -> AdaptedStreamFailure {
        if !self.is_committed() {
            return AdaptedStreamFailure::PreCommit(error);
        }
        let body = serde_json::to_vec(&error.openai_json()).unwrap_or_else(|_| {
            br#"{"error":{"message":"stream failed","type":"server_error","param":null,"code":"server_error"}}"#
                .to_vec()
        });
        let mut event = b"data: ".to_vec();
        event.extend_from_slice(&body);
        event.extend_from_slice(b"\n\n");
        AdaptedStreamFailure::Committed(vec![event, b"data: [DONE]\n\n".to_vec()])
    }

    pub fn cancel(&self) -> AdaptedStreamFailure {
        self.fail(AdapterError::cancelled())
    }
}

fn source_id<'a>(id: &'a str, context: &'a AdapterContext) -> &'a str {
    if id.is_empty() {
        &context.request_id
    } else {
        id
    }
}

fn source_created(created: i64, context: &AdapterContext) -> i64 {
    if created == 0 {
        context.created_at
    } else {
        created
    }
}

fn source_model<'a>(model: &'a str, context: &'a AdapterContext) -> &'a str {
    if context.model.is_empty() {
        model
    } else {
        &context.model
    }
}

fn completion_id(id: &str) -> String {
    if let Some(suffix) = id.strip_prefix("chatcmpl-") {
        format!("cmpl-{suffix}")
    } else if id.starts_with("cmpl-") {
        id.to_owned()
    } else {
        format!("cmpl-{id}")
    }
}

fn usage_value(usage: super::ChatUsage) -> Value {
    json!({
        "prompt_tokens": usage.prompt_tokens,
        "completion_tokens": usage.completion_tokens,
        "total_tokens": usage.total_tokens,
    })
}

fn sse_data(value: Value) -> Result<Vec<u8>, AdapterError> {
    let mut output = b"data: ".to_vec();
    output.extend_from_slice(
        &serde_json::to_vec(&value)
            .map_err(|_| AdapterError::invalid("completion event could not be encoded", None))?,
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
    fn request_preserves_generation_knobs() {
        let request = parse_completions_request(
            br#"{"model":"model-a","prompt":"hello","stream":true,"temperature":0.2,"top_p":0.9,"max_tokens":9,"stop":["x"],"seed":4,"logprobs":3}"#,
        )
        .expect("request");
        let chat: Value = serde_json::from_slice(request.body()).expect("chat JSON");
        assert_eq!(chat["messages"][0]["content"], "hello");
        assert_eq!(chat["temperature"], 0.2);
        assert_eq!(chat["top_p"], 0.9);
        assert_eq!(chat["stop"][0], "x");
        assert_eq!(chat["seed"], 4);
        assert_eq!(chat["logprobs"], true);
        assert_eq!(chat["top_logprobs"], 3);
        assert!(request.stream());
    }

    #[test]
    fn nonstream_and_stream_are_legacy_completion_shapes() {
        let chat = br#"{"id":"chatcmpl-x","object":"chat.completion","created":2,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}"#;
        let output = adapt_completions_nonstream(chat, &context()).expect("adapt");
        let output: Value = serde_json::from_slice(&output).expect("JSON");
        assert_eq!(output["id"], "cmpl-x");
        assert_eq!(output["object"], "text_completion");
        assert_eq!(output["choices"][0]["text"], "hello");

        let mut stream = CompletionsStreamAdapter::new(context());
        assert!(
            stream
                .push(br#"data: {"id":"chatcmpl-x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

"#)
                .expect("role")
                .is_empty()
        );
        let output = stream
            .push(br#"data: {"id":"chatcmpl-x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":"stop"}]}

data: [DONE]

"#)
            .expect("content");
        assert_eq!(output.len(), 2);
        assert!(String::from_utf8_lossy(&output[0]).contains("\"text\":\"hello\""));
        assert_eq!(output[1], b"data: [DONE]\n\n");
    }

    #[test]
    fn empty_success_preserves_usage_in_stream_and_nonstream_shapes() {
        let empty = br#"data: {"id":"chatcmpl-empty","object":"chat.completion.chunk","created":2,"model":"model-a","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"id":"chatcmpl-empty","object":"chat.completion.chunk","created":2,"model":"model-a","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":0,"total_tokens":3}}

data: [DONE]

"#;
        let output = adapt_completions_nonstream(empty, &context()).expect("empty nonstream");
        let output: Value = serde_json::from_slice(&output).expect("empty nonstream JSON");
        assert_eq!(output["choices"][0]["text"], "");
        assert_eq!(output["usage"]["prompt_tokens"], 3);
        assert_eq!(output["usage"]["completion_tokens"], 0);

        let mut stream = CompletionsStreamAdapter::new(context());
        assert!(stream.push(empty).expect("held empty stream").is_empty());
        let output = stream.finish_input().expect("finish empty stream");
        let text = output
            .iter()
            .map(|event| String::from_utf8_lossy(event))
            .collect::<String>();
        assert!(text.contains("\"text\":\"\""));
        assert!(text.contains("\"prompt_tokens\":3"));
        assert!(text.contains("\"completion_tokens\":0"));
        assert!(text.ends_with("data: [DONE]\n\n"));
    }

    #[test]
    fn malformed_and_multi_prompt_requests_are_rejected() {
        assert!(parse_completions_request(br#"{"model":"m","prompt":"#).is_err());
        let request = json!({
            "model": "m",
            "prompt": vec!["x"; MAX_PROMPTS + 1],
        });
        let error = parse_completions_request(
            &serde_json::to_vec(&request).expect("oversized prompt list JSON"),
        )
        .expect_err("prompt count limit");
        assert!(error.message().contains("at most 256"));
    }
}
