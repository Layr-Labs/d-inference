//! The streaming (SSE) chat response path (plan §7.8, §16).
//!
//! # SSE flush guarantees (plan §16: per-chunk relay p99 < 2 ms)
//!
//! Streaming responses use `Body::from_stream` over frames that are each
//! ONE complete SSE event ([`sse::event`]): hyper writes and flushes every
//! body frame as soon as the stream yields it and never buffers across
//! `Pending` (no Content-Length is set, the transfer is chunked). Socket
//! coalescing is disabled at accept time (TCP_NODELAY — [`crate::serve`]).
//! `Cache-Control: no-cache, no-store` plus `X-Accel-Buffering: no` keep
//! intermediaries from buffering; Caddy streams flushed upstream bodies
//! immediately by default. There is deliberately NO response-timeout layer
//! on this route: stream lifetime is bounded by the request task's own
//! deadlines, not a blanket tower timeout.

use std::collections::VecDeque;
use std::sync::Arc;

use axum::body::Body;
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::Response;
use bytes::Bytes;
use serde_json::{json, Value};
use tokio::sync::mpsc;

use darkbloom_core::ids::JobId;

use crate::http::errors::{error_for_report, ApiError};
use crate::http::sealed::{self, SealedReply};
use crate::http::sse;
use crate::http::HttpState;
use crate::request_task::{self, ConsumerEvent, UsageOut};

#[allow(clippy::too_many_arguments)]
pub(super) async fn streaming_response(
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

    // Streaming anti-buffering posture (module docs): chunked transfer
    // (never a Content-Length), caches off, and the nginx/proxy buffering
    // opt-out. Caddy respects flushed streaming bodies by default; the
    // `Connection` header is HTTP/1.1-only and stripped by hyper on h2.
    let mut response = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache, no-store")
        .header(header::CONNECTION, "keep-alive")
        .header("x-accel-buffering", "no")
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

pub(super) fn usage_value(usage: &UsageOut) -> Value {
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
