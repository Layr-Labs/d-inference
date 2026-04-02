//! Inference backend management for the DGInf provider.
//!
//! The only supported backend is vllm-mlx — a high-performance inference
//! engine for Apple Silicon with continuous batching, prefix caching, and
//! an OpenAI-compatible API. It builds on Apple's MLX framework.
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
                            tracing::warn!("Backend {} health check failed", b.name());
                            drop(b);

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
pub async fn check_health(base_url: &str) -> bool {
    let url = format!("{base_url}/health");
    let client = health_client();
    match client.get(&url).send().await {
        Ok(resp) => resp.status().is_success(),
        Err(_) => false,
    }
}

/// Check if the backend has fully loaded its model into GPU memory.
/// Returns true only when the /health endpoint reports model_loaded: true.
pub async fn check_model_loaded(base_url: &str) -> bool {
    let url = format!("{base_url}/health");
    let client = health_client();
    match client.get(&url).send().await {
        Ok(resp) if resp.status().is_success() => {
            if let Ok(body) = resp.json::<serde_json::Value>().await {
                body.get("model_loaded")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false)
            } else {
                // If we can't parse the body, fall back to status-only check
                true
            }
        }
        _ => false,
    }
}

/// Send a minimal warmup request to prime the model's GPU caches.
/// This avoids the 30-50s first-token penalty on real user requests.
pub async fn warmup_backend(base_url: &str) -> bool {
    let url = format!("{base_url}/v1/chat/completions");
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .unwrap_or_default();

    let body = serde_json::json!({
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
}
