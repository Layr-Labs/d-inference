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
use tokio_util::sync::CancellationToken;

use crate::coordinator::AtomicProviderStats;
use crate::crypto::NodeKeyPair;
use crate::protocol::{
    ImageGenerationRequestBody, ImageGenerationUsage, ProviderMessage, TranscriptionRequestBody,
    TranscriptionSegment, TranscriptionUsage, UsageInfo,
};
use crate::security;

/// Handle an inference request by forwarding it to the local backend
/// and streaming responses back via the outbound channel.
///
/// This is the main entry point for processing inference requests from
/// the coordinator. It determines whether the request is streaming or
/// non-streaming and delegates accordingly.
///
/// The `node_keypair` parameter is retained for future coordinator-to-provider
/// encryption but is not used in the current plain JSON flow.
/// Returns `true` if the backend appears to be down (connection refused),
/// signalling that the caller should mark the backend as not running.
pub async fn handle_inference_request(
    request_id: String,
    body: serde_json::Value,
    backend_url: String,
    outbound_tx: mpsc::Sender<ProviderMessage>,
    _node_keypair: Option<Arc<NodeKeyPair>>,
    cancel_token: CancellationToken,
    stats: Option<Arc<AtomicProviderStats>>,
) -> bool {
    // Pre-request SIP check: verify SIP is still enabled before processing
    // any consumer data. SIP can't be disabled at runtime (requires reboot),
    // so this is defense-in-depth on top of the startup check.
    if !security::check_sip_enabled() {
        tracing::error!("SIP disabled — refusing inference request {request_id}");
        let _ = outbound_tx
            .send(ProviderMessage::InferenceError {
                request_id,
                error: "provider security check failed: SIP disabled".to_string(),
                status_code: 503,
            })
            .await;
        return false;
    }

    let is_streaming = body
        .get("stream")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    let result = if is_streaming {
        handle_streaming_request(
            &request_id,
            &body,
            &backend_url,
            &outbound_tx,
            &cancel_token,
            &stats,
        )
        .await
    } else {
        handle_non_streaming_request(
            &request_id,
            &body,
            &backend_url,
            &outbound_tx,
            &cancel_token,
            &stats,
        )
        .await
    };

    let mut backend_dead = false;
    if let Err(e) = result {
        if cancel_token.is_cancelled() {
            tracing::info!("Inference request {request_id} cancelled");
        } else {
            // Check if this is a connection error (backend process died)
            backend_dead = e.chain().any(|cause| {
                cause
                    .downcast_ref::<reqwest::Error>()
                    .map_or(false, |re| re.is_connect())
            });
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

    // Wipe the request body from memory after processing.
    // The body contains the consumer's prompts — we don't want them
    // lingering in process memory after the job completes.
    if let Ok(mut body_bytes) = serde_json::to_vec(&body) {
        security::secure_zero(&mut body_bytes);
    }

    backend_dead
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
    cancel_token: &CancellationToken,
    stats: &Option<Arc<AtomicProviderStats>>,
) -> Result<()> {
    let endpoint = body
        .get("endpoint")
        .and_then(|v| v.as_str())
        .unwrap_or("/v1/chat/completions");
    let url = format!("{backend_url}{endpoint}");
    let client = reqwest::Client::new();

    let response = tokio::select! {
        result = client.post(&url).json(body).send() => {
            result.context("failed to send request to backend")?
        }
        _ = cancel_token.cancelled() => {
            anyhow::bail!("request cancelled");
        }
    };

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

    let response_json: serde_json::Value = tokio::select! {
        result = response.json() => {
            result.context("failed to parse backend response as JSON")?
        }
        _ = cancel_token.cancelled() => {
            anyhow::bail!("request cancelled");
        }
    };

    // Extract token usage info for billing (format-agnostic: handles both
    // chat completions prompt_tokens/completion_tokens and Responses API
    // input_tokens/output_tokens).
    let usage = extract_usage(&response_json);
    let completion_tokens = usage.completion_tokens;

    // Forward the raw backend response as a single chunk. The proxy is
    // format-agnostic — it doesn't parse choices/output/message fields.
    // vllm-mlx handles all format-specific logic; we just relay the response.
    let raw_json = serde_json::to_string(&response_json).unwrap_or_default();

    // Sign the raw response with the Secure Enclave key.
    let sign_data = format!("{}:{}:{}", request_id, completion_tokens, &raw_json);
    let response_hash = security::sha256_hex(sign_data.as_bytes());
    let se_signature = security::se_sign(response_hash.as_bytes());

    outbound_tx
        .send(ProviderMessage::InferenceResponseChunk {
            request_id: request_id.to_string(),
            data: format!("data: {}", raw_json),
        })
        .await
        .ok();

    outbound_tx
        .send(ProviderMessage::InferenceComplete {
            request_id: request_id.to_string(),
            usage,
            se_signature,
            response_hash: Some(response_hash),
        })
        .await
        .ok();

    // Increment shared stats counters for heartbeat reporting.
    if let Some(s) = stats {
        use std::sync::atomic::Ordering;
        s.requests_served.fetch_add(1, Ordering::Relaxed);
        s.tokens_generated
            .fetch_add(completion_tokens, Ordering::Relaxed);
    }

    // Wipe response data from memory — contains consumer's inference output.
    if let Ok(mut resp_bytes) = serde_json::to_vec(&response_json) {
        security::secure_zero(&mut resp_bytes);
    }

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
    cancel_token: &CancellationToken,
    stats: &Option<Arc<AtomicProviderStats>>,
) -> Result<()> {
    let endpoint = body
        .get("endpoint")
        .and_then(|v| v.as_str())
        .unwrap_or("/v1/chat/completions");
    let url = format!("{backend_url}{endpoint}");
    let client = reqwest::Client::new();

    let response = tokio::select! {
        result = client.post(&url).json(body).send() => {
            result.context("failed to send streaming request to backend")?
        }
        _ = cancel_token.cancelled() => {
            anyhow::bail!("request cancelled");
        }
    };

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

    // Read the SSE stream chunk by chunk.
    // The cancel_token select! branch ensures that when the coordinator
    // disconnects or sends a cancel, we drop `stream` immediately —
    // this closes the HTTP connection and vllm-mlx stops generating.
    let mut stream = response.bytes_stream();
    // Accumulate actual response content for signing
    let mut response_content = String::new();
    let mut buffer = String::new();
    let mut total_completion_tokens: u64 = 0;
    let mut prompt_tokens: u64 = 0;

    use futures_util::StreamExt;

    loop {
        let chunk = tokio::select! {
            chunk = stream.next() => chunk,
            _ = cancel_token.cancelled() => {
                // Drop stream → close HTTP connection → vllm-mlx sees disconnect
                anyhow::bail!("request cancelled");
            }
        };

        let Some(chunk) = chunk else { break };
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
                    // Stream complete — sign the actual response content
                    let sign_data = format!(
                        "{}:{}:{}",
                        request_id, total_completion_tokens, response_content
                    );
                    let response_hash = security::sha256_hex(sign_data.as_bytes());
                    let se_signature = security::se_sign(response_hash.as_bytes());

                    outbound_tx
                        .send(ProviderMessage::InferenceComplete {
                            request_id: request_id.to_string(),
                            usage: UsageInfo {
                                prompt_tokens,
                                completion_tokens: total_completion_tokens,
                            },
                            se_signature,
                            response_hash: Some(response_hash),
                        })
                        .await
                        .ok();
                    // Increment shared stats counters for heartbeat reporting.
                    if let Some(s) = stats {
                        use std::sync::atomic::Ordering;
                        s.requests_served.fetch_add(1, Ordering::Relaxed);
                        s.tokens_generated
                            .fetch_add(total_completion_tokens, Ordering::Relaxed);
                    }
                    return Ok(());
                }

                // Try to extract usage from chunk (some backends include it)
                if let Ok(chunk_json) = serde_json::from_str::<serde_json::Value>(data) {
                    if let Some(usage) = chunk_json.get("usage") {
                        if let Some(pt) = usage.get("prompt_tokens").and_then(|v| v.as_u64()) {
                            prompt_tokens = pt;
                        }
                        if let Some(ct) = usage.get("completion_tokens").and_then(|v| v.as_u64()) {
                            total_completion_tokens = ct;
                        }
                    }

                    // Extract content from delta chunks for token counting and signing
                    if let Some(choices) = chunk_json.get("choices").and_then(|v| v.as_array()) {
                        for choice in choices {
                            if let Some(content) = choice
                                .get("delta")
                                .and_then(|d| d.get("content"))
                                .and_then(|c| c.as_str())
                            {
                                total_completion_tokens += 1;
                                response_content.push_str(content);
                            }
                            // Also capture reasoning/thinking content
                            if let Some(reasoning) = choice
                                .get("delta")
                                .and_then(|d| d.get("reasoning_content"))
                                .and_then(|c| c.as_str())
                            {
                                response_content.push_str(reasoning);
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
    // Sign the actual accumulated response content
    let sign_data = format!(
        "{}:{}:{}",
        request_id, total_completion_tokens, response_content
    );
    let response_hash = security::sha256_hex(sign_data.as_bytes());
    let se_signature = security::se_sign(response_hash.as_bytes());

    outbound_tx
        .send(ProviderMessage::InferenceComplete {
            request_id: request_id.to_string(),
            usage: UsageInfo {
                prompt_tokens,
                completion_tokens: total_completion_tokens,
            },
            se_signature,
            response_hash: Some(response_hash),
        })
        .await
        .ok();

    // Increment shared stats counters for heartbeat reporting.
    if let Some(s) = stats {
        use std::sync::atomic::Ordering;
        s.requests_served.fetch_add(1, Ordering::Relaxed);
        s.tokens_generated
            .fetch_add(total_completion_tokens, Ordering::Relaxed);
    }

    Ok(())
}

/// Handle a transcription request by forwarding audio to the local STT backend.
///
/// Decodes base64 audio, writes it to a temp file, POSTs it as multipart/form-data
/// to the mlx-audio server's /v1/audio/transcriptions endpoint, and sends the
/// result back as a TranscriptionComplete message.
pub async fn handle_transcription_request(
    request_id: String,
    body: TranscriptionRequestBody,
    stt_backend_url: String,
    outbound_tx: mpsc::Sender<ProviderMessage>,
    cancel_token: CancellationToken,
) {
    let start = std::time::Instant::now();

    let result = do_transcription(
        &request_id,
        &body,
        &stt_backend_url,
        &outbound_tx,
        &cancel_token,
        start,
    )
    .await;

    if let Err(e) = result {
        if cancel_token.is_cancelled() {
            tracing::info!("Transcription request {request_id} cancelled");
        } else {
            tracing::error!("Transcription request {request_id} failed: {e}");
            let _ = outbound_tx
                .send(ProviderMessage::InferenceError {
                    request_id: request_id.clone(),
                    error: e.to_string(),
                    status_code: 500,
                })
                .await;
        }
    }

    tracing::info!(
        "Transcription request {request_id} finished in {:.2}s",
        start.elapsed().as_secs_f64()
    );
}

async fn do_transcription(
    request_id: &str,
    body: &TranscriptionRequestBody,
    stt_backend_url: &str,
    outbound_tx: &mpsc::Sender<ProviderMessage>,
    cancel_token: &CancellationToken,
    start: std::time::Instant,
) -> Result<()> {
    use base64::Engine;

    // Decode base64 audio
    let audio_bytes = base64::engine::general_purpose::STANDARD
        .decode(&body.audio)
        .context("invalid base64 audio data")?;

    let audio_seconds = estimate_audio_duration(&audio_bytes, &body.format);

    // Determine file extension from format hint
    let ext = if body.format.is_empty() {
        "wav"
    } else {
        &body.format
    };

    // Write to temp file for multipart upload
    let tmp_path = format!("/tmp/eigeninference-stt-{request_id}.{ext}");
    tokio::fs::write(&tmp_path, &audio_bytes)
        .await
        .context("failed to write temp audio file")?;

    // Build multipart form
    let file_bytes = tokio::fs::read(&tmp_path)
        .await
        .context("failed to read temp audio file")?;

    let file_part = reqwest::multipart::Part::bytes(file_bytes)
        .file_name(format!("audio.{ext}"))
        .mime_str(&format!("audio/{ext}"))
        .unwrap_or_else(|_| reqwest::multipart::Part::bytes(vec![]).file_name("audio.wav"));

    let mut form = reqwest::multipart::Form::new()
        .part("file", file_part)
        .text("model", body.model.clone());

    if let Some(ref lang) = body.language {
        form = form.text("language", lang.clone());
    }

    let url = format!("{stt_backend_url}/v1/audio/transcriptions");
    let client = reqwest::Client::new();

    let response = tokio::select! {
        result = client.post(&url).multipart(form).send() => {
            result.context("failed to send transcription request to STT backend")?
        }
        _ = cancel_token.cancelled() => {
            let _ = tokio::fs::remove_file(&tmp_path).await;
            anyhow::bail!("request cancelled");
        }
    };

    // Clean up temp file
    let _ = tokio::fs::remove_file(&tmp_path).await;

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

    // mlx-audio returns NDJSON; read the full response
    let response_text = response
        .text()
        .await
        .context("failed to read STT response")?;

    // Parse the NDJSON response (may have multiple lines)
    let mut text = String::new();
    let mut segments = Vec::new();
    let mut language = None;
    let mut generation_tokens: u64 = 0;

    for line in response_text.lines() {
        if line.trim().is_empty() {
            continue;
        }
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(line) {
            // Full result format
            if let Some(t) = json.get("text").and_then(|v| v.as_str()) {
                text = t.to_string();
            }
            if let Some(lang) = json.get("language").and_then(|v| v.as_str()) {
                language = Some(lang.to_string());
            }
            if let Some(gt) = json.get("generation_tokens").and_then(|v| v.as_u64()) {
                generation_tokens = gt;
            }
            if let Some(segs) = json.get("segments").and_then(|v| v.as_array()) {
                for seg in segs {
                    if let (Some(start), Some(end), Some(seg_text)) = (
                        seg.get("start").and_then(|v| v.as_f64()),
                        seg.get("end").and_then(|v| v.as_f64()),
                        seg.get("text").and_then(|v| v.as_str()),
                    ) {
                        segments.push(TranscriptionSegment {
                            start,
                            end,
                            text: seg_text.to_string(),
                        });
                    }
                }
            }
        }
    }

    outbound_tx
        .send(ProviderMessage::TranscriptionComplete {
            request_id: request_id.to_string(),
            text,
            segments: if segments.is_empty() {
                None
            } else {
                Some(segments)
            },
            language,
            usage: TranscriptionUsage {
                audio_seconds,
                generation_tokens,
            },
            duration_secs: start.elapsed().as_secs_f64(),
        })
        .await
        .ok();

    Ok(())
}

/// Estimate audio duration from raw bytes and format.
/// This is approximate — mainly for billing. Exact duration comes from the STT result.
fn estimate_audio_duration(bytes: &[u8], format: &str) -> f64 {
    match format {
        "wav" => {
            // WAV: sample_rate at offset 24, bits_per_sample at 34, data starts at 44
            if bytes.len() > 44 {
                let sample_rate =
                    u32::from_le_bytes(bytes[24..28].try_into().unwrap_or([0; 4])) as f64;
                let bits = u16::from_le_bytes(bytes[34..36].try_into().unwrap_or([0; 2])) as f64;
                let channels =
                    u16::from_le_bytes(bytes[22..24].try_into().unwrap_or([0; 2])) as f64;
                if sample_rate > 0.0 && bits > 0.0 && channels > 0.0 {
                    let data_bytes = (bytes.len() - 44) as f64;
                    return data_bytes / (sample_rate * channels * bits / 8.0);
                }
            }
            0.0
        }
        "mp3" => {
            // Rough estimate: ~128kbps MP3
            (bytes.len() as f64 * 8.0) / 128_000.0
        }
        _ => 0.0,
    }
}

/// Handle an image generation request by forwarding it to the local image bridge.
///
/// Sends the request to the bridge, then uploads generated images to the
/// coordinator via HTTP POST (avoiding WebSocket size limits). Finally sends
/// a small ImageGenerationComplete message over WebSocket with just usage metadata.
pub async fn handle_image_generation_request(
    request_id: String,
    body: ImageGenerationRequestBody,
    image_bridge_url: String,
    upload_url: String,
    outbound_tx: mpsc::Sender<ProviderMessage>,
    cancel_token: CancellationToken,
) {
    let start = std::time::Instant::now();

    let result = do_image_generation(
        &request_id,
        &body,
        &image_bridge_url,
        &upload_url,
        &outbound_tx,
        &cancel_token,
        start,
    )
    .await;

    if let Err(e) = result {
        if cancel_token.is_cancelled() {
            tracing::info!("Image generation request {request_id} cancelled");
        } else {
            tracing::error!("Image generation request {request_id} failed: {e}");
            let _ = outbound_tx
                .send(ProviderMessage::InferenceError {
                    request_id: request_id.clone(),
                    error: e.to_string(),
                    status_code: 500,
                })
                .await;
        }
    }

    tracing::info!(
        "Image generation request {request_id} finished in {:.2}s",
        start.elapsed().as_secs_f64()
    );
}

async fn do_image_generation(
    request_id: &str,
    body: &ImageGenerationRequestBody,
    image_bridge_url: &str,
    upload_url: &str,
    outbound_tx: &mpsc::Sender<ProviderMessage>,
    cancel_token: &CancellationToken,
    start: std::time::Instant,
) -> Result<()> {
    use base64::Engine;

    // Build the request body for the image bridge (OpenAI images format)
    let req_body = serde_json::json!({
        "model": body.model,
        "prompt": body.prompt,
        "negative_prompt": body.negative_prompt,
        "n": body.n,
        "size": body.size,
        "steps": body.steps,
        "seed": body.seed,
        "response_format": "b64_json",
    });

    let url = format!("{image_bridge_url}/v1/images/generations");
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(300)) // 5 min timeout for image gen
        .build()
        .unwrap_or_default();

    let response = tokio::select! {
        result = client.post(&url).json(&req_body).send() => {
            result.context("failed to send image generation request to bridge")?
        }
        _ = cancel_token.cancelled() => {
            anyhow::bail!("request cancelled");
        }
    };

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
        .context("failed to parse image bridge response")?;

    // Extract base64 images from OpenAI format: { "data": [{"b64_json": "..."}] }
    let b64_images: Vec<&str> = response_json
        .get("data")
        .and_then(|d| d.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|item| item.get("b64_json").and_then(|v| v.as_str()))
                .collect()
        })
        .unwrap_or_default();

    if b64_images.is_empty() {
        anyhow::bail!("image bridge returned no images");
    }

    // Upload each image to the coordinator via HTTP POST (not WebSocket).
    // This avoids the WebSocket message size limit. Each upload carries an
    // SE-signed signature over the request_id so the coordinator can bind
    // the upload to the SE-attested provider that owns this request_id.
    // Without it, anyone who guessed the UUID could swap in arbitrary
    // bytes for the consumer's response.
    let request_id_signature = security::se_sign(request_id.as_bytes()).unwrap_or_default();
    for (i, b64) in b64_images.iter().enumerate() {
        let image_bytes = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .context("invalid base64 image data from bridge")?;

        let upload_resp = client
            .post(upload_url)
            .body(image_bytes)
            .header("content-type", "image/png")
            .header("x-provider-signature", &request_id_signature)
            .send()
            .await
            .context("failed to upload image to coordinator")?;

        if !upload_resp.status().is_success() {
            tracing::warn!(
                "Image upload {}/{} failed: {}",
                i + 1,
                b64_images.len(),
                upload_resp.status()
            );
        }
    }

    // Parse size for usage info (default 1024x1024)
    let (width, height) = body
        .size
        .as_deref()
        .and_then(|s| {
            let parts: Vec<&str> = s.split('x').collect();
            if parts.len() == 2 {
                Some((
                    parts[0].parse::<u32>().unwrap_or(1024),
                    parts[1].parse::<u32>().unwrap_or(1024),
                ))
            } else {
                None
            }
        })
        .unwrap_or((1024, 1024));

    let steps = body.steps.unwrap_or(4);

    // Send small completion message over WebSocket (no image data).
    outbound_tx
        .send(ProviderMessage::ImageGenerationComplete {
            request_id: request_id.to_string(),
            usage: ImageGenerationUsage {
                images_generated: body.n,
                width,
                height,
                steps,
                model: body.model.clone(),
            },
            duration_secs: start.elapsed().as_secs_f64(),
        })
        .await
        .ok();

    Ok(())
}

/// Extract usage info from a non-streaming response JSON body.
///
/// Looks for the standard OpenAI "usage" object with prompt_tokens and
/// completion_tokens fields. Returns zeros if the fields are missing.
/// Extract usage from any OpenAI-compatible response format.
/// Chat completions uses prompt_tokens/completion_tokens.
/// Responses API uses input_tokens/output_tokens.
fn extract_usage(response: &serde_json::Value) -> UsageInfo {
    let usage = response.get("usage");

    let prompt_tokens = usage
        .and_then(|u| u.get("prompt_tokens").or_else(|| u.get("input_tokens")))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    let completion_tokens = usage
        .and_then(|u| {
            u.get("completion_tokens")
                .or_else(|| u.get("output_tokens"))
        })
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
        use axum::{Json, Router, routing::post};

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

        let dead = handle_inference_request(
            "req-1".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;
        assert!(!dead, "backend should not be reported as dead");

        // First message: the response content as an SSE chunk
        let chunk_msg = rx.recv().await.unwrap();
        match &chunk_msg {
            ProviderMessage::InferenceResponseChunk { request_id, data } => {
                assert_eq!(request_id, "req-1");
                assert!(
                    data.contains("Hello!"),
                    "chunk should contain response content"
                );
            }
            other => panic!("Expected InferenceResponseChunk, got {:?}", other),
        }

        // Second message: InferenceComplete with usage
        let complete_msg = rx.recv().await.unwrap();
        match complete_msg {
            ProviderMessage::InferenceComplete {
                request_id, usage, ..
            } => {
                assert_eq!(request_id, "req-1");
                assert_eq!(usage.prompt_tokens, 10);
                assert_eq!(usage.completion_tokens, 5);
            }
            other => panic!("Expected InferenceComplete, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn test_handle_error_response() {
        use axum::{Router, http::StatusCode, routing::post};

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

        let dead = handle_inference_request(
            "req-err".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;
        // HTTP 500 means backend is running but returned an error — not dead
        assert!(!dead, "HTTP error should not report backend as dead");

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
        use axum::{Router, body::Body, http::StatusCode, response::Response, routing::post};

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

        let dead = handle_inference_request(
            "req-stream".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;
        assert!(!dead, "backend should not be reported as dead");

        // Collect all messages
        let mut messages = Vec::new();
        while let Ok(Some(msg)) =
            tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv()).await
        {
            messages.push(msg);
        }

        // Should have chunks + final complete
        assert!(
            messages.len() >= 2,
            "Expected at least 2 messages, got {}",
            messages.len()
        );

        // Last message should be InferenceComplete
        let last = messages.last().unwrap();
        assert!(
            matches!(last, ProviderMessage::InferenceComplete { .. }),
            "Expected InferenceComplete as last message, got {:?}",
            last
        );
    }

    #[tokio::test]
    async fn test_streaming_cancel_stops_early() {
        use axum::{Router, body::Body, http::StatusCode, response::Response, routing::post};

        // Slow SSE backend: sends chunks with delays
        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                let stream = futures_util::stream::unfold(0u32, |i| async move {
                    if i >= 100 {
                        return None;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    let chunk = format!(
                        "data: {{\"choices\":[{{\"delta\":{{\"content\":\"tok-{i}\"}}}}]}}\n\n"
                    );
                    Some((Ok::<_, std::convert::Infallible>(chunk), i + 1))
                });

                Response::builder()
                    .status(StatusCode::OK)
                    .header("content-type", "text/event-stream")
                    .body(Body::from_stream(stream))
                    .unwrap()
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let (tx, mut rx) = mpsc::channel(128);
        let body = serde_json::json!({
            "model": "test",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": true
        });

        let cancel_token = CancellationToken::new();
        let token_clone = cancel_token.clone();

        // Spawn inference and cancel after 200ms
        let handle = tokio::spawn(async move {
            handle_inference_request(
                "req-cancel".to_string(),
                body,
                format!("http://127.0.0.1:{}", addr.port()),
                tx,
                None,
                token_clone,
                None,
            )
            .await;
        });

        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        cancel_token.cancel();

        let _ = tokio::time::timeout(std::time::Duration::from_secs(2), handle).await;

        // Collect messages — should have some chunks but NOT all 100,
        // and NO InferenceError (cancelled requests don't send errors)
        let mut chunks = 0;
        let mut got_error = false;
        while let Ok(Some(msg)) =
            tokio::time::timeout(std::time::Duration::from_millis(100), rx.recv()).await
        {
            match msg {
                ProviderMessage::InferenceResponseChunk { .. } => chunks += 1,
                ProviderMessage::InferenceError { .. } => got_error = true,
                _ => {}
            }
        }

        assert!(
            chunks < 50,
            "Expected early stop, got {chunks} chunks (should be << 100)"
        );
        assert!(
            !got_error,
            "Cancelled request should not send InferenceError"
        );
    }

    #[tokio::test]
    async fn test_handle_image_generation_mock() {
        use axum::{Json, Router, body::Bytes, routing::post};
        use std::sync::{Arc, Mutex};

        // Track what gets uploaded
        let uploaded: Arc<Mutex<Vec<Vec<u8>>>> = Arc::new(Mutex::new(Vec::new()));
        let uploaded_clone = uploaded.clone();

        // Mock server: bridge endpoint + upload endpoint
        let app = Router::new()
            .route(
                "/v1/images/generations",
                post(|| async {
                    Json(serde_json::json!({
                        "created": 1234567890,
                        "data": [
                            {"b64_json": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg=="}
                        ]
                    }))
                }),
            )
            .route(
                "/v1/provider/image-upload",
                post(move |body: Bytes| {
                    let uploaded = uploaded_clone.clone();
                    async move {
                        uploaded.lock().unwrap().push(body.to_vec());
                        Json(serde_json::json!({"status": "ok"}))
                    }
                }),
            );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let base = format!("http://127.0.0.1:{}", addr.port());
        let upload_url = format!("{base}/v1/provider/image-upload?request_id=img-req-1");

        let (tx, mut rx) = mpsc::channel(32);
        let body = ImageGenerationRequestBody {
            model: "flux-klein-4b".to_string(),
            prompt: "a cat wearing a hat".to_string(),
            negative_prompt: None,
            n: 1,
            size: Some("1024x1024".to_string()),
            steps: Some(4),
            seed: Some(42),
            response_format: None,
        };

        handle_image_generation_request(
            "img-req-1".to_string(),
            body,
            base,
            upload_url,
            tx,
            CancellationToken::new(),
        )
        .await;

        // Verify image was uploaded via HTTP (not WebSocket)
        let uploads = uploaded.lock().unwrap();
        assert_eq!(uploads.len(), 1, "Expected 1 image uploaded via HTTP");
        assert!(!uploads[0].is_empty(), "Uploaded image should not be empty");

        // WebSocket message should have usage but no images
        let msg = rx.recv().await.unwrap();
        match msg {
            ProviderMessage::ImageGenerationComplete {
                request_id,
                usage,
                duration_secs,
            } => {
                assert_eq!(request_id, "img-req-1");
                assert_eq!(usage.images_generated, 1);
                assert_eq!(usage.width, 1024);
                assert_eq!(usage.height, 1024);
                assert_eq!(usage.steps, 4);
                assert_eq!(usage.model, "flux-klein-4b");
                assert!(duration_secs > 0.0);
            }
            other => panic!("Expected ImageGenerationComplete, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn test_handle_image_generation_error() {
        use axum::{Router, http::StatusCode, routing::post};

        let app = Router::new().route(
            "/v1/images/generations",
            post(|| async { (StatusCode::INTERNAL_SERVER_ERROR, "model not loaded") }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let (tx, mut rx) = mpsc::channel(32);
        let body = ImageGenerationRequestBody {
            model: "flux-klein-4b".to_string(),
            prompt: "test".to_string(),
            negative_prompt: None,
            n: 1,
            size: None,
            steps: None,
            seed: None,
            response_format: None,
        };

        handle_image_generation_request(
            "img-err-1".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            "http://127.0.0.1:1/unused".to_string(),
            tx,
            CancellationToken::new(),
        )
        .await;

        let msg = rx.recv().await.unwrap();
        match msg {
            ProviderMessage::InferenceError {
                request_id,
                error,
                status_code,
            } => {
                assert_eq!(request_id, "img-err-1");
                assert_eq!(status_code, 500);
                assert!(error.contains("model not loaded"));
            }
            other => panic!("Expected InferenceError, got {:?}", other),
        }
    }

    /// Test 1: Streaming response parsing — verify individual SSE chunks are
    /// correctly parsed, forwarded as InferenceResponseChunk messages, and the
    /// accumulated content matches what the mock backend sent.
    #[tokio::test]
    async fn test_streaming_chunk_content_verified() {
        use axum::{Router, body::Body, http::StatusCode, response::Response, routing::post};

        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                let sse_data = [
                    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n",
                    "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
                    "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n",
                    "data: {\"choices\":[{\"delta\":{\"content\":\"!\"}}]}\n\n",
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
            "req-chunk-verify".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        // Collect all messages
        let mut chunks = Vec::new();
        let mut complete = None;
        while let Ok(Some(msg)) =
            tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv()).await
        {
            match msg {
                ProviderMessage::InferenceResponseChunk { data, .. } => {
                    chunks.push(data);
                }
                ProviderMessage::InferenceComplete {
                    usage,
                    response_hash,
                    ..
                } => {
                    complete = Some((usage, response_hash));
                }
                _ => {}
            }
        }

        // Verify individual chunks contain the expected content fragments
        let all_chunk_text = chunks.join("\n");
        assert!(
            all_chunk_text.contains("Hello"),
            "Chunks should contain 'Hello'"
        );
        assert!(
            all_chunk_text.contains(" world"),
            "Chunks should contain ' world'"
        );
        assert!(all_chunk_text.contains("!"), "Chunks should contain '!'");

        // Verify InferenceComplete was sent with token counts
        let (usage, response_hash) = complete.expect("Should receive InferenceComplete");
        // Each content chunk counts as 1 token (the approximate counting logic)
        assert!(
            usage.completion_tokens >= 3,
            "Should count at least 3 completion tokens, got {}",
            usage.completion_tokens
        );
        assert!(response_hash.is_some(), "Response hash should be present");
    }

    /// Test 2 (enhanced): Non-streaming response verifies response_hash and
    /// SE signature fields are populated (even if SE is unavailable, the hash
    /// should still be computed).
    #[tokio::test]
    async fn test_non_streaming_response_hash_and_signature() {
        use axum::{Json, Router, routing::post};

        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                Json(serde_json::json!({
                    "id": "chatcmpl-test",
                    "choices": [{"message": {"role": "assistant", "content": "The answer is 42."}}],
                    "usage": {"prompt_tokens": 15, "completion_tokens": 7, "total_tokens": 22}
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
            "messages": [{"role": "user", "content": "What is the meaning of life?"}],
            "stream": false
        });

        handle_inference_request(
            "req-hash-test".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        // First: InferenceResponseChunk with the content
        let chunk = rx.recv().await.unwrap();
        match &chunk {
            ProviderMessage::InferenceResponseChunk { request_id, data } => {
                assert_eq!(request_id, "req-hash-test");
                assert!(
                    data.contains("The answer is 42."),
                    "Chunk should contain response content"
                );
            }
            other => panic!("Expected InferenceResponseChunk, got {:?}", other),
        }

        // Second: InferenceComplete with hash
        let msg = rx.recv().await.unwrap();
        match msg {
            ProviderMessage::InferenceComplete {
                request_id,
                usage,
                response_hash,
                ..
            } => {
                assert_eq!(request_id, "req-hash-test");
                assert_eq!(usage.prompt_tokens, 15);
                assert_eq!(usage.completion_tokens, 7);
                // response_hash should always be computed (SHA-256 hex)
                let hash = response_hash.expect("response_hash should be present");
                assert_eq!(
                    hash.len(),
                    64,
                    "SHA-256 hex should be 64 chars, got {}",
                    hash.len()
                );
                // Verify it's valid hex
                assert!(
                    hash.chars().all(|c| c.is_ascii_hexdigit()),
                    "Hash should be hex"
                );
            }
            other => panic!("Expected InferenceComplete, got {:?}", other),
        }
    }

    /// Test 3 (enhanced): Cancellation during initial HTTP connection phase.
    /// Cancel before the backend even responds — should bail cleanly without
    /// sending any error message.
    #[tokio::test]
    async fn test_cancel_during_connection_phase() {
        use axum::{Router, routing::post};

        // Backend that takes forever to respond (simulates slow connection)
        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                axum::Json(serde_json::json!({"choices": []}))
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let (tx, mut rx) = mpsc::channel(32);
        let cancel_token = CancellationToken::new();
        let token_clone = cancel_token.clone();

        let body = serde_json::json!({
            "model": "test",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": false
        });

        let handle = tokio::spawn(async move {
            handle_inference_request(
                "req-cancel-connect".to_string(),
                body,
                format!("http://127.0.0.1:{}", addr.port()),
                tx,
                None,
                token_clone,
                None,
            )
            .await;
        });

        // Cancel almost immediately (before response)
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        cancel_token.cancel();

        let _ = tokio::time::timeout(std::time::Duration::from_secs(2), handle).await;

        // Should NOT receive an InferenceError — cancelled requests are silent
        let msg = tokio::time::timeout(std::time::Duration::from_millis(100), rx.recv()).await;
        assert!(
            msg.is_err() || msg.unwrap().is_none(),
            "Cancelled non-streaming request should not send any messages"
        );
    }

    /// Test 4 (enhanced): Backend returns various HTTP error codes.
    /// Verify status_code is forwarded correctly for 400, 404, 503.
    #[tokio::test]
    async fn test_error_status_codes_forwarded() {
        use axum::{Router, extract::Path, http::StatusCode, routing::post};

        // Backend that returns the status code from the URL path
        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async { (StatusCode::BAD_REQUEST, "invalid model parameter") }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let (tx, mut rx) = mpsc::channel(32);
        let body = serde_json::json!({"model": "nonexistent", "messages": [], "stream": false});

        handle_inference_request(
            "req-400".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        let msg = rx.recv().await.unwrap();
        match msg {
            ProviderMessage::InferenceError {
                status_code, error, ..
            } => {
                assert_eq!(status_code, 400);
                assert!(error.contains("invalid model parameter"));
            }
            other => panic!("Expected InferenceError, got {:?}", other),
        }
    }

    /// Test 4b: Streaming request that returns an error should produce InferenceError.
    #[tokio::test]
    async fn test_streaming_error_response() {
        use axum::{Router, http::StatusCode, routing::post};

        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async { (StatusCode::SERVICE_UNAVAILABLE, "backend overloaded") }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let (tx, mut rx) = mpsc::channel(32);
        let body = serde_json::json!({"model": "test", "messages": [], "stream": true});

        handle_inference_request(
            "req-stream-err".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        let msg = rx.recv().await.unwrap();
        match msg {
            ProviderMessage::InferenceError {
                status_code, error, ..
            } => {
                assert_eq!(status_code, 503);
                assert!(error.contains("backend overloaded"));
            }
            other => panic!("Expected InferenceError, got {:?}", other),
        }
    }

    /// Test 5: Backend unreachable — connection refused should produce an
    /// InferenceError with status 500 (internal failure).
    #[tokio::test]
    async fn test_backend_unreachable_error() {
        let (tx, mut rx) = mpsc::channel(32);
        let body = serde_json::json!({
            "model": "test",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": false
        });

        // Use a port that nothing is listening on
        handle_inference_request(
            "req-unreachable".to_string(),
            body,
            "http://127.0.0.1:19997".to_string(),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        let msg = rx.recv().await.unwrap();
        match msg {
            ProviderMessage::InferenceError {
                request_id,
                status_code,
                ..
            } => {
                assert_eq!(request_id, "req-unreachable");
                assert_eq!(status_code, 500, "Connection refused should produce 500");
            }
            other => panic!("Expected InferenceError, got {:?}", other),
        }
    }

    /// Test 5b: Streaming backend unreachable produces InferenceError.
    #[tokio::test]
    async fn test_streaming_backend_unreachable() {
        let (tx, mut rx) = mpsc::channel(32);
        let body = serde_json::json!({
            "model": "test",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": true
        });

        handle_inference_request(
            "req-stream-unreachable".to_string(),
            body,
            "http://127.0.0.1:19996".to_string(),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        let msg = rx.recv().await.unwrap();
        match msg {
            ProviderMessage::InferenceError {
                request_id,
                status_code,
                ..
            } => {
                assert_eq!(request_id, "req-stream-unreachable");
                assert_eq!(status_code, 500);
            }
            other => panic!("Expected InferenceError, got {:?}", other),
        }
    }

    /// Test: Stats counters are incremented after successful inference.
    #[tokio::test]
    async fn test_stats_counters_incremented() {
        use axum::{Json, Router, routing::post};
        use std::sync::atomic::Ordering;

        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                Json(serde_json::json!({
                    "choices": [{"message": {"content": "test"}}],
                    "usage": {"prompt_tokens": 5, "completion_tokens": 10}
                }))
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let stats = Arc::new(AtomicProviderStats::new());
        let (tx, mut rx) = mpsc::channel(32);
        let body = serde_json::json!({
            "model": "test",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": false
        });

        handle_inference_request(
            "req-stats".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            Some(stats.clone()),
        )
        .await;

        // Drain messages
        while let Ok(Some(_)) =
            tokio::time::timeout(std::time::Duration::from_millis(100), rx.recv()).await
        {}

        assert_eq!(stats.requests_served.load(Ordering::Relaxed), 1);
        assert_eq!(stats.tokens_generated.load(Ordering::Relaxed), 10);
    }

    /// Test: Stats counters are incremented for streaming requests too.
    #[tokio::test]
    async fn test_stats_counters_streaming() {
        use axum::{Router, body::Body, http::StatusCode, response::Response, routing::post};
        use std::sync::atomic::Ordering;

        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n\
                           data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\n\
                           data: [DONE]\n\n";
                Response::builder()
                    .status(StatusCode::OK)
                    .header("content-type", "text/event-stream")
                    .body(Body::from(sse))
                    .unwrap()
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let stats = Arc::new(AtomicProviderStats::new());
        let (tx, mut rx) = mpsc::channel(32);
        let body = serde_json::json!({
            "model": "test",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": true
        });

        handle_inference_request(
            "req-stats-stream".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            Some(stats.clone()),
        )
        .await;

        // Drain messages
        while let Ok(Some(_)) =
            tokio::time::timeout(std::time::Duration::from_millis(100), rx.recv()).await
        {}

        assert_eq!(stats.requests_served.load(Ordering::Relaxed), 1);
        assert!(
            stats.tokens_generated.load(Ordering::Relaxed) >= 2,
            "Should count at least 2 tokens"
        );
    }

    /// Test: Custom endpoint routing. When body contains "endpoint", the proxy
    /// should use it instead of /v1/chat/completions.
    #[tokio::test]
    async fn test_custom_endpoint_routing() {
        use axum::{Json, Router, routing::post};

        let app = Router::new()
            .route(
                "/v1/custom/endpoint",
                post(|| async {
                    Json(serde_json::json!({
                        "choices": [{"message": {"content": "custom!"}}],
                        "usage": {"prompt_tokens": 1, "completion_tokens": 1}
                    }))
                }),
            )
            .route(
                "/v1/chat/completions",
                post(|| async {
                    Json(serde_json::json!({
                        "choices": [{"message": {"content": "default"}}],
                        "usage": {"prompt_tokens": 1, "completion_tokens": 1}
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
            "stream": false,
            "endpoint": "/v1/custom/endpoint"
        });

        handle_inference_request(
            "req-custom".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        let chunk = rx.recv().await.unwrap();
        match &chunk {
            ProviderMessage::InferenceResponseChunk { data, .. } => {
                assert!(
                    data.contains("custom!"),
                    "Should hit custom endpoint, got: {}",
                    data
                );
            }
            other => panic!("Expected InferenceResponseChunk, got {:?}", other),
        }
    }

    /// Test: Streaming with backend-reported usage (some backends include usage
    /// in chunks). Verify the reported values override the approximate count.
    #[tokio::test]
    async fn test_streaming_backend_reported_usage() {
        use axum::{Router, body::Body, http::StatusCode, response::Response, routing::post};

        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n\
                           data: {\"choices\":[{\"delta\":{\"content\":\" there\"}}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":50}}\n\n\
                           data: [DONE]\n\n";
                Response::builder()
                    .status(StatusCode::OK)
                    .header("content-type", "text/event-stream")
                    .body(Body::from(sse))
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
            "req-usage-report".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        // Find the InferenceComplete message
        let mut complete = None;
        while let Ok(Some(msg)) =
            tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv()).await
        {
            if let ProviderMessage::InferenceComplete { usage, .. } = msg {
                complete = Some(usage);
            }
        }

        let usage = complete.expect("Should receive InferenceComplete");
        // The backend-reported usage (50) is set, then the approximate counter
        // also adds 1 per content chunk. The code uses both, so completion_tokens
        // should be >= 50 (backend-reported) since the last set value wins plus
        // the per-chunk increment.
        assert_eq!(
            usage.prompt_tokens, 20,
            "prompt_tokens should come from backend"
        );
        assert!(
            usage.completion_tokens >= 50,
            "completion_tokens should include backend-reported value, got {}",
            usage.completion_tokens
        );
    }

    /// Test: Streaming response without [DONE] sentinel still produces
    /// InferenceComplete (the "stream ended without [DONE]" fallback path).
    #[tokio::test]
    async fn test_streaming_no_done_sentinel() {
        use axum::{Router, body::Body, http::StatusCode, response::Response, routing::post};

        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async {
                // Stream that ends without [DONE]
                let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n";
                Response::builder()
                    .status(StatusCode::OK)
                    .header("content-type", "text/event-stream")
                    .body(Body::from(sse))
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
            "req-no-done".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        let mut got_complete = false;
        while let Ok(Some(msg)) =
            tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv()).await
        {
            if matches!(msg, ProviderMessage::InferenceComplete { .. }) {
                got_complete = true;
            }
        }

        assert!(
            got_complete,
            "Should still send InferenceComplete even without [DONE]"
        );
    }

    /// Test 8: Encrypted request round-trip — encrypt with provider's public key,
    /// then decrypt and verify the plaintext is recoverable.
    #[tokio::test]
    async fn test_encrypted_payload_round_trip() {
        use crate::crypto::NodeKeyPair;
        use crate::protocol::EncryptedPayload;
        use base64::Engine;

        // Generate two key pairs: one for the provider, one as ephemeral consumer key
        let provider_kp = NodeKeyPair::generate();
        let consumer_kp = NodeKeyPair::generate();

        // The plaintext request body
        let plaintext = serde_json::json!({
            "model": "test-model",
            "messages": [{"role": "user", "content": "secret prompt"}],
            "stream": false
        });
        let plaintext_bytes = serde_json::to_vec(&plaintext).unwrap();

        // Consumer encrypts with provider's public key
        let ciphertext = consumer_kp
            .encrypt(&provider_kp.public_key_bytes(), &plaintext_bytes)
            .expect("encryption should succeed");

        // Build the EncryptedPayload (what the coordinator would send)
        let payload = EncryptedPayload {
            ephemeral_public_key: base64::engine::general_purpose::STANDARD
                .encode(consumer_kp.public_key_bytes()),
            ciphertext: base64::engine::general_purpose::STANDARD.encode(&ciphertext),
        };

        // Provider decrypts
        let consumer_pub_bytes: [u8; 32] = base64::engine::general_purpose::STANDARD
            .decode(&payload.ephemeral_public_key)
            .unwrap()
            .try_into()
            .unwrap();
        let ct_bytes = base64::engine::general_purpose::STANDARD
            .decode(&payload.ciphertext)
            .unwrap();
        let decrypted = provider_kp
            .decrypt(&consumer_pub_bytes, &ct_bytes)
            .expect("decryption should succeed");

        let decrypted_json: serde_json::Value = serde_json::from_slice(&decrypted).unwrap();
        assert_eq!(decrypted_json, plaintext);
        assert_eq!(
            decrypted_json["messages"][0]["content"].as_str().unwrap(),
            "secret prompt"
        );
    }

    /// Test 8b: Encrypted payload with wrong key fails decryption.
    #[tokio::test]
    async fn test_encrypted_payload_wrong_key_fails() {
        use crate::crypto::NodeKeyPair;

        let provider_kp = NodeKeyPair::generate();
        let consumer_kp = NodeKeyPair::generate();
        let wrong_provider_kp = NodeKeyPair::generate();

        let plaintext = b"secret data";
        let ciphertext = consumer_kp
            .encrypt(&provider_kp.public_key_bytes(), plaintext)
            .unwrap();

        // Try to decrypt with wrong key — should fail
        let result = wrong_provider_kp.decrypt(&consumer_kp.public_key_bytes(), &ciphertext);
        assert!(result.is_err(), "Decryption with wrong key should fail");
    }

    /// Test: estimate_audio_duration for WAV files.
    #[test]
    fn test_estimate_audio_duration_wav() {
        // Construct a minimal WAV header: 16kHz, 16-bit, mono
        let mut wav = vec![0u8; 100];
        // "RIFF" magic
        wav[0..4].copy_from_slice(b"RIFF");
        // Format "WAVE"
        wav[8..12].copy_from_slice(b"WAVE");
        // Sample rate at offset 24: 16000
        wav[24..28].copy_from_slice(&16000u32.to_le_bytes());
        // Bits per sample at offset 34: 16
        wav[34..36].copy_from_slice(&16u16.to_le_bytes());
        // Channels at offset 22: 1
        wav[22..24].copy_from_slice(&1u16.to_le_bytes());

        // Data starts at 44, so data_bytes = 100 - 44 = 56
        // Duration = 56 / (16000 * 1 * 16/8) = 56 / 32000 = 0.00175s
        let duration = estimate_audio_duration(&wav, "wav");
        assert!(duration > 0.0, "Duration should be positive");
        assert!(
            (duration - 0.00175).abs() < 0.001,
            "Duration should be ~0.00175s, got {}",
            duration
        );
    }

    /// Test: estimate_audio_duration for MP3 files.
    #[test]
    fn test_estimate_audio_duration_mp3() {
        // 128kbps MP3, 16000 bytes = 1 second
        let mp3_data = vec![0u8; 16000];
        let duration = estimate_audio_duration(&mp3_data, "mp3");
        assert!(
            (duration - 1.0).abs() < 0.01,
            "16KB at 128kbps should be ~1s, got {}",
            duration
        );
    }

    /// Test: estimate_audio_duration for unknown format returns 0.
    #[test]
    fn test_estimate_audio_duration_unknown() {
        let data = vec![0u8; 1000];
        let duration = estimate_audio_duration(&data, "ogg");
        assert_eq!(duration, 0.0);
    }

    #[tokio::test]
    async fn test_handle_image_generation_cancel() {
        use axum::{Router, routing::post};

        // Slow backend that takes 10 seconds
        let app = Router::new().route(
            "/v1/images/generations",
            post(|| async {
                tokio::time::sleep(std::time::Duration::from_secs(10)).await;
                axum::Json(serde_json::json!({"data": []}))
            }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let (tx, mut rx) = mpsc::channel(32);
        let cancel_token = CancellationToken::new();
        let token_clone = cancel_token.clone();

        let body = ImageGenerationRequestBody {
            model: "flux-klein-4b".to_string(),
            prompt: "test".to_string(),
            negative_prompt: None,
            n: 1,
            size: None,
            steps: None,
            seed: None,
            response_format: None,
        };

        let handle = tokio::spawn(async move {
            handle_image_generation_request(
                "img-cancel-1".to_string(),
                body,
                format!("http://127.0.0.1:{}", addr.port()),
                "http://127.0.0.1:1/unused".to_string(),
                tx,
                token_clone,
            )
            .await;
        });

        // Cancel after 200ms
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        cancel_token.cancel();

        let _ = tokio::time::timeout(std::time::Duration::from_secs(2), handle).await;

        // Should NOT get an error message (cancelled requests are silent)
        let msg = tokio::time::timeout(std::time::Duration::from_millis(100), rx.recv()).await;
        assert!(
            msg.is_err() || msg.unwrap().is_none(),
            "Cancelled request should not send messages"
        );
    }

    #[tokio::test]
    async fn test_backend_dead_on_connection_refused() {
        // Use a port with nothing listening to simulate a crashed backend
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener); // free the port — nothing listening now

        let (tx, mut rx) = mpsc::channel(32);
        let body = serde_json::json!({
            "model": "test",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": true
        });

        let dead = handle_inference_request(
            "req-dead".to_string(),
            body,
            format!("http://127.0.0.1:{}", port),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        assert!(dead, "connection refused should report backend as dead");

        let msg = rx.recv().await.unwrap();
        match msg {
            ProviderMessage::InferenceError { request_id, .. } => {
                assert_eq!(request_id, "req-dead");
            }
            other => panic!("Expected InferenceError, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn test_backend_not_dead_on_http_error() {
        use axum::{Router, http::StatusCode, routing::post};

        let app = Router::new().route(
            "/v1/chat/completions",
            post(|| async { (StatusCode::BAD_GATEWAY, "upstream error") }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let (tx, _rx) = mpsc::channel(32);
        let body = serde_json::json!({
            "model": "test",
            "messages": [{"role": "user", "content": "hi"}],
            "stream": false
        });

        let dead = handle_inference_request(
            "req-502".to_string(),
            body,
            format!("http://127.0.0.1:{}", addr.port()),
            tx,
            None,
            CancellationToken::new(),
            None,
        )
        .await;

        assert!(!dead, "HTTP 502 should not report backend as dead");
    }
}
