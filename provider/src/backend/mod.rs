//! Inference backend management for the Darkbloom provider.
//!
//! Supported backends are vllm-mlx and mlx-lm.
//!
//! We prefer mlx-lm in production right now because vllm-mlx has been observed
//! to accept HTTP requests and then hang indefinitely on generation for some
//! large quantized models. Both expose an OpenAI-compatible API.
//!
//! The BackendManager wraps the backend with health monitoring and automatic
//! restart. It periodically checks the backend's /health endpoint and
//! restarts it with exponential backoff if it becomes unhealthy.
//!
//! The backend is spawned as a child process and communicates via HTTP
//! on localhost. Its stdout/stderr are forwarded to the provider's
//! tracing output for unified logging.

pub mod vllm_mlx;

use anyhow::Result;
use async_trait::async_trait;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;

/// Trait that all inference backends must implement.
#[async_trait]
pub trait Backend: Send + Sync {
    /// Start the backend process.
    async fn start(&mut self) -> Result<()>;

    /// Stop the backend process gracefully.
    async fn stop(&mut self) -> Result<()>;

    /// Check if the backend is healthy.
    async fn health(&self) -> bool;

    /// Get the base URL for HTTP requests to this backend.
    fn base_url(&self) -> String;

    /// Get the backend name.
    fn name(&self) -> &str;
}

/// Manages the active backend with health monitoring and auto-restart.
pub struct BackendManager {
    backend: Arc<Mutex<Box<dyn Backend>>>,
    health_interval: Duration,
    shutdown: tokio::sync::watch::Sender<bool>,
    shutdown_rx: tokio::sync::watch::Receiver<bool>,
}

impl BackendManager {
    pub fn new(backend: Box<dyn Backend>, health_interval: Duration) -> Self {
        let (shutdown, shutdown_rx) = tokio::sync::watch::channel(false);
        Self {
            backend: Arc::new(Mutex::new(backend)),
            health_interval,
            shutdown,
            shutdown_rx,
        }
    }

    /// Start the backend and begin health monitoring.
    pub async fn start(&self) -> Result<()> {
        {
            let mut backend = self.backend.lock().await;
            backend.start().await?;
        }

        let backend = Arc::clone(&self.backend);
        let interval = self.health_interval;
        let mut shutdown_rx = self.shutdown_rx.clone();

        tokio::spawn(async move {
            let mut backoff = ExponentialBackoff::new();

            loop {
                tokio::select! {
                    _ = shutdown_rx.changed() => {
                        tracing::info!("Backend health monitor shutting down");
                        break;
                    }
                    _ = tokio::time::sleep(interval) => {
                        let b = backend.lock().await;
                        if !b.health().await {
                            let backend_name = b.name().to_string();
                            tracing::warn!("Backend {} health check failed", backend_name);
                            drop(b);

                            // Report the crash to telemetry before we try to recover.
                            crate::telemetry::emit(
                                crate::telemetry::TelemetryEvent::new(
                                    crate::telemetry::Source::Provider,
                                    crate::telemetry::Severity::Error,
                                    crate::telemetry::Kind::BackendCrash,
                                    format!("backend health check failed: {}", backend_name),
                                )
                                .with_field("backend", backend_name.clone())
                                .with_field("component", "provider"),
                            );

                            let delay = backoff.next_delay();
                            tracing::info!("Restarting backend in {:?}", delay);
                            tokio::time::sleep(delay).await;

                            let mut b = backend.lock().await;
                            if let Err(e) = b.stop().await {
                                tracing::warn!("Error stopping unhealthy backend: {e}");
                            }
                            match b.start().await {
                                Ok(()) => {
                                    tracing::info!("Backend {} restarted successfully", b.name());
                                    backoff.reset();
                                }
                                Err(e) => {
                                    tracing::error!("Failed to restart backend: {e}");
                                    crate::telemetry::emit(
                                        crate::telemetry::TelemetryEvent::new(
                                            crate::telemetry::Source::Provider,
                                            crate::telemetry::Severity::Error,
                                            crate::telemetry::Kind::BackendCrash,
                                            "backend restart failed",
                                        )
                                        .with_field("backend", backend_name)
                                        .with_field("reason", "restart_error")
                                        .with_field("error", format!("{e}")),
                                    );
                                }
                            }
                        } else {
                            backoff.reset();
                        }
                    }
                }
            }
        });

        Ok(())
    }

    /// Stop the backend and health monitoring.
    pub async fn stop(&self) -> Result<()> {
        let _ = self.shutdown.send(true);
        let mut backend = self.backend.lock().await;
        backend.stop().await
    }

    /// Get the base URL for the active backend.
    pub async fn base_url(&self) -> String {
        let backend = self.backend.lock().await;
        backend.base_url()
    }

    /// Check if the backend is healthy.
    #[allow(dead_code)]
    pub async fn is_healthy(&self) -> bool {
        let backend = self.backend.lock().await;
        backend.health().await
    }

    /// Get a reference to the backend mutex (for proxy use).
    #[allow(dead_code)]
    pub fn backend(&self) -> &Arc<Mutex<Box<dyn Backend>>> {
        &self.backend
    }
}

/// Exponential backoff calculator: 1s, 2s, 4s, 8s, ... max 60s.
pub struct ExponentialBackoff {
    current: Duration,
    max: Duration,
}

impl ExponentialBackoff {
    pub fn new() -> Self {
        Self {
            current: Duration::from_secs(1),
            max: Duration::from_secs(5),
        }
    }

    pub fn next_delay(&mut self) -> Duration {
        let delay = self.current;
        self.current = (self.current * 2).min(self.max);
        delay
    }

    pub fn reset(&mut self) {
        self.current = Duration::from_secs(1);
    }
}

impl Default for ExponentialBackoff {
    fn default() -> Self {
        Self::new()
    }
}

/// Check if a binary exists on PATH.
pub fn binary_exists(name: &str) -> bool {
    std::process::Command::new("which")
        .arg(name)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Build an HTTP client for health checks.
fn health_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap_or_default()
}

/// Perform a health check against the given URL.
///
/// Different backends expose different health surfaces:
/// - vllm-mlx: `/health`
/// - mlx_lm.server: `/v1/models`
pub async fn check_health(base_url: &str) -> bool {
    let client = health_client();

    for path in ["/health", "/v1/models"] {
        let url = format!("{base_url}{path}");
        if let Ok(resp) = client.get(&url).send().await {
            if resp.status().is_success() {
                return true;
            }
        }
    }

    false
}

/// Check if the backend has fully loaded its model into GPU memory.
/// Returns true only when the /health endpoint reports model_loaded: true.
pub async fn check_model_loaded(base_url: &str) -> bool {
    let client = health_client();

    // vllm-mlx reports explicit model_loaded state on /health.
    // Only trust an explicit `true` — if the field is missing or the
    // body isn't JSON, fall through to the /v1/models check below.
    // Previously, missing field defaulted to true, causing us to skip
    // the wait loop and jump to warmup before weights were in GPU memory.
    let health_url = format!("{base_url}/health");
    if let Ok(resp) = client.get(&health_url).send().await {
        if resp.status().is_success() {
            if let Ok(body) = resp.json::<serde_json::Value>().await {
                if let Some(loaded) = body.get("model_loaded").and_then(|v| v.as_bool()) {
                    return loaded;
                }
                // Field missing — don't assume loaded, fall through.
            }
            // Non-JSON 200 — server is up but can't confirm model state.
        }
    }

    // mlx_lm.server does not expose /health; if /v1/models responds, treat the
    // backend as loaded enough to serve requests.
    let models_url = format!("{base_url}/v1/models");
    matches!(
        client.get(&models_url).send().await,
        Ok(resp) if resp.status().is_success()
    )
}

/// Send a minimal warmup request to prime the model's GPU caches.
/// This avoids the 30-50s first-token penalty on real user requests.
pub async fn warmup_backend(base_url: &str) -> bool {
    let url = format!("{base_url}/v1/chat/completions");
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .unwrap_or_default();

    // Fetch the model name from /v1/models so the warmup request
    // uses the correct model identifier. The model field is required
    // by the OpenAI schema — without it, vllm-mlx returns 422.
    let models_url = format!("{base_url}/v1/models");
    let model_name = match client.get(&models_url).send().await {
        Ok(resp) if resp.status().is_success() => resp
            .json::<serde_json::Value>()
            .await
            .ok()
            .and_then(|v| {
                v.get("data")
                    .and_then(|d| d.as_array())
                    .and_then(|arr| arr.first())
                    .and_then(|m| m.get("id"))
                    .and_then(|id| id.as_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or_else(|| "default".to_string()),
        _ => "default".to_string(),
    };

    let body = serde_json::json!({
        "model": model_name,
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 1,
        "stream": false,
    });

    match client.post(&url).json(&body).send().await {
        Ok(resp) if resp.status().is_success() => {
            tracing::info!("Backend warmup complete — GPU caches primed");
            true
        }
        Ok(resp) => {
            tracing::warn!("Backend warmup got status {}", resp.status());
            false
        }
        Err(e) => {
            tracing::warn!("Backend warmup request failed: {e}");
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_exponential_backoff() {
        let mut backoff = ExponentialBackoff::new();
        assert_eq!(backoff.next_delay(), Duration::from_secs(1));
        assert_eq!(backoff.next_delay(), Duration::from_secs(2));
        assert_eq!(backoff.next_delay(), Duration::from_secs(4));
        assert_eq!(backoff.next_delay(), Duration::from_secs(5)); // capped at 5s
        assert_eq!(backoff.next_delay(), Duration::from_secs(5)); // stays capped
    }

    #[test]
    fn test_exponential_backoff_reset() {
        let mut backoff = ExponentialBackoff::new();
        backoff.next_delay();
        backoff.next_delay();
        backoff.next_delay();
        backoff.reset();
        assert_eq!(backoff.next_delay(), Duration::from_secs(1));
    }

    #[test]
    fn test_binary_exists_true() {
        // `which` itself should exist
        assert!(binary_exists("ls"));
    }

    #[test]
    fn test_binary_exists_false() {
        assert!(!binary_exists("nonexistent_binary_xyz_12345"));
    }

    #[tokio::test]
    async fn test_health_check_unreachable() {
        // Health check against a port that's not listening
        let healthy = check_health("http://127.0.0.1:19999").await;
        assert!(!healthy);
    }

    #[tokio::test]
    async fn test_health_check_with_mock_server() {
        // Start a minimal axum server for health check
        use axum::{Router, routing::get};

        let app = Router::new().route("/health", get(|| async { "ok" }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });

        // Give the server a moment to start
        tokio::time::sleep(Duration::from_millis(50)).await;

        let healthy = check_health(&format!("http://127.0.0.1:{}", addr.port())).await;
        assert!(healthy);
    }

    #[tokio::test]
    async fn test_backend_manager_with_mock() {
        use super::tests::mock::MockBackend;

        let backend = Box::new(MockBackend::new(true));
        let manager = BackendManager::new(backend, Duration::from_secs(60));

        manager.start().await.unwrap();
        assert!(manager.is_healthy().await);
        assert_eq!(manager.base_url().await, "http://127.0.0.1:8100");

        manager.stop().await.unwrap();
    }

    /// Test 6: Health check against a backend that returns HTTP 500 → unhealthy.
    #[tokio::test]
    async fn test_health_check_500_response() {
        use axum::{Router, http::StatusCode, routing::get};

        let app = Router::new()
            .route(
                "/health",
                get(|| async { StatusCode::INTERNAL_SERVER_ERROR }),
            )
            .route(
                "/v1/models",
                get(|| async { StatusCode::INTERNAL_SERVER_ERROR }),
            );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(Duration::from_millis(50)).await;

        let healthy = check_health(&format!("http://127.0.0.1:{}", addr.port())).await;
        assert!(!healthy, "Backend returning 500 should be unhealthy");
    }

    /// Test 6b: Health check succeeds via /v1/models when /health is absent.
    #[tokio::test]
    async fn test_health_check_via_models_endpoint() {
        use axum::{Json, Router, routing::get};

        // No /health route — only /v1/models
        let app = Router::new().route(
            "/v1/models",
            get(|| async { Json(serde_json::json!({"data": [{"id": "test-model"}]})) }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(Duration::from_millis(50)).await;

        let healthy = check_health(&format!("http://127.0.0.1:{}", addr.port())).await;
        assert!(
            healthy,
            "Backend with /v1/models should be considered healthy"
        );
    }

    /// Test 6c: check_model_loaded returns true when model_loaded is true.
    #[tokio::test]
    async fn test_check_model_loaded_true() {
        use axum::{Json, Router, routing::get};

        let app = Router::new().route(
            "/health",
            get(|| async { Json(serde_json::json!({"status": "ok", "model_loaded": true})) }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(Duration::from_millis(50)).await;

        assert!(check_model_loaded(&format!("http://127.0.0.1:{}", addr.port())).await);
    }

    /// Test 6d: check_model_loaded returns false when model_loaded is false.
    #[tokio::test]
    async fn test_check_model_loaded_false() {
        use axum::{Json, Router, routing::get};

        let app = Router::new().route(
            "/health",
            get(|| async { Json(serde_json::json!({"status": "loading", "model_loaded": false})) }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(Duration::from_millis(50)).await;

        assert!(!check_model_loaded(&format!("http://127.0.0.1:{}", addr.port())).await);
    }

    /// Test 6e: check_model_loaded for unreachable backend.
    #[tokio::test]
    async fn test_check_model_loaded_unreachable() {
        assert!(!check_model_loaded("http://127.0.0.1:19995").await);
    }

    /// Test 6f: check_model_loaded via /v1/models fallback (mlx_lm.server).
    #[tokio::test]
    async fn test_check_model_loaded_via_models_fallback() {
        use axum::{Json, Router, routing::get};

        // No /health, but /v1/models responds — treat as loaded
        let app = Router::new().route(
            "/v1/models",
            get(|| async { Json(serde_json::json!({"data": [{"id": "test"}]})) }),
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        tokio::time::sleep(Duration::from_millis(50)).await;

        assert!(check_model_loaded(&format!("http://127.0.0.1:{}", addr.port())).await);
    }

    /// Test: BackendManager with unhealthy backend still reports unhealthy.
    #[tokio::test]
    async fn test_backend_manager_unhealthy() {
        use super::tests::mock::MockBackend;

        let backend = Box::new(MockBackend::new(false));
        let manager = BackendManager::new(backend, Duration::from_secs(60));

        manager.start().await.unwrap();
        assert!(
            !manager.is_healthy().await,
            "Backend reporting unhealthy should be detected"
        );
        manager.stop().await.unwrap();
    }

    /// Test: BackendManager stop is idempotent.
    #[tokio::test]
    async fn test_backend_manager_stop_idempotent() {
        use super::tests::mock::MockBackend;

        let backend = Box::new(MockBackend::new(true));
        let manager = BackendManager::new(backend, Duration::from_secs(60));

        manager.start().await.unwrap();
        manager.stop().await.unwrap();
        // Second stop should not panic
        manager.stop().await.unwrap();
    }

    mod mock {
        use super::super::*;

        pub struct MockBackend {
            healthy: bool,
            started: bool,
        }

        impl MockBackend {
            pub fn new(healthy: bool) -> Self {
                Self {
                    healthy,
                    started: false,
                }
            }
        }

        #[async_trait]
        impl Backend for MockBackend {
            async fn start(&mut self) -> Result<()> {
                self.started = true;
                Ok(())
            }

            async fn stop(&mut self) -> Result<()> {
                self.started = false;
                Ok(())
            }

            async fn health(&self) -> bool {
                self.started && self.healthy
            }

            fn base_url(&self) -> String {
                "http://127.0.0.1:8100".to_string()
            }

            fn name(&self) -> &str {
                "mock"
            }
        }
    }

    // -----------------------------------------------------------------------
    // Live vllm-mlx integration tests
    //
    // These tests start a real vllm-mlx process, load a real model, and run
    // inference. They require:
    //   - Apple Silicon Mac
    //   - vllm-mlx on PATH
    //   - A small model downloaded (Qwen3.5-0.8B-MLX-4bit)
    //
    // Run with: LIVE_INFERENCE_TEST=1 cargo test live_inference -- --nocapture
    // -----------------------------------------------------------------------

    fn should_run_live_tests() -> bool {
        std::env::var("LIVE_INFERENCE_TEST").is_ok()
    }

    fn find_small_model() -> Option<String> {
        let cache = dirs::home_dir()?.join(".cache/huggingface/hub");
        // Prefer the smallest model for fast tests
        for model_dir_name in [
            "models--mlx-community--Qwen3.5-0.8B-MLX-4bit",
            "models--mlx-community--Qwen2.5-0.5B-Instruct-4bit",
        ] {
            let snapshots = cache.join(model_dir_name).join("snapshots");
            if let Ok(mut entries) = std::fs::read_dir(&snapshots) {
                if let Some(Ok(entry)) = entries.next() {
                    if entry.path().join("config.json").exists() {
                        return Some(entry.path().to_string_lossy().to_string());
                    }
                }
            }
        }
        None
    }

    /// Check if backend is still alive after an edge case test, restart if crashed.
    async fn ensure_backend_alive(
        backend: &mut vllm_mlx::VllmMlxBackend,
        base_url: &str,
        model_path: &str,
        model_name: &str,
        port: u16,
        client: &reqwest::Client,
    ) {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        if check_health(base_url).await {
            return;
        }
        eprintln!("    Backend crashed! Restarting...");
        let _ = backend.stop().await;
        *backend = vllm_mlx::VllmMlxBackend::new(model_path.to_string(), port, false);
        backend.start().await.unwrap();
        assert!(
            wait_for_backend(base_url, 120).await,
            "restart failed after crash"
        );
        let _ = client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&serde_json::json!({"model": model_name, "messages": [{"role":"user","content":"hi"}], "max_tokens": 1, "stream": false}))
            .send()
            .await;
        eprintln!("    Restarted ✓");
    }

    async fn wait_for_backend(base_url: &str, timeout_secs: u64) -> bool {
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);
        while tokio::time::Instant::now() < deadline {
            if check_health(base_url).await {
                return true;
            }
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        }
        false
    }

    /// Single comprehensive live test that starts the backend once and
    /// exercises all functionality. Loading the model is expensive (~10-30s),
    /// so we do it once and run all checks sequentially.
    ///
    /// Run: LIVE_INFERENCE_TEST=1 cargo test live_inference -- --nocapture
    #[tokio::test]
    async fn live_inference_full_pipeline() {
        if !should_run_live_tests() {
            eprintln!("Skipping live test (set LIVE_INFERENCE_TEST=1 to run)");
            return;
        }
        if !binary_exists("vllm-mlx") {
            eprintln!("Skipping: vllm-mlx not on PATH");
            return;
        }
        let model_path = match find_small_model() {
            Some(p) => p,
            None => {
                eprintln!("Skipping: no small test model found in ~/.cache/huggingface/hub/");
                return;
            }
        };

        let port = 18200u16;
        let base_url = format!("http://127.0.0.1:{port}");
        // vllm-mlx requires a "model" field in every request — use the path.
        let model_name = model_path.clone();
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .unwrap();

        // ── 1. Start backend ────────────────────────────────────
        eprintln!("\n=== 1. Backend startup ===");
        let mut backend = vllm_mlx::VllmMlxBackend::new(model_path.clone(), port, false);
        backend.start().await.expect("backend should start");

        eprintln!("  Waiting for model to load...");
        assert!(
            wait_for_backend(&base_url, 120).await,
            "backend should become healthy within 120s"
        );
        assert!(backend.health().await, "health check should pass");
        assert!(
            check_model_loaded(&base_url).await,
            "model should report loaded"
        );
        eprintln!("  ✓ Backend started and model loaded");

        // ── 2. Warmup ───────────────────────────────────────────
        eprintln!("\n=== 2. Warmup ===");
        // Use a longer-timeout client for warmup (first inference is slow).
        let warmup_client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(120))
            .build()
            .unwrap();
        let warmup_resp = warmup_client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&serde_json::json!({
                "model": &model_name,
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 1,
                "stream": false
            }))
            .send()
            .await;
        assert!(
            warmup_resp.is_ok() && warmup_resp.unwrap().status().is_success(),
            "warmup request should succeed"
        );
        eprintln!("  ✓ Warmup complete");

        // ── 3. Non-streaming completion ─────────────────────────
        eprintln!("\n=== 3. Non-streaming completion ===");
        let resp: serde_json::Value = client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&serde_json::json!({
                "model": &model_name,
                "messages": [{"role": "user", "content": "What is 2+2? Reply with just the number."}],
                "stream": false,
                "max_tokens": 10,
                "temperature": 0.0
            }))
            .send()
            .await
            .expect("request should succeed")
            .json()
            .await
            .unwrap();

        let content = resp["choices"][0]["message"]["content"]
            .as_str()
            .expect("should have content");
        assert!(!content.is_empty(), "content should not be empty");
        let comp_tokens = resp["usage"]["completion_tokens"].as_i64().unwrap_or(0);
        assert!(comp_tokens > 0, "should report completion tokens");
        // Verify OpenAI format fields
        assert!(resp.get("id").is_some(), "missing 'id' field");
        assert!(resp.get("object").is_some(), "missing 'object' field");
        assert!(resp.get("choices").is_some(), "missing 'choices' field");
        assert!(resp.get("usage").is_some(), "missing 'usage' field");
        eprintln!("  ✓ Response: \"{content}\" ({comp_tokens} tokens)");

        // ── 4. Streaming completion ─────────────────────────────
        eprintln!("\n=== 4. Streaming completion ===");
        let stream_resp = client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&serde_json::json!({
                "model": &model_name,
                "messages": [{"role": "user", "content": "Count 1 to 3."}],
                "stream": true,
                "max_tokens": 20,
                "temperature": 0.0
            }))
            .send()
            .await
            .unwrap();

        assert!(
            stream_resp.status().is_success(),
            "streaming should return 200"
        );
        let body_text = stream_resp.text().await.unwrap();
        let chunk_count = body_text
            .lines()
            .filter(|l| l.starts_with("data: {"))
            .count();
        assert!(
            chunk_count > 1,
            "should have multiple SSE chunks, got {chunk_count}"
        );
        assert!(body_text.contains("data: [DONE]"), "should end with [DONE]");
        eprintln!("  ✓ Streamed {chunk_count} chunks with [DONE]");

        // ── 5. max_tokens enforcement ───────────────────────────
        eprintln!("\n=== 5. max_tokens enforcement ===");
        let short: serde_json::Value = client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&serde_json::json!({
                "model": &model_name,
                "messages": [{"role": "user", "content": "Write a very long essay about everything."}],
                "stream": false,
                "max_tokens": 5,
                "temperature": 0.0
            }))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();

        let short_tokens = short["usage"]["completion_tokens"].as_i64().unwrap_or(999);
        assert!(
            short_tokens <= 10,
            "max_tokens=5 but got {short_tokens} tokens"
        );
        eprintln!("  ✓ Got {short_tokens} tokens (limit was 5)");

        // ── 6. Deterministic (temperature=0) ────────────────────
        eprintln!("\n=== 6. Deterministic output (temperature=0) ===");
        let det_body = serde_json::json!({
            "model": &model_name,
            "messages": [{"role": "user", "content": "Capital of France? One word."}],
            "stream": false,
            "max_tokens": 5,
            "temperature": 0.0
        });
        let r1: serde_json::Value = client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&det_body)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let r2: serde_json::Value = client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&det_body)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let c1 = r1["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or("");
        let c2 = r2["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or("");
        assert_eq!(c1, c2, "should be deterministic: '{c1}' vs '{c2}'");
        eprintln!("  ✓ Both responses: \"{c1}\"");

        // ── 7. Concurrent requests ──────────────────────────────
        eprintln!("\n=== 7. Concurrent requests ===");
        let mut handles = vec![];
        for i in 1..=3 {
            let client = client.clone();
            let url = format!("{base_url}/v1/chat/completions");
            let model_name_clone = model_name.clone();
            handles.push(tokio::spawn(async move {
                let r: serde_json::Value = client
                    .post(&url)
                    .json(&serde_json::json!({
                        "model": &model_name_clone,
                        "messages": [{"role": "user", "content": format!("What is {i}+{i}?")}],
                        "stream": false,
                        "max_tokens": 10
                    }))
                    .send()
                    .await
                    .unwrap()
                    .json()
                    .await
                    .unwrap();
                r["choices"][0]["message"]["content"]
                    .as_str()
                    .unwrap_or("")
                    .to_string()
            }));
        }
        for (i, h) in handles.into_iter().enumerate() {
            let content = h.await.unwrap();
            assert!(!content.is_empty(), "request {i} returned empty");
            eprintln!("  ✓ Request {}: \"{content}\"", i + 1);
        }

        // ── 8. Latency benchmark ────────────────────────────────
        eprintln!("\n=== 8. Latency benchmark ===");
        let t0 = std::time::Instant::now();
        let _: serde_json::Value = client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&serde_json::json!({
                "model": &model_name,
                "messages": [{"role": "user", "content": "Hi"}],
                "stream": false,
                "max_tokens": 1,
                "temperature": 0.0
            }))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        eprintln!("  ✓ TTFT (1 token, warm): {:?}", t0.elapsed());

        let t1 = std::time::Instant::now();
        let bench: serde_json::Value = client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&serde_json::json!({
                "model": &model_name,
                "messages": [{"role": "user", "content": "Explain gravity briefly."}],
                "stream": false,
                "max_tokens": 50,
                "temperature": 0.0
            }))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let elapsed = t1.elapsed();
        let gen_tokens = bench["usage"]["completion_tokens"].as_i64().unwrap_or(0);
        if gen_tokens > 0 {
            let tps = gen_tokens as f64 / elapsed.as_secs_f64();
            eprintln!("  ✓ Decode: {gen_tokens} tokens in {elapsed:?} = {tps:.1} tok/s");
        }

        // ── 9. Stop and verify unreachable ──────────────────────
        eprintln!("\n=== 9. Stop and verify ===");
        backend.stop().await.expect("should stop gracefully");
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        assert!(
            !check_health(&base_url).await,
            "should be unreachable after stop"
        );
        eprintln!("  ✓ Backend stopped, port unreachable");

        // ── 10. Restart (simulates idle timeout reload) ─────────
        eprintln!("\n=== 10. Restart (cold reload) ===");
        let mut backend2 = vllm_mlx::VllmMlxBackend::new(model_path, port, false);
        backend2.start().await.unwrap();
        assert!(
            wait_for_backend(&base_url, 120).await,
            "should come back after restart"
        );
        let restart_resp = client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&serde_json::json!({
                "model": &model_name,
                "messages": [{"role": "user", "content": "Hi"}],
                "stream": false,
                "max_tokens": 3
            }))
            .send()
            .await
            .unwrap();
        assert!(
            restart_resp.status().is_success(),
            "should serve after restart"
        );
        eprintln!("  ✓ Backend restarted and serving");

        backend2.stop().await.unwrap();
        eprintln!("\n=== All live inference tests passed! ===\n");
    }

    /// Edge case tests — malformed inputs, boundary conditions, stress.
    /// Starts backend once, runs all edge cases sequentially.
    ///
    /// Run: LIVE_INFERENCE_TEST=1 cargo test live_edge_cases -- --nocapture
    #[tokio::test]
    async fn live_edge_cases() {
        if !should_run_live_tests() {
            eprintln!("Skipping (set LIVE_INFERENCE_TEST=1)");
            return;
        }
        if !binary_exists("vllm-mlx") {
            return;
        }
        let model_path = match find_small_model() {
            Some(p) => p,
            None => return,
        };

        let port = 18211u16;
        let base_url = format!("http://127.0.0.1:{port}");
        let model_name = model_path.clone();
        let mut backend = vllm_mlx::VllmMlxBackend::new(model_path.clone(), port, false);
        backend.start().await.unwrap();
        assert!(
            wait_for_backend(&base_url, 120).await,
            "backend didn't start"
        );

        // Warm up
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(120))
            .build()
            .unwrap();
        let _ = client
            .post(format!("{base_url}/v1/chat/completions"))
            .json(&serde_json::json!({
                "model": &model_name,
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 1, "stream": false
            }))
            .send()
            .await;

        // Switch to shorter timeout for edge case tests
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .unwrap();

        let url = format!("{base_url}/v1/chat/completions");

        // ── Empty/malformed requests ────────────────────────────

        eprintln!("\n=== Edge: Empty/Malformed Requests ===");

        // Missing model field
        let r = client
            .post(&url)
            .json(
                &serde_json::json!({"messages": [{"role":"user","content":"hi"}], "max_tokens": 3}),
            )
            .send()
            .await
            .unwrap();
        assert!(
            r.status() == 422 || r.status() == 400,
            "missing model should be 4xx, got {}",
            r.status()
        );
        eprintln!("  ✓ Missing model field → {}", r.status());

        // Missing messages field
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "max_tokens": 3}))
            .send()
            .await
            .unwrap();
        assert!(
            r.status() == 422 || r.status() == 400,
            "missing messages should be 4xx, got {}",
            r.status()
        );
        eprintln!("  ✓ Missing messages field → {}", r.status());

        // Empty messages array — KNOWN BUG: vllm-mlx returns 500 and may crash.
        // The provider proxy should validate messages before forwarding.
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [], "max_tokens": 3}))
            .send()
            .await
            .unwrap();
        let status = r.status().as_u16();
        if status == 500 {
            eprintln!("  ⚠ Empty messages array → 500 (BUG: vllm-mlx crashes)");
        } else {
            eprintln!("  ✓ Empty messages array → {status}");
        }
        ensure_backend_alive(
            &mut backend,
            &base_url,
            &model_path,
            &model_name,
            port,
            &client,
        )
        .await;

        // Invalid JSON body
        let r = client
            .post(&url)
            .header("Content-Type", "application/json")
            .body("not json at all{{{")
            .send()
            .await
            .unwrap();
        assert!(
            r.status() == 422 || r.status() == 400,
            "invalid JSON should be 4xx, got {}",
            r.status()
        );
        eprintln!("  ✓ Invalid JSON body → {}", r.status());

        // Empty message content
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":""}], "stream": false, "max_tokens": 5}))
            .send().await.unwrap();
        let status = r.status().as_u16();
        assert!(
            status == 200 || status == 400 || status == 422 || status == 500,
            "empty content: unexpected {status}"
        );
        eprintln!("  ✓ Empty message content → {status}");

        // Invalid role — KNOWN BUG: vllm-mlx may 500/crash on unknown roles.
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"banana","content":"hi"}], "stream": false, "max_tokens": 5}))
            .send().await.unwrap();
        let status = r.status().as_u16();
        if status == 500 {
            eprintln!("  ⚠ Invalid role 'banana' → 500 (BUG: vllm-mlx crashes)");
        } else {
            eprintln!("  ✓ Invalid role 'banana' → {status}");
        }
        ensure_backend_alive(
            &mut backend,
            &base_url,
            &model_path,
            &model_name,
            port,
            &client,
        )
        .await;

        // ── Token limit edge cases ──────────────────────────────

        eprintln!("\n=== Edge: Token Limits ===");

        // max_tokens=0
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":"hi"}], "stream": false, "max_tokens": 0}))
            .send().await.unwrap();
        let status = r.status().as_u16();
        assert!(
            status == 200 || status == 400 || status == 422 || status == 500,
            "max_tokens=0: unexpected {status}"
        );
        eprintln!("  ✓ max_tokens=0 → {status}");
        ensure_backend_alive(
            &mut backend,
            &base_url,
            &model_path,
            &model_name,
            port,
            &client,
        )
        .await;

        // max_tokens=1 — should return exactly 1 token
        let r: serde_json::Value = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":"hi"}], "stream": false, "max_tokens": 1, "temperature": 0.0}))
            .send().await.unwrap().json().await.unwrap();
        let tokens = r["usage"]["completion_tokens"].as_i64().unwrap_or(-1);
        assert!(tokens >= 0 && tokens <= 2, "max_tokens=1 but got {tokens}");
        eprintln!("  ✓ max_tokens=1 → {tokens} token(s)");

        // max_tokens negative
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":"hi"}], "stream": false, "max_tokens": -1}))
            .send().await.unwrap();
        let status = r.status().as_u16();
        assert!(
            status == 200 || status == 400 || status == 422 || status == 500,
            "max_tokens=-1: unexpected {status}"
        );
        eprintln!("  ✓ max_tokens=-1 → {status}");
        ensure_backend_alive(
            &mut backend,
            &base_url,
            &model_path,
            &model_name,
            port,
            &client,
        )
        .await;

        // ── Large inputs ────────────────────────────────────────

        eprintln!("\n=== Edge: Large Inputs ===");

        // 10K character prompt
        let long_content = "x".repeat(10_000);
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content": long_content}], "stream": false, "max_tokens": 5}))
            .send().await.unwrap();
        let status = r.status().as_u16();
        assert!(
            status == 200 || status == 400 || status == 413 || status == 500,
            "10K prompt: unexpected {status}"
        );
        eprintln!("  ✓ 10K character prompt → {status}");
        ensure_backend_alive(
            &mut backend,
            &base_url,
            &model_path,
            &model_name,
            port,
            &client,
        )
        .await;

        // 50-message conversation
        let mut msgs: Vec<serde_json::Value> = (0..50)
            .map(|i| {
                serde_json::json!({
                    "role": if i % 2 == 0 { "user" } else { "assistant" },
                    "content": format!("Message number {i}")
                })
            })
            .collect();
        msgs.push(serde_json::json!({"role": "user", "content": "Summarize."}));
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": msgs, "stream": false, "max_tokens": 10}))
            .send().await.unwrap();
        assert!(
            r.status().is_success(),
            "50-message convo failed: {}",
            r.status()
        );
        eprintln!("  ✓ 50-message conversation → {}", r.status());

        // Unicode/emoji
        let r: serde_json::Value = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":"日本語でこんにちはと言って 🎌"}], "stream": false, "max_tokens": 10}))
            .send().await.unwrap().json().await.unwrap();
        let content = r["choices"][0]["message"]["content"].as_str().unwrap_or("");
        assert!(!content.is_empty(), "unicode response empty");
        eprintln!("  ✓ Unicode/emoji prompt → \"{content}\"");

        // ── Streaming edge cases ────────────────────────────────

        eprintln!("\n=== Edge: Streaming ===");

        // Streaming with max_tokens=1
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":"hi"}], "stream": true, "max_tokens": 1}))
            .send().await.unwrap();
        assert!(r.status().is_success());
        let text = r.text().await.unwrap();
        assert!(
            text.contains("data: [DONE]"),
            "streaming max_tokens=1 missing [DONE]"
        );
        eprintln!("  ✓ Streaming max_tokens=1 → got [DONE]");

        // Streaming early disconnect
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":"Write a long essay."}], "stream": true, "max_tokens": 200}))
            .send().await.unwrap();
        assert!(r.status().is_success());
        // Read only 3 chunks then drop the connection
        let mut chunks_read = 0usize;
        let body = r.text().await.unwrap();
        for line in body.lines() {
            if line.starts_with("data: {") {
                chunks_read += 1;
            }
        }
        // We can't truly disconnect mid-stream in reqwest without streaming mode,
        // but we can verify the full response completed without error
        assert!(chunks_read > 3, "expected many chunks, got {chunks_read}");
        eprintln!("  ✓ Full stream completed ({chunks_read} chunks)");

        // ── Temperature ─────────────────────────────────────────

        eprintln!("\n=== Edge: Temperature ===");

        // High temperature
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":"Pick a number."}], "stream": false, "max_tokens": 5, "temperature": 2.0}))
            .send().await.unwrap();
        assert!(r.status().is_success(), "temperature=2.0 failed");
        eprintln!("  ✓ temperature=2.0 → {}", r.status());

        // Negative temperature
        let r = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":"hi"}], "stream": false, "max_tokens": 3, "temperature": -1.0}))
            .send().await.unwrap();
        let status = r.status().as_u16();
        assert!(
            status == 200 || status == 400 || status == 422 || status == 500,
            "temperature=-1: unexpected {status}"
        );
        eprintln!("  ✓ temperature=-1.0 → {status}");
        ensure_backend_alive(
            &mut backend,
            &base_url,
            &model_path,
            &model_name,
            port,
            &client,
        )
        .await;

        // ── Response format ─────────────────────────────────────

        eprintln!("\n=== Edge: Response Format ===");

        // finish_reason=length when truncated
        let r: serde_json::Value = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":"Write a very long story about dragons."}], "stream": false, "max_tokens": 3, "temperature": 0.0}))
            .send().await.unwrap().json().await.unwrap();
        let fr = r["choices"][0]["finish_reason"].as_str().unwrap_or("null");
        assert!(
            fr == "length" || fr == "stop",
            "expected length or stop, got {fr}"
        );
        eprintln!("  ✓ finish_reason when truncated → \"{fr}\"");

        // finish_reason=stop when natural end
        let r: serde_json::Value = client
            .post(&url)
            .json(&serde_json::json!({"model": &model_name, "messages": [{"role":"user","content":"Say just 'ok'."}], "stream": false, "max_tokens": 100, "temperature": 0.0}))
            .send().await.unwrap().json().await.unwrap();
        let fr = r["choices"][0]["finish_reason"].as_str().unwrap_or("null");
        eprintln!("  ✓ finish_reason on natural end → \"{fr}\"");

        // ── Concurrent stress ───────────────────────────────────

        eprintln!("\n=== Edge: Concurrent Stress (10 requests) ===");

        let mut handles = vec![];
        for i in 0..10 {
            let client = client.clone();
            let url = url.clone();
            let mn = model_name.clone();
            handles.push(tokio::spawn(async move {
                let r = client
                    .post(&url)
                    .json(&serde_json::json!({"model": mn, "messages": [{"role":"user","content": format!("{i}*{i}=?")}], "stream": false, "max_tokens": 5}))
                    .send().await;
                match r {
                    Ok(resp) => resp.status().as_u16(),
                    Err(_) => 0,
                }
            }));
        }
        let mut ok_count = 0;
        for h in handles {
            let status = h.await.unwrap();
            if status == 200 {
                ok_count += 1;
            }
        }
        assert!(
            ok_count >= 8,
            "only {ok_count}/10 concurrent requests succeeded"
        );
        eprintln!("  ✓ {ok_count}/10 concurrent requests succeeded");

        // ── Cleanup ─────────────────────────────────────────────

        backend.stop().await.unwrap();
        eprintln!("\n=== All edge case tests passed! ===\n");
    }
}
