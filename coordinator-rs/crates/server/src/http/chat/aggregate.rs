//! Non-streaming chat aggregation: buffers the whole stream and answers
//! with one JSON body (Go `handleNonStreamingResponse` semantics).

use std::sync::Arc;

use axum::body::Body;
use axum::http::{header, StatusCode};
use axum::response::Response;
use serde_json::{json, Value};
use tokio::sync::mpsc;

use darkbloom_core::ids::JobId;

use crate::http::errors::{error_for_report, ApiError};
use crate::http::sealed::{self, SealedReply};
use crate::http::HttpState;
use crate::request_task::{self, ConsumerEvent, UsageOut};

use super::stream::usage_value;

pub(super) async fn non_streaming_response(
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
