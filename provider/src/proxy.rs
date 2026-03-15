//! Request proxy between the coordinator WebSocket and the local inference backend.
//!
//! When the coordinator sends an inference request over WebSocket, this module
//! forwards it to the local backend (vllm-mlx or mlx-lm) via HTTP, reads the
//! response (streaming or non-streaming), and sends the results back to the
//! coordinator as WebSocket messages.
//!
//! The provider receives plain JSON inference requests from the coordinator.
//! No decryption is needed on the provider side — the coordinator runs in a
//! GCP Confidential VM and handles the trust boundary. The provider's identity
//! and integrity are proven via Secure Enclave attestation and periodic
//! challenge-response verification.
//!
//! The provider's NaCl key pair (NodeKeyPair) is kept for future use but is
//! not used in the current request flow.

use anyhow::{Context, Result};
use std::sync::Arc;
use tokio::sync::mpsc;

use crate::crypto::NodeKeyPair;
use crate::protocol::{ProviderMessage, UsageInfo};

/// Handle an inference request by forwarding it to the local backend
/// and streaming responses back via the outbound channel.
///
/// This is the main entry point for processing inference requests from
/// the coordinator. It determines whether the request is streaming or
/// non-streaming and delegates accordingly.
///
/// The `node_keypair` parameter is retained for future coordinator-to-provider
/// encryption but is not used in the current plain JSON flow.
pub async fn handle_inference_request(
    request_id: String,
    body: serde_json::Value,
    backend_url: String,
    outbound_tx: mpsc::Sender<ProviderMessage>,
    _node_keypair: Option<Arc<NodeKeyPair>>,
) {
    let is_streaming = body.get("stream").and_then(|v| v.as_bool()).unwrap_or(false);

    let result = if is_streaming {
        handle_streaming_request(&request_id, &body, &backend_url, &outbound_tx).await
    } else {
        handle_non_streaming_request(&request_id, &body, &backend_url, &outbound_tx).await
    };

    if let Err(e) = result {
        tracing::error!("Inference request {request_id} failed: {e}");
        let _ = outbound_tx
            .send(ProviderMessage::InferenceError {
                request_id,
                error: e.to_string(),
                status_code: 500,
            })
            .await;
    }
}

/// Handle a non-streaming inference request.
///
/// Sends the full request body to the backend, waits for a complete JSON
/// response, extracts usage info, and sends an InferenceComplete message
/// back to the coordinator.
async fn handle_non_streaming_request(
    request_id: &str,
    body: &serde_json::Value,
    backend_url: &str,
    outbound_tx: &mpsc::Sender<ProviderMessage>,
) -> Result<()> {
    let url = format!("{backend_url}/v1/chat/completions");
    let client = reqwest::Client::new();

    let response = client
        .post(&url)
        .json(body)
        .send()
        .await
        .context("failed to send request to backend")?;

    let status = response.status();
    if !status.is_success() {
        let error_body = response.text().await.unwrap_or_default();
        outbound_tx
            .send(ProviderMessage::InferenceError {
                request_id: request_id.to_string(),
                error: error_body,
                status_code: status.as_u16(),
            })
            .await
            .ok();
        return Ok(());
    }

    let response_json: serde_json::Value = response
        .json()
        .await
        .context("failed to parse backend response as JSON")?;

    // Extract token usage info for billing
    let usage = extract_usage(&response_json);

    outbound_tx
        .send(ProviderMessage::InferenceComplete {
            request_id: request_id.to_string(),
            usage,
        })
        .await
        .ok();

    Ok(())
}

/// Handle a streaming inference request (SSE).
///
/// Sends the request to the backend and reads the Server-Sent Events stream.
/// Each SSE "data:" line is forwarded to the coordinator as an
/// InferenceResponseChunk message. When the "[DONE]" sentinel is received,
/// sends an InferenceComplete with accumulated usage info.
///
/// Token counting: If the backend includes a "usage" field in chunks, those
/// counts are used. Otherwise, tokens are estimated by counting chunks that
/// contain delta content (approximate, but sufficient for billing).
async fn handle_streaming_request(
    request_id: &str,
    body: &serde_json::Value,
    backend_url: &str,
    outbound_tx: &mpsc::Sender<ProviderMessage>,
) -> Result<()> {
    let url = format!("{backend_url}/v1/chat/completions");
    let client = reqwest::Client::new();

    let response = client
        .post(&url)
        .json(body)
        .send()
        .await
        .context("failed to send streaming request to backend")?;

    let status = response.status();
    if !status.is_success() {
        let error_body = response.text().await.unwrap_or_default();
        outbound_tx
            .send(ProviderMessage::InferenceError {
                request_id: request_id.to_string(),
                error: error_body,
                status_code: status.as_u16(),
            })
            .await
            .ok();
        return Ok(());
    }

    // Read the SSE stream chunk by chunk
    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    let mut total_completion_tokens: u64 = 0;
    let mut prompt_tokens: u64 = 0;

    use futures_util::StreamExt;

    while let Some(chunk) = stream.next().await {
        let bytes = chunk.context("error reading SSE chunk")?;
        let text = String::from_utf8_lossy(&bytes);
        buffer.push_str(&text);

        // Process complete SSE lines from the buffer
        while let Some(line_end) = buffer.find('\n') {
            let line = buffer[..line_end].trim_end_matches('\r').to_string();
            buffer = buffer[line_end + 1..].to_string();

            if line.is_empty() {
                continue;
            }

            if line.starts_with("data: ") {
                let data = &line[6..];

                if data == "[DONE]" {
                    // Stream complete — send final usage info
                    outbound_tx
                        .send(ProviderMessage::InferenceComplete {
                            request_id: request_id.to_string(),
                            usage: UsageInfo {
                                prompt_tokens,
                                completion_tokens: total_completion_tokens,
                            },
                        })
                        .await
                        .ok();
                    return Ok(());
                }

                // Try to extract usage from chunk (some backends include it)
                if let Ok(chunk_json) = serde_json::from_str::<serde_json::Value>(data) {
                    if let Some(usage) = chunk_json.get("usage") {
                        if let Some(pt) = usage.get("prompt_tokens").and_then(|v| v.as_u64()) {
                            prompt_tokens = pt;
                        }
                        if let Some(ct) =
                            usage.get("completion_tokens").and_then(|v| v.as_u64())
                        {
                            total_completion_tokens = ct;
                        }
                    }

                    // Approximate token count from delta content chunks
                    if let Some(choices) = chunk_json.get("choices").and_then(|v| v.as_array()) {
                        for choice in choices {
                            if choice
                                .get("delta")
                                .and_then(|d| d.get("content"))
                                .and_then(|c| c.as_str())
                                .is_some()
                            {
                                total_completion_tokens += 1;
                            }
                        }
                    }
                }

                // Forward the SSE line to coordinator
                outbound_tx
                    .send(ProviderMessage::InferenceResponseChunk {
                        request_id: request_id.to_string(),
                        data: line.clone(),
                    })
                    .await
                    .ok();
            }
        }
    }

    // If we get here without [DONE], send completion with what we have
    outbound_tx
        .send(ProviderMessage::InferenceComplete {
            request_id: request_id.to_string(),
            usage: UsageInfo {
                prompt_tokens,
                completion_tokens: total_completion_tokens,
            },
        })
        .await
        .ok();

    Ok(())
}

/// Extract usage info from a non-streaming response JSON body.
///
/// Looks for the standard OpenAI "usage" object with prompt_tokens and
/// completion_tokens fields. Returns zeros if the fields are missing.
fn extract_usage(response: &serde_json::Value) -> UsageInfo {
    let usage = response.get("usage");

    let prompt_tokens = usage
        .and_then(|u| u.get("prompt_tokens"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    let completion_tokens = usage
        .and_then(|u| u.get("completion_tokens"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    UsageInfo {
        prompt_tokens,
        completion_tokens,
    }
}

/// Parse SSE lines from raw text. Returns (complete_lines, remaining_buffer).
///
/// This is a utility for testing and debugging SSE parsing. Lines are split
/// on newline boundaries; incomplete lines remain in the buffer for the next
/// call.
#[allow(dead_code)]
pub fn parse_sse_lines(buffer: &str) -> (Vec<String>, String) {
    let mut lines = Vec::new();
    let mut remaining = buffer.to_string();

    while let Some(line_end) = remaining.find('\n') {
        let line = remaining[..line_end].trim_end_matches('\r').to_string();
        remaining = remaining[line_end + 1..].to_string();
        if !line.is_empty() {
            lines.push(line);
        }
    }

    (lines, remaining)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_usage() {
        let response = serde_json::json!({
            "choices": [{"message": {"content": "hello"}}],
            "usage": {
                "prompt_tokens": 50,
                "completion_tokens": 100,
                "total_tokens": 150
            }
        });

        let usage = extract_usage(&response);
        assert_eq!(usage.prompt_tokens, 50);
        assert_eq!(usage.completion_tokens, 100);
    }

    #[test]
    fn test_extract_usage_missing() {
        let response = serde_json::json!({"choices": []});
        let usage = extract_usage(&response);
        assert_eq!(usage.prompt_tokens, 0);
        assert_eq!(usage.completion_tokens, 0);
    }

    #[test]
    fn test_parse_sse_lines_complete() {
        let buffer = "data: {\"id\": \"1\"}\n\ndata: {\"id\": \"2\"}\n\ndata: [DONE]\n\n";
        let (lines, remaining) = parse_sse_lines(buffer);
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0], "data: {\"id\": \"1\"}");
        assert_eq!(lines[1], "data: {\"id\": \"2\"}");
        assert_eq!(lines[2], "data: [DONE]");
        assert!(remaining.is_empty());
    }

    #[test]
    fn test_parse_sse_lines_partial() {
        let buffer = "data: {\"id\": \"1\"}\ndata: partial";
        let (lines, remaining) = parse_sse_lines(buffer);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0], "data: {\"id\": \"1\"}");
        assert_eq!(remaining, "data: partial");
    }

    #[test]
    fn test_parse_sse_lines_empty() {
        let (lines, remaining) = parse_sse_lines("");
        assert!(lines.is_empty());
        assert!(remaining.is_empty());
    }

    #[test]
    fn test_parse_sse_lines_with_cr_lf() {
        let buffer = "data: test\r\ndata: test2\r\n";
        let (lines, remaining) = parse_sse_lines(buffer);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0], "data: test");
        assert_eq!(lines[1], "data: test2");
        assert!(remaining.is_empty());
    }

    #[tokio::test]
    async fn test_handle_non_streaming_mock() {
        use axum::{routing::post, Json, Router};

        // Start a mock backend server
        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                Json(serde_json::json!({
                    "choices": [{"message": {"content": "Hello!"}}],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
                }))
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let (tx, mut rx) = mpsc::channel(32);
        let body = serde_json::json!({
            "model": "test",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": false
        });

        handle_inference_request(
            "req-1".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
        )
        .await;

        let msg = rx.recv().await.unwrap();
        match msg {
            ProviderMessage::InferenceComplete { request_id, usage } => {
                assert_eq!(request_id, "req-1");
                assert_eq!(usage.prompt_tokens, 10);
                assert_eq!(usage.completion_tokens, 5);
            }
            other => panic!("Expected InferenceComplete, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn test_handle_error_response() {
        use axum::{http::StatusCode, routing::post, Router};

        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async { (StatusCode::INTERNAL_SERVER_ERROR, "model not loaded") }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let (tx, mut rx) = mpsc::channel(32);
        let body = serde_json::json!({"model": "test", "messages": [], "stream": false});

        handle_inference_request(
            "req-err".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
        )
        .await;

        let msg = rx.recv().await.unwrap();
        match msg {
            ProviderMessage::InferenceError {
                request_id,
                error,
                status_code,
            } => {
                assert_eq!(request_id, "req-err");
                assert_eq!(status_code, 500);
                assert!(error.contains("model not loaded"));
            }
            other => panic!("Expected InferenceError, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn test_handle_streaming_mock() {
        use axum::{
            body::Body,
            http::StatusCode,
            response::Response,
            routing::post,
            Router,
        };

        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                let sse_data = [
                    "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
                    "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n",
                    "data: [DONE]\n\n",
                ]
                .join("");

                Response::builder()
                    .status(StatusCode::OK)
                    .header("content-type", "text/event-stream")
                    .body(Body::from(sse_data))
                    .unwrap()
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let (tx, mut rx) = mpsc::channel(32);
        let body = serde_json::json!({
            "model": "test",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": true
        });

        handle_inference_request(
            "req-stream".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
        )
        .await;

        // Collect all messages
        let mut messages = Vec::new();
        while let Ok(Some(msg)) =
            tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv()).await
        {
            messages.push(msg);
        }

        // Should have chunks + final complete
        assert!(messages.len() >= 2, "Expected at least 2 messages, got {}", messages.len());

        // Last message should be InferenceComplete
        let last = messages.last().unwrap();
        assert!(
            matches!(last, ProviderMessage::InferenceComplete { .. }),
            "Expected InferenceComplete as last message, got {:?}",
            last
        );
    }
}
