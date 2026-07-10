//! `POST /v1/chat/completions` (plan §7.1, §23.2).
//!
//! The body is parsed ONCE into [`ChatCompletionRequest`] (unknown fields
//! preserved through a flattened map for forward compatibility, plan §15.4),
//! normalized (alias resolution, output bound injection, trait detection),
//! and handed to one supervised request task. The response commits only on
//! first content: pre-content failures map to typed HTTP errors and any
//! provider retries stay invisible (plan §7.8).

use std::collections::VecDeque;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use tokio::sync::mpsc;
use uuid::Uuid;

use darkbloom_core::ids::JobId;

use crate::http::auth::authenticate;
use crate::http::errors::{error_for_report, ApiError};
use crate::http::sealed::{self, SealedReply};
use crate::http::sse;
use crate::http::HttpState;
use crate::request_task::{self, ConsumerEvent, NormalizedRequest, UsageOut};

/// Ceiling injected when the consumer sets no output bound, so the
/// reservation covers the whole generation (Go `defaultMaxOutputTokens`).
const DEFAULT_MAX_OUTPUT_TOKENS: u64 = 8192;

/// Consumer-event channel capacity: drains continuously into the socket;
/// the per-attempt byte pipe upstream is the real 13.6 grace window.
const CONSUMER_CHANNEL_CAP: usize = 256;

/// The chat completions request, parsed exactly once. Unknown fields ride
/// in `extra` and are re-serialized verbatim toward the provider.
#[derive(Debug, Serialize, Deserialize)]
pub struct ChatCompletionRequest {
    #[serde(default)]
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub messages: Option<Vec<Value>>,
    #[serde(default)]
    pub stream: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_completion_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tools: Option<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl ChatCompletionRequest {
    /// Explicit consumer bound from any recognized field (Go
    /// `explicitMaxTokens`).
    fn explicit_max_tokens(&self) -> Option<u64> {
        [
            self.max_tokens,
            self.max_completion_tokens,
            self.max_output_tokens,
        ]
        .into_iter()
        .flatten()
        .find(|v| *v > 0)
    }

    /// Routing estimate: message content bytes / 4 (Go
    /// `estimatePromptTokens` heuristic).
    fn estimated_prompt_tokens(&self) -> u64 {
        let mut bytes: u64 = 0;
        for message in self.messages.iter().flatten() {
            match message.get("content") {
                Some(Value::String(s)) => bytes += s.len() as u64,
                Some(Value::Array(parts)) => {
                    for part in parts {
                        if let Some(Value::String(s)) = part.get("text") {
                            bytes += s.len() as u64;
                        }
                    }
                }
                _ => {}
            }
        }
        (bytes / 4).max(1)
    }

    fn needs_vision(&self) -> bool {
        self.messages.iter().flatten().any(|message| {
            matches!(message.get("content"), Some(Value::Array(parts))
                if parts.iter().any(|p| p.get("type").and_then(Value::as_str) == Some("image_url")))
        })
    }

    fn needs_tools(&self) -> bool {
        matches!(&self.tools, Some(Value::Array(t)) if !t.is_empty())
    }
}

/// One normalization pass: alias resolution, bound injection, provider
/// body serialization (serialized exactly once, plan §15.4).
struct Prepared {
    normalized: NormalizedRequest,
    stream: bool,
    public_model: String,
    job: JobId,
}

fn prepare_request(
    state: &HttpState,
    key: &crate::contracts::ApiKeyRecord,
    body: &[u8],
    consumer: mpsc::Sender<ConsumerEvent>,
) -> Result<Prepared, ApiError> {
    let mut request: ChatCompletionRequest = serde_json::from_slice(body)
        .map_err(|_| ApiError::InvalidRequest("invalid JSON body".to_owned()))?;
    if request.model.is_empty() {
        return Err(ApiError::InvalidRequest("model is required".to_owned()));
    }
    if request.messages.as_ref().is_none_or(Vec::is_empty) {
        return Err(ApiError::InvalidRequest(
            "messages or input is required".to_owned(),
        ));
    }

    let catalog = state.app.catalog.load();
    let public_model = request.model.clone();
    let concrete_model = if let Some(concrete) = catalog.aliases.get(&public_model) {
        concrete.clone()
    } else if catalog.prices.contains_key(&public_model) {
        public_model.clone()
    } else {
        return Err(ApiError::ModelNotFound(public_model));
    };

    let requested_max = request
        .explicit_max_tokens()
        .unwrap_or(DEFAULT_MAX_OUTPUT_TOKENS);
    // Bound injection (Go ensureMaxTokensBound): the provider must see the
    // same ceiling the reservation covers.
    request.max_tokens = Some(requested_max);
    let estimated_prompt_tokens = request.estimated_prompt_tokens();
    let needs_vision = request.needs_vision();
    let needs_tools = request.needs_tools();
    let stream = request.stream;

    // Rewrite to the concrete build and serialize the provider body once.
    request.model = concrete_model.clone();
    let provider_body = serde_json::to_vec(&request)
        .map_err(|_| ApiError::Internal("failed to serialize provider body"))?;

    let job = JobId::new(Uuid::new_v4());
    Ok(Prepared {
        normalized: NormalizedRequest {
            job,
            account: key.account,
            api_key: key.key_id.clone(),
            spend_cap: key.spend_cap,
            public_model: public_model.clone(),
            concrete_model,
            body: Bytes::from(provider_body),
            stream,
            estimated_prompt_tokens,
            requested_max_tokens: requested_max,
            needs_vision,
            needs_tools,
            paid: true,
            consumer,
        },
        stream,
        public_model,
        job,
    })
}

pub async fn chat_completions(
    State(state): State<HttpState>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    match handle(state, headers, body).await {
        Ok(response) => response,
        Err(err) => err.into_response(),
    }
}

async fn handle(state: HttpState, headers: HeaderMap, body: Bytes) -> Result<Response, ApiError> {
    let key = authenticate(&*state.app.keys, &headers).await?;

    // Reject before allocating anything heavy (plan §14).
    let permits = state
        .limits
        .try_acquire(key.account)
        .ok_or(ApiError::Overloaded)?;

    // Sealed-transport unwrap (Go sender_encryption.go semantics).
    let (plain_body, seal_ctx): (Bytes, Option<Arc<SealedReply>>) = if sealed::is_sealed(&headers) {
        let (plaintext, reply) = sealed::open_request(&state.app.encryption, &body)?;
        (plaintext, Some(Arc::new(reply)))
    } else {
        (body, None)
    };

    let (consumer_tx, consumer_rx) = mpsc::channel::<ConsumerEvent>(CONSUMER_CHANNEL_CAP);
    let prepared = prepare_request(&state, &key, &plain_body, consumer_tx)?;
    let job = prepared.job;
    let public_model = prepared.public_model.clone();
    let stream = prepared.stream;

    let span = tracing::info_span!("request_task", job = %job, model = %public_model);
    let task = {
        let deps = state.task_deps.clone();
        let normalized = prepared.normalized;
        // Spawned on the supervisor's requests-phase tracker (plan §15.1
        // step 2): ordered shutdown cancels via `deps.shutdown` (already in
        // the task's select) and then WAITS for these tasks to reach their
        // durable disposition before workers and sessions stop.
        state.request_tracker.spawn(tracing::Instrument::instrument(
            request_task::run(deps, normalized),
            span,
        ))
    };

    if stream {
        streaming_response(
            state.clone(),
            task,
            consumer_rx,
            job,
            public_model.clone(),
            seal_ctx.clone(),
            permits,
        )
        .await
    } else {
        // Permits drop when aggregation completes (request ends here).
        let response = non_streaming_response(
            state.clone(),
            task,
            consumer_rx,
            job,
            public_model.clone(),
            seal_ctx.clone(),
        )
        .await;
        drop(permits);
        response
    }
}

// ---------------------------------------------------------------------
// Streaming (SSE)
// ---------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
async fn streaming_response(
    state: HttpState,
    task: tokio::task::JoinHandle<request_task::TaskReport>,
    mut rx: mpsc::Receiver<ConsumerEvent>,
    job: JobId,
    public_model: String,
    seal_ctx: Option<Arc<SealedReply>>,
    permits: crate::http::limits::RequestPermits,
) -> Result<Response, ApiError> {
    // Nothing is written before first content: pre-content failover stays
    // invisible and failures map to plain HTTP errors (plan §7.8).
    let first = rx.recv().await;
    let Some(first) = first else {
        let report = task
            .await
            .map_err(|_| ApiError::Internal("request task panicked"))?;
        return Err(error_for_report(&report, &public_model));
    };

    let mut initial = VecDeque::new();
    let mut open = true;
    emit_event(
        &state,
        &seal_ctx,
        &public_model,
        job,
        first,
        &mut initial,
        &mut open,
    );

    struct StreamState {
        rx: mpsc::Receiver<ConsumerEvent>,
        queued: VecDeque<Bytes>,
        open: bool,
        state: HttpState,
        seal_ctx: Option<Arc<SealedReply>>,
        public_model: String,
        job: JobId,
        /// Concurrency permits held for the whole stream (plan §14).
        _permits: crate::http::limits::RequestPermits,
    }
    let stream_state = StreamState {
        rx,
        queued: initial,
        open,
        state,
        seal_ctx,
        public_model,
        job,
        _permits: permits,
    };
    let body_stream = futures::stream::unfold(stream_state, |mut s| async move {
        loop {
            if let Some(frame) = s.queued.pop_front() {
                return Some((Ok::<Bytes, std::convert::Infallible>(frame), s));
            }
            if !s.open {
                return None;
            }
            match s.rx.recv().await {
                Some(event) => {
                    let (mut queued, mut open) = (VecDeque::new(), s.open);
                    emit_event(
                        &s.state,
                        &s.seal_ctx,
                        &s.public_model,
                        s.job,
                        event,
                        &mut queued,
                        &mut open,
                    );
                    s.queued = queued;
                    s.open = open;
                }
                None => return None,
            }
        }
    });

    let mut response = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .header(header::CONNECTION, "keep-alive")
        .body(Body::from_stream(body_stream))
        .map_err(|_| ApiError::Internal("failed to build streaming response"))?;
    if let Ok(value) = HeaderValue::from_str(&job.to_string()) {
        response.headers_mut().insert("x-inference-job-id", value);
    }
    Ok(response)
}

/// Turns one consumer event into SSE frames. Sets `open = false` on the
/// terminal events.
fn emit_event(
    state: &HttpState,
    seal_ctx: &Option<Arc<SealedReply>>,
    public_model: &str,
    job: JobId,
    event: ConsumerEvent,
    out: &mut VecDeque<Bytes>,
    open: &mut bool,
) {
    match event {
        ConsumerEvent::Chunk(payload) => {
            out.push_back(frame(state, seal_ctx, &payload));
        }
        ConsumerEvent::Completed(usage) => {
            let usage_chunk = final_usage_chunk(job, public_model, &usage);
            let bytes = serde_json::to_vec(&usage_chunk).unwrap_or_default();
            out.push_back(frame(state, seal_ctx, &bytes));
            out.push_back(done_frame(state, seal_ctx));
            *open = false;
        }
        ConsumerEvent::Failed {
            message,
            error_type,
        } => {
            let err = json!({"error": {"message": message, "type": error_type}});
            let bytes = serde_json::to_vec(&err).unwrap_or_default();
            out.push_back(frame(state, seal_ctx, &bytes));
            *open = false;
        }
    }
}

fn frame(state: &HttpState, seal_ctx: &Option<Arc<SealedReply>>, payload: &[u8]) -> Bytes {
    match seal_ctx {
        None => sse::event(payload),
        Some(reply) => {
            // Seal the full upstream event bytes including the `data: `
            // prefix (Go sealed-SSE semantics).
            let mut event = Vec::with_capacity(sse::DATA_PREFIX.len() + payload.len());
            event.extend_from_slice(sse::DATA_PREFIX);
            event.extend_from_slice(payload);
            match sealed::seal_sse_event(&state.app.encryption, reply, &event) {
                Some(line) => sse::raw(line),
                None => Bytes::new(),
            }
        }
    }
}

fn done_frame(state: &HttpState, seal_ctx: &Option<Arc<SealedReply>>) -> Bytes {
    match seal_ctx {
        None => Bytes::from_static(sse::DONE_EVENT),
        Some(reply) => {
            match sealed::seal_sse_event(&state.app.encryption, reply, b"data: [DONE]") {
                Some(line) => sse::raw(line),
                None => Bytes::new(),
            }
        }
    }
}

/// The coordinator's final usage chunk: authoritative counts from the
/// terminal, SE signature riding on a well-formed `chat.completion.chunk`
/// (Go parity).
fn final_usage_chunk(job: JobId, public_model: &str, usage: &UsageOut) -> Value {
    let mut chunk = json!({
        "id": format!("chatcmpl-{job}"),
        "object": "chat.completion.chunk",
        "created": chrono::Utc::now().timestamp(),
        "model": public_model,
        "choices": [],
        "usage": usage_value(usage),
    });
    if let Some(sig) = &usage.se_signature {
        chunk["se_signature"] = json!(sig);
        chunk["response_hash"] = json!(usage.response_hash.clone().unwrap_or_default());
    }
    chunk
}

fn usage_value(usage: &UsageOut) -> Value {
    let mut value = json!({
        "prompt_tokens": usage.prompt_tokens,
        "completion_tokens": usage.completion_tokens,
        "total_tokens": usage.prompt_tokens + usage.completion_tokens,
    });
    if usage.reasoning_tokens > 0 {
        value["completion_tokens_details"] = json!({
            "reasoning_tokens": usage.reasoning_tokens,
        });
    }
    value
}

// ---------------------------------------------------------------------
// Non-streaming aggregation (Go handleNonStreamingResponse semantics)
// ---------------------------------------------------------------------

async fn non_streaming_response(
    state: HttpState,
    task: tokio::task::JoinHandle<request_task::TaskReport>,
    mut rx: mpsc::Receiver<ConsumerEvent>,
    job: JobId,
    public_model: String,
    seal_ctx: Option<Arc<SealedReply>>,
) -> Result<Response, ApiError> {
    let mut content = String::new();
    let mut reasoning = String::new();
    let mut finish_reason: Option<String> = None;
    let mut saw_content = false;

    let outcome: Result<UsageOut, (String, String)> = loop {
        match rx.recv().await {
            Some(ConsumerEvent::Chunk(chunk)) => {
                saw_content = true;
                accumulate_delta(&chunk, &mut content, &mut reasoning, &mut finish_reason);
            }
            Some(ConsumerEvent::Completed(usage)) => break Ok(usage),
            Some(ConsumerEvent::Failed {
                message,
                error_type,
            }) => break Err((message, error_type)),
            None => {
                if !saw_content {
                    let report = task
                        .await
                        .map_err(|_| ApiError::Internal("request task panicked"))?;
                    return Err(error_for_report(&report, &public_model));
                }
                break Err((
                    "provider ended without completion".to_owned(),
                    "provider_error".to_owned(),
                ));
            }
        }
    };

    match outcome {
        Ok(usage) => {
            let mut message = json!({
                "role": "assistant",
                "content": content,
            });
            if !reasoning.is_empty() {
                message["reasoning"] = json!(reasoning);
            }
            let mut response = json!({
                "id": format!("chatcmpl-{job}"),
                "object": "chat.completion",
                "created": chrono::Utc::now().timestamp(),
                "model": public_model,
                "choices": [{
                    "index": 0,
                    "message": message,
                    "finish_reason": finish_reason.unwrap_or_else(|| "stop".to_owned()),
                }],
                "usage": usage_value(&usage),
            });
            if let Some(sig) = &usage.se_signature {
                response["se_signature"] = json!(sig);
                response["response_hash"] = json!(usage.response_hash.clone().unwrap_or_default());
            }
            json_response(&state, &seal_ctx, StatusCode::OK, &response)
        }
        Err((message, error_type)) => {
            let status = if error_type == "timeout" {
                StatusCode::GATEWAY_TIMEOUT
            } else {
                StatusCode::BAD_GATEWAY
            };
            let body =
                json!({"error": {"type": error_type, "message": message, "code": error_type}});
            json_response(&state, &seal_ctx, status, &body)
        }
    }
}

/// Extracts delta text from one streamed chunk into the aggregate.
fn accumulate_delta(
    chunk: &[u8],
    content: &mut String,
    reasoning: &mut String,
    finish_reason: &mut Option<String>,
) {
    let Ok(value) = serde_json::from_slice::<Value>(chunk) else {
        return;
    };
    let Some(choices) = value.get("choices").and_then(Value::as_array) else {
        return;
    };
    for choice in choices {
        if let Some(delta) = choice.get("delta") {
            if let Some(text) = delta.get("content").and_then(Value::as_str) {
                content.push_str(text);
            }
            for key in ["reasoning_content", "reasoning"] {
                if let Some(text) = delta.get(key).and_then(Value::as_str) {
                    reasoning.push_str(text);
                }
            }
        }
        if let Some(fr) = choice.get("finish_reason").and_then(Value::as_str) {
            *finish_reason = Some(fr.to_owned());
        }
    }
}

fn json_response(
    state: &HttpState,
    seal_ctx: &Option<Arc<SealedReply>>,
    status: StatusCode,
    body: &Value,
) -> Result<Response, ApiError> {
    let bytes = serde_json::to_vec(body).map_err(|_| ApiError::Internal("encode failed"))?;
    match seal_ctx {
        None => Response::builder()
            .status(status)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(bytes))
            .map_err(|_| ApiError::Internal("failed to build response")),
        Some(reply) => {
            // Sealed replies mirror the request envelope (Go
            // sealingResponseWriter buffered mode).
            let sealed_bytes = sealed::seal_response(&state.app.encryption, reply, &bytes)?;
            Response::builder()
                .status(status)
                .header(
                    header::CONTENT_TYPE,
                    darkbloom_protocol::crypto::sealed_sender::SEALED_CONTENT_TYPE,
                )
                .body(Body::from(sealed_bytes))
                .map_err(|_| ApiError::Internal("failed to build response"))
        }
    }
}
