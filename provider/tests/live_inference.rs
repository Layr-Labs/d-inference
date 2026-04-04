//! Live inference integration tests against a real vllm-mlx backend.
//!
//! These tests spin up a real vllm-mlx process with a small model and send
//! actual inference requests to verify the full pipeline works correctly.
//!
//! **Not run in CI** — requires Apple Silicon hardware, vllm-mlx installed,
//! and a model downloaded to ~/.cache/huggingface/hub/. Gate with:
//!
//!     LIVE_INFERENCE_TEST=1 cargo test --test live_inference -- --test-threads=1
//!
//! The tests use a small model (Qwen2.5-0.5B or Qwen3.5-0.8B) for fast
//! iteration. Tests are ordered to reuse a single backend process where
//! possible — the first test starts vllm-mlx and subsequent tests reuse it.

use reqwest::Client;
use serde_json::{Value, json};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// Port for the test backend (unlikely to conflict with anything).
const TEST_PORT: u16 = 18199;
const BASE_URL: &str = "http://127.0.0.1:18199";

/// Small model for testing — fast to load, good enough for edge cases.
/// Tries Qwen3.5-0.8B first, falls back to Qwen2.5-0.5B.
fn test_model() -> &'static str {
    static MODEL: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    MODEL.get_or_init(|| {
        let candidates = [
            "mlx-community/Qwen3.5-0.8B-MLX-4bit",
            "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
        ];
        let hf_cache = dirs::home_dir().unwrap().join(".cache/huggingface/hub");
        for c in &candidates {
            let dir_name = format!("models--{}", c.replace('/', "--"));
            if hf_cache.join(&dir_name).exists() {
                return c.to_string();
            }
        }
        // Fall back to first candidate — will fail at startup with clear error
        candidates[0].to_string()
    })
}

fn should_run() -> bool {
    std::env::var("LIVE_INFERENCE_TEST").map_or(false, |v| v == "1" || v == "true")
}

/// Start vllm-mlx backend and wait for it to become healthy.
fn start_backend() -> Child {
    eprintln!("[test] Starting vllm-mlx with model: {}", test_model());
    let child = Command::new("vllm-mlx")
        .args(["serve", test_model(), "--port", &TEST_PORT.to_string()])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to spawn vllm-mlx — is it installed?");

    eprintln!("[test] vllm-mlx PID: {}", child.id());
    child
}

/// Wait for backend to become healthy (model loaded).
async fn wait_for_healthy(client: &Client, timeout: Duration) {
    let start = Instant::now();
    loop {
        if start.elapsed() > timeout {
            panic!("Backend did not become healthy within {:?}", timeout);
        }
        if let Ok(resp) = client.get(format!("{BASE_URL}/health")).send().await {
            if resp.status().is_success() {
                if let Ok(body) = resp.json::<Value>().await {
                    if body
                        .get("model_loaded")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false)
                    {
                        eprintln!(
                            "[test] Backend healthy and model loaded ({:.1}s)",
                            start.elapsed().as_secs_f64()
                        );
                        return;
                    }
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

/// Send a chat completion request and return the response.
async fn chat(client: &Client, body: Value) -> reqwest::Response {
    client
        .post(format!("{BASE_URL}/v1/chat/completions"))
        .json(&body)
        .send()
        .await
        .expect("failed to send request")
}

/// Send a chat completion and parse the JSON response.
async fn chat_json(client: &Client, body: Value) -> (u16, Value) {
    let resp = chat(client, body).await;
    let status = resp.status().as_u16();
    let json = resp
        .json::<Value>()
        .await
        .unwrap_or(json!({"error": "failed to parse response"}));
    (status, json)
}

/// Collect streaming SSE response into a Vec of parsed JSON chunks.
async fn stream_collect(client: &Client, body: Value) -> (u16, Vec<Value>, String) {
    let resp = client
        .post(format!("{BASE_URL}/v1/chat/completions"))
        .json(&body)
        .send()
        .await
        .expect("failed to send streaming request");

    let status = resp.status().as_u16();
    let text = resp.text().await.unwrap_or_default();

    let mut chunks = Vec::new();
    let mut full_content = String::new();

    for line in text.lines() {
        if let Some(data) = line.strip_prefix("data: ") {
            if data.trim() == "[DONE]" {
                break;
            }
            if let Ok(chunk) = serde_json::from_str::<Value>(data) {
                if let Some(content) = chunk
                    .pointer("/choices/0/delta/content")
                    .and_then(|v| v.as_str())
                {
                    full_content.push_str(content);
                }
                chunks.push(chunk);
            }
        }
    }

    (status, chunks, full_content)
}

/// Extract content from a non-streaming chat completion response.
fn extract_content(resp: &Value) -> &str {
    resp.pointer("/choices/0/message/content")
        .and_then(|v| v.as_str())
        .unwrap_or("")
}

/// Extract finish_reason from a non-streaming response.
fn extract_finish_reason(resp: &Value) -> &str {
    resp.pointer("/choices/0/finish_reason")
        .and_then(|v| v.as_str())
        .unwrap_or("")
}

// ============================================================================
// Test suite — runs against a live vllm-mlx process
// ============================================================================

/// Master test that orchestrates backend lifecycle and runs all sub-tests.
/// This avoids starting/stopping the backend for each test.
#[tokio::test]
async fn live_inference_full_suite() {
    if !should_run() {
        eprintln!("Skipping live inference tests (set LIVE_INFERENCE_TEST=1 to enable)");
        return;
    }

    let client = Client::builder()
        .timeout(Duration::from_secs(120))
        .build()
        .unwrap();

    // Start backend
    let mut backend = start_backend();
    wait_for_healthy(&client, Duration::from_secs(180)).await;

    // Warmup — prime GPU caches
    let warmup_body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 1,
        "stream": false,
    });
    let (status, _) = chat_json(&client, warmup_body).await;
    assert!(status == 200, "warmup failed with status {status}");
    eprintln!("[test] Warmup complete");

    // Run all test cases — order matters for some (e.g. concurrency after basic)
    test_basic_completion(&client).await;
    test_streaming_completion(&client).await;
    test_multi_turn_conversation(&client).await;
    test_system_prompt(&client).await;
    test_max_tokens_1(&client).await;
    test_max_tokens_large(&client).await;
    test_temperature_zero_determinism(&client).await;
    test_temperature_high(&client).await;
    test_empty_content(&client).await;
    test_unicode_and_emoji(&client).await;
    test_very_long_prompt(&client).await;
    test_whitespace_only_prompt(&client).await;
    test_code_in_prompt(&client).await;
    test_json_in_prompt(&client).await;
    test_special_characters_prompt(&client).await;
    test_streaming_token_count(&client).await;
    test_non_streaming_usage_fields(&client).await;
    test_concurrent_requests(&client).await;
    test_rapid_sequential_requests(&client).await;
    test_models_endpoint(&client).await;
    test_health_endpoint(&client).await;
    test_invalid_endpoint(&client).await;

    // Cleanup
    eprintln!("[test] Shutting down backend...");
    unsafe {
        libc::kill(backend.id() as i32, libc::SIGTERM);
    }
    let _ = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if let Ok(Some(_)) = backend.try_wait() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    })
    .await;
    let _ = backend.kill();
    eprintln!("[test] All live inference tests passed!");
}

// ---------------------------------------------------------------------------
// Basic functionality
// ---------------------------------------------------------------------------

async fn test_basic_completion(client: &Client) {
    eprintln!("[test] basic_completion");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "What is 2+2? Answer with just the number."}],
        "max_tokens": 10,
        "stream": false,
        "temperature": 0.0,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200, "basic completion failed: {resp}");

    let content = extract_content(&resp);
    assert!(!content.is_empty(), "response content is empty");
    assert!(content.contains('4'), "expected '4' in response: {content}");
    assert_eq!(
        extract_finish_reason(&resp),
        "stop",
        "expected stop finish_reason"
    );

    // Verify usage is present
    assert!(resp.get("usage").is_some(), "usage field missing");
    let usage = &resp["usage"];
    assert!(
        usage["prompt_tokens"].as_u64().unwrap_or(0) > 0,
        "prompt_tokens should be > 0"
    );
    assert!(
        usage["completion_tokens"].as_u64().unwrap_or(0) > 0,
        "completion_tokens should be > 0"
    );
}

async fn test_streaming_completion(client: &Client) {
    eprintln!("[test] streaming_completion");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "Say hello"}],
        "max_tokens": 20,
        "stream": true,
        "temperature": 0.0,
    });
    let (status, chunks, content) = stream_collect(client, body).await;
    assert_eq!(status, 200, "streaming request failed");
    assert!(!chunks.is_empty(), "no chunks received");
    assert!(!content.is_empty(), "streamed content is empty");

    // First chunk should have a role
    let first = &chunks[0];
    let role = first
        .pointer("/choices/0/delta/role")
        .and_then(|v| v.as_str());
    // Role may or may not be in first chunk depending on backend version
    if role.is_some() {
        assert_eq!(role.unwrap(), "assistant");
    }
}

// ---------------------------------------------------------------------------
// Conversation patterns
// ---------------------------------------------------------------------------

async fn test_multi_turn_conversation(client: &Client) {
    eprintln!("[test] multi_turn_conversation");
    let body = json!({
        "model": test_model(),
        "messages": [
            {"role": "user", "content": "My name is Alice."},
            {"role": "assistant", "content": "Nice to meet you, Alice!"},
            {"role": "user", "content": "What is my name?"},
        ],
        "max_tokens": 30,
        "stream": false,
        "temperature": 0.0,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200, "multi-turn failed: {resp}");
    let content = extract_content(&resp).to_lowercase();
    assert!(
        content.contains("alice"),
        "model should remember name 'Alice': {content}"
    );
}

async fn test_system_prompt(client: &Client) {
    eprintln!("[test] system_prompt");
    let body = json!({
        "model": test_model(),
        "messages": [
            {"role": "system", "content": "You are a pirate. Always say 'Arr!' at the start of your response."},
            {"role": "user", "content": "How are you?"},
        ],
        "max_tokens": 50,
        "stream": false,
        "temperature": 0.0,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200, "system prompt failed: {resp}");
    let content = extract_content(&resp);
    assert!(!content.is_empty(), "system prompt response empty");
    // Small models may or may not follow the pirate instruction perfectly,
    // but the request should succeed without error
}

// ---------------------------------------------------------------------------
// Token limits and generation control
// ---------------------------------------------------------------------------

async fn test_max_tokens_1(client: &Client) {
    eprintln!("[test] max_tokens_1");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "Tell me a very long story about dragons."}],
        "max_tokens": 1,
        "stream": false,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200, "max_tokens=1 failed: {resp}");

    let usage = &resp["usage"];
    let completion_tokens = usage["completion_tokens"].as_u64().unwrap_or(0);
    // vllm-mlx may generate 1-2 tokens with max_tokens=1
    assert!(
        completion_tokens <= 3,
        "expected <=3 completion tokens with max_tokens=1, got {completion_tokens}"
    );

    let finish = extract_finish_reason(&resp);
    assert!(
        finish == "length" || finish == "stop",
        "expected length or stop finish_reason, got: {finish}"
    );
}

async fn test_max_tokens_large(client: &Client) {
    eprintln!("[test] max_tokens_large");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "Say exactly: 'OK'"}],
        "max_tokens": 8192,
        "stream": false,
        "temperature": 0.0,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200, "max_tokens=8192 failed: {resp}");
    // Should succeed — model finishes before hitting the limit
    let finish = extract_finish_reason(&resp);
    assert!(
        finish == "stop" || finish == "length",
        "unexpected finish_reason: {finish}"
    );
}

// ---------------------------------------------------------------------------
// Temperature
// ---------------------------------------------------------------------------

async fn test_temperature_zero_determinism(client: &Client) {
    eprintln!("[test] temperature_zero_determinism");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "What is the capital of France? One word answer."}],
        "max_tokens": 5,
        "stream": false,
        "temperature": 0.0,
    });

    let (_, resp1) = chat_json(client, body.clone()).await;
    let (_, resp2) = chat_json(client, body.clone()).await;
    let (_, resp3) = chat_json(client, body).await;

    let c1 = extract_content(&resp1);
    let c2 = extract_content(&resp2);
    let c3 = extract_content(&resp3);

    assert_eq!(
        c1, c2,
        "temperature=0 should be deterministic: '{c1}' vs '{c2}'"
    );
    assert_eq!(
        c2, c3,
        "temperature=0 should be deterministic: '{c2}' vs '{c3}'"
    );
}

async fn test_temperature_high(client: &Client) {
    eprintln!("[test] temperature_high");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "Generate a random word."}],
        "max_tokens": 10,
        "stream": false,
        "temperature": 1.5,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200, "high temperature failed: {resp}");
    assert!(
        !extract_content(&resp).is_empty(),
        "high temp response empty"
    );
}

// ---------------------------------------------------------------------------
// Content edge cases
// ---------------------------------------------------------------------------

async fn test_empty_content(client: &Client) {
    eprintln!("[test] empty_content");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": ""}],
        "max_tokens": 10,
        "stream": false,
    });
    let (status, _resp) = chat_json(client, body).await;
    // Backend may return 200 or 400 for empty content — both acceptable
    assert!(
        status == 200 || status == 400,
        "unexpected status for empty content: {status}"
    );
}

async fn test_unicode_and_emoji(client: &Client) {
    eprintln!("[test] unicode_and_emoji");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "Translate to English: \u{1F600} means happy. \u{4F60}\u{597D}\u{4E16}\u{754C} means hello world. What does \u{2764}\u{FE0F} mean?"}],
        "max_tokens": 30,
        "stream": false,
        "temperature": 0.0,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200, "unicode/emoji failed: {resp}");
    assert!(!extract_content(&resp).is_empty(), "unicode response empty");
}

async fn test_very_long_prompt(client: &Client) {
    eprintln!("[test] very_long_prompt");
    // Create a ~4000 token prompt (roughly 16KB of text)
    let long_text = "The quick brown fox jumps over the lazy dog. ".repeat(400);
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": format!("Summarize this in one sentence: {long_text}")}],
        "max_tokens": 30,
        "stream": false,
    });
    let (status, resp) = chat_json(client, body).await;
    // May succeed or fail with context length — both are valid
    assert!(
        status == 200 || status == 400,
        "unexpected status for long prompt: {status}: {resp}"
    );
}

async fn test_whitespace_only_prompt(client: &Client) {
    eprintln!("[test] whitespace_only_prompt");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "   \n\t\n   "}],
        "max_tokens": 10,
        "stream": false,
    });
    let (status, _) = chat_json(client, body).await;
    // Whitespace-only is technically valid content
    assert!(
        status == 200 || status == 400,
        "unexpected status for whitespace: {status}"
    );
}

async fn test_code_in_prompt(client: &Client) {
    eprintln!("[test] code_in_prompt");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "What does this code do?\n```python\ndef fib(n):\n    if n <= 1:\n        return n\n    return fib(n-1) + fib(n-2)\n```"}],
        "max_tokens": 50,
        "stream": false,
        "temperature": 0.0,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200, "code prompt failed: {resp}");
    let content = extract_content(&resp).to_lowercase();
    assert!(
        content.contains("fibonacci")
            || content.contains("fib")
            || content.contains("recursive")
            || content.contains("number"),
        "expected code-related response: {content}"
    );
}

async fn test_json_in_prompt(client: &Client) {
    eprintln!("[test] json_in_prompt");
    // JSON with special characters, nested objects, arrays — tests escaping
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "Parse this JSON and tell me the name: {\"user\": {\"name\": \"O'Brien\", \"tags\": [\"admin\", \"user\"], \"bio\": \"He said \\\"hello\\\"\"}}"}],
        "max_tokens": 20,
        "stream": false,
        "temperature": 0.0,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200, "json prompt failed: {resp}");
    assert!(
        !extract_content(&resp).is_empty(),
        "json prompt response empty"
    );
}

async fn test_special_characters_prompt(client: &Client) {
    eprintln!("[test] special_characters_prompt");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "Repeat exactly: <script>alert('xss')</script> & \"quotes\" \\ backslash \0 null"}],
        "max_tokens": 30,
        "stream": false,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200, "special chars failed: {resp}");
    // Just verify it doesn't crash
    assert!(
        !extract_content(&resp).is_empty(),
        "special chars response empty"
    );
}

// ---------------------------------------------------------------------------
// Streaming specifics
// ---------------------------------------------------------------------------

async fn test_streaming_token_count(client: &Client) {
    eprintln!("[test] streaming_token_count");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "Count from 1 to 5."}],
        "max_tokens": 30,
        "stream": true,
        "temperature": 0.0,
    });
    let (status, chunks, content) = stream_collect(client, body).await;
    assert_eq!(status, 200, "streaming count failed");
    assert!(
        chunks.len() >= 2,
        "expected at least 2 chunks, got {}",
        chunks.len()
    );
    assert!(!content.is_empty(), "streamed content is empty");

    // Last chunk should have finish_reason
    let last = chunks.last().unwrap();
    let finish = last
        .pointer("/choices/0/finish_reason")
        .and_then(|v| v.as_str());
    // finish_reason may be in the last chunk or a separate one
    if let Some(f) = finish {
        assert!(f == "stop" || f == "length", "unexpected finish: {f}");
    }
}

// ---------------------------------------------------------------------------
// Usage / billing fields
// ---------------------------------------------------------------------------

async fn test_non_streaming_usage_fields(client: &Client) {
    eprintln!("[test] non_streaming_usage_fields");
    let body = json!({
        "model": test_model(),
        "messages": [{"role": "user", "content": "Say hi"}],
        "max_tokens": 5,
        "stream": false,
    });
    let (status, resp) = chat_json(client, body).await;
    assert_eq!(status, 200);

    let usage = resp.get("usage").expect("usage field missing");
    let prompt_tokens = usage["prompt_tokens"]
        .as_u64()
        .expect("prompt_tokens missing");
    let completion_tokens = usage["completion_tokens"]
        .as_u64()
        .expect("completion_tokens missing");
    let total_tokens = usage["total_tokens"]
        .as_u64()
        .expect("total_tokens missing");

    assert!(prompt_tokens > 0, "prompt_tokens should be > 0");
    assert!(completion_tokens > 0, "completion_tokens should be > 0");
    assert_eq!(
        total_tokens,
        prompt_tokens + completion_tokens,
        "total should equal prompt + completion"
    );
}

// ---------------------------------------------------------------------------
// Concurrency and load
// ---------------------------------------------------------------------------

async fn test_concurrent_requests(client: &Client) {
    eprintln!("[test] concurrent_requests (5 parallel)");
    let mut handles = Vec::new();

    for i in 0..5 {
        let client = client.clone();
        let handle = tokio::spawn(async move {
            let body = json!({
                "model": test_model(),
                "messages": [{"role": "user", "content": format!("What is {i}+{i}? Just the number.")}],
                "max_tokens": 5,
                "stream": false,
                "temperature": 0.0,
            });
            let (status, resp) = chat_json(&client, body).await;
            (i, status, resp)
        });
        handles.push(handle);
    }

    let mut success_count = 0;
    for handle in handles {
        let (i, status, resp) = handle.await.unwrap();
        if status == 200 {
            let content = extract_content(&resp);
            assert!(
                !content.is_empty(),
                "concurrent req {i} returned empty content"
            );
            success_count += 1;
        } else {
            eprintln!("[test] concurrent req {i} got status {status} (may be expected under load)");
        }
    }
    assert!(
        success_count >= 3,
        "expected at least 3/5 concurrent requests to succeed, got {success_count}"
    );
}

async fn test_rapid_sequential_requests(client: &Client) {
    eprintln!("[test] rapid_sequential_requests (10 back-to-back)");
    let start = Instant::now();
    for i in 0..10 {
        let body = json!({
            "model": test_model(),
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 1,
            "stream": false,
        });
        let (status, _) = chat_json(client, body).await;
        assert_eq!(status, 200, "rapid request {i} failed");
    }
    let elapsed = start.elapsed();
    eprintln!(
        "[test] 10 rapid requests completed in {:.1}s ({:.0}ms avg)",
        elapsed.as_secs_f64(),
        elapsed.as_millis() as f64 / 10.0
    );
}

// ---------------------------------------------------------------------------
// Endpoint tests (non-inference)
// ---------------------------------------------------------------------------

async fn test_models_endpoint(client: &Client) {
    eprintln!("[test] models_endpoint");
    let resp = client
        .get(format!("{BASE_URL}/v1/models"))
        .send()
        .await
        .expect("models request failed");
    assert_eq!(resp.status(), 200);

    let body: Value = resp.json().await.unwrap();
    let data = body["data"]
        .as_array()
        .expect("models response should have 'data' array");
    assert!(!data.is_empty(), "models list should not be empty");

    // Our model should be in the list
    let model_ids: Vec<&str> = data.iter().filter_map(|m| m["id"].as_str()).collect();
    assert!(
        model_ids.iter().any(|id| id.contains("Qwen")),
        "expected a Qwen model in list: {model_ids:?}"
    );
}

async fn test_health_endpoint(client: &Client) {
    eprintln!("[test] health_endpoint");
    let resp = client
        .get(format!("{BASE_URL}/health"))
        .send()
        .await
        .expect("health request failed");
    assert_eq!(resp.status(), 200);

    let body: Value = resp.json().await.unwrap();
    let model_loaded = body["model_loaded"].as_bool().unwrap_or(false);
    assert!(model_loaded, "model should be loaded: {body}");
}

async fn test_invalid_endpoint(client: &Client) {
    eprintln!("[test] invalid_endpoint");
    let resp = client
        .get(format!("{BASE_URL}/v1/nonexistent"))
        .send()
        .await
        .expect("invalid endpoint request failed");
    // vllm-mlx should return 404 or 405 for unknown endpoints
    assert!(
        resp.status() == 404 || resp.status() == 405 || resp.status() == 400,
        "expected 4xx for invalid endpoint, got {}",
        resp.status()
    );
}
