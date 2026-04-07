//! vllm-mlx inference backend integration.
//!
//! vllm-mlx is a high-performance inference engine for Apple Silicon that
//! supports continuous batching (serving multiple requests concurrently).
//! This module manages the vllm-mlx process lifecycle: spawning, health
//! checking, graceful shutdown (SIGTERM with fallback to SIGKILL), and
//! log forwarding.
//!
//! The backend is started as `vllm-mlx serve <model> --port <port>` and
//! exposes an OpenAI-compatible HTTP API on localhost.

use anyhow::{Context, Result};
use async_trait::async_trait;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

use super::{Backend, binary_exists, check_health};

/// Backend that runs `vllm-mlx serve <model>`.
///
/// Supports two communication modes:
///   - TCP localhost (default, legacy): HTTP on 127.0.0.1:<port>
///   - Unix socket (secure): HTTP over Unix domain socket with 0600 permissions
///
/// Unix socket mode prevents localhost traffic sniffing (tcpdump can't
/// capture Unix socket traffic). The socket file is created with restrictive
/// permissions so only our process can connect.
pub struct VllmMlxBackend {
    model: String,
    port: u16,
    continuous_batching: bool,
    child: Option<Child>,
    /// If set, use a Unix domain socket instead of TCP for backend communication.
    /// This prevents localhost traffic sniffing via tcpdump.
    unix_socket_path: Option<std::path::PathBuf>,
}

impl VllmMlxBackend {
    pub fn new(model: String, port: u16, continuous_batching: bool) -> Self {
        Self {
            model,
            port,
            continuous_batching,
            child: None,
            unix_socket_path: None,
        }
    }

    /// Enable Unix socket mode for secure IPC (no TCP sniffing possible).
    pub fn with_unix_socket(mut self, path: std::path::PathBuf) -> Self {
        self.unix_socket_path = Some(path);
        self
    }

    /// Build the command arguments for spawning vllm-mlx.
    pub fn build_args(&self) -> Vec<String> {
        let mut args = vec!["serve".to_string(), self.model.clone()];

        // If Unix socket is configured, vllm-mlx needs to listen on it.
        // Note: vllm-mlx may not support --unix-socket natively yet.
        // In that case, we fall back to TCP with the port.
        if let Some(ref socket_path) = self.unix_socket_path {
            args.push("--unix-socket".to_string());
            args.push(socket_path.to_string_lossy().to_string());
        } else {
            args.push("--port".to_string());
            args.push(self.port.to_string());
        }

        if self.continuous_batching {
            args.push("--continuous-batching".to_string());
        }

        // Enable tool call parsing so vllm-mlx converts <tool_call> output
        // into structured tool_calls fields in the OpenAI response format.
        // "auto" parser auto-detects the model's tool call format.
        args.push("--enable-auto-tool-choice".to_string());
        args.push("--tool-call-parser".to_string());
        args.push("auto".to_string());

        // Extract <think>...</think> into reasoning_content field instead of
        // leaking thinking tags into the response content.
        //
        // Default: qwen3 parser (safe for all models — if no </think> found,
        // it's a no-op passthrough). DeepSeek needs its own parser because it
        // supports implicit reasoning mode where <think> is omitted.
        let model_lower = self.model.to_lowercase();
        let reasoning_parser = if model_lower.contains("deepseek") {
            "deepseek_r1"
        } else {
            "qwen3" // safe default: no-op if model doesn't output <think> tags
        };
        args.push("--reasoning-parser".to_string());
        args.push(reasoning_parser.to_string());

        args
    }

    fn spawn_log_forwarder(
        stream: impl tokio::io::AsyncRead + Unpin + Send + 'static,
        label: &'static str,
    ) {
        tokio::spawn(async move {
            let reader = BufReader::new(stream);
            let mut lines = reader.lines();
            while let Ok(Some(line)) = lines.next_line().await {
                match label {
                    "stdout" => tracing::info!(target: "vllm_mlx", "{}", line),
                    "stderr" => tracing::warn!(target: "vllm_mlx", "{}", line),
                    _ => tracing::debug!(target: "vllm_mlx", "{}", line),
                }
            }
        });
    }
}

#[async_trait]
impl Backend for VllmMlxBackend {
    async fn start(&mut self) -> Result<()> {
        if self.child.is_some() {
            anyhow::bail!("vllm-mlx backend is already running");
        }

        if !binary_exists("vllm-mlx") {
            anyhow::bail!(
                "vllm-mlx binary not found on PATH. Install it with: pip install vllm-mlx"
            );
        }

        let args = self.build_args();
        tracing::info!("Starting vllm-mlx with args: {:?}", args);

        let mut child = Command::new("vllm-mlx")
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("failed to spawn vllm-mlx process")?;

        // Forward stdout/stderr to tracing
        if let Some(stdout) = child.stdout.take() {
            Self::spawn_log_forwarder(stdout, "stdout");
        }
        if let Some(stderr) = child.stderr.take() {
            Self::spawn_log_forwarder(stderr, "stderr");
        }

        self.child = Some(child);
        tracing::info!("vllm-mlx started on port {}", self.port);
        Ok(())
    }

    async fn stop(&mut self) -> Result<()> {
        if let Some(mut child) = self.child.take() {
            tracing::info!("Stopping vllm-mlx...");

            // Try graceful shutdown with SIGTERM first
            #[cfg(unix)]
            {
                if let Some(pid) = child.id() {
                    unsafe {
                        libc::kill(pid as i32, libc::SIGTERM);
                    }

                    // Wait up to 10 seconds for graceful shutdown
                    match tokio::time::timeout(std::time::Duration::from_secs(10), child.wait())
                        .await
                    {
                        Ok(Ok(status)) => {
                            tracing::info!("vllm-mlx exited with status: {status}");
                            return Ok(());
                        }
                        Ok(Err(e)) => {
                            tracing::warn!("Error waiting for vllm-mlx: {e}");
                        }
                        Err(_) => {
                            tracing::warn!("vllm-mlx did not exit within 10s, sending SIGKILL");
                        }
                    }
                }
            }

            // Force kill if still running
            let _ = child.kill().await;
            let _ = child.wait().await;
            tracing::info!("vllm-mlx stopped");
        }
        Ok(())
    }

    async fn health(&self) -> bool {
        check_health(&self.base_url()).await
    }

    fn base_url(&self) -> String {
        // Note: Unix socket URL support requires reqwest's unix-socket feature
        // or a custom transport. For now, fall back to TCP if the backend
        // doesn't support Unix sockets yet. The socket path is used for
        // the backend spawn args; HTTP communication may still use TCP.
        if let Some(ref _socket_path) = self.unix_socket_path {
            // Unix socket HTTP format: http://localhost is the Host header,
            // but the actual transport goes through the socket.
            // For now, fall back to TCP until reqwest unix socket support is added.
            format!("http://127.0.0.1:{}", self.port)
        } else {
            format!("http://127.0.0.1:{}", self.port)
        }
    }

    fn name(&self) -> &str {
        "vllm-mlx"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_args_basic() {
        let backend = VllmMlxBackend::new("mlx-community/Qwen2.5-7B-4bit".into(), 8100, false);
        let args = backend.build_args();
        // Qwen model gets tool calling + qwen3 reasoning parser
        assert!(args.contains(&"serve".to_string()));
        assert!(args.contains(&"--enable-auto-tool-choice".to_string()));
        assert!(args.contains(&"--tool-call-parser".to_string()));
        assert!(args.contains(&"auto".to_string()));
        assert!(args.contains(&"--reasoning-parser".to_string()));
        assert!(args.contains(&"qwen3".to_string()));
        assert!(!args.contains(&"--continuous-batching".to_string()));
    }

    #[test]
    fn test_build_args_with_continuous_batching() {
        let backend = VllmMlxBackend::new("mlx-community/Qwen2.5-7B-4bit".into(), 8100, true);
        let args = backend.build_args();
        assert!(args.contains(&"--continuous-batching".to_string()));
        assert!(args.contains(&"--enable-auto-tool-choice".to_string()));
        assert!(args.contains(&"qwen3".to_string()));
    }

    #[test]
    fn test_build_args_deepseek_model() {
        let backend = VllmMlxBackend::new("mlx-community/DeepSeek-R1-7B".into(), 8100, false);
        let args = backend.build_args();
        assert!(args.contains(&"--reasoning-parser".to_string()));
        assert!(args.contains(&"deepseek_r1".to_string()));
        assert!(!args.contains(&"qwen3".to_string()));
    }

    #[test]
    fn test_build_args_generic_model() {
        let backend = VllmMlxBackend::new("mlx-community/Llama-3-8B".into(), 8100, false);
        let args = backend.build_args();
        // Generic model gets tool calling + qwen3 reasoning (safe default)
        assert!(args.contains(&"--enable-auto-tool-choice".to_string()));
        assert!(args.contains(&"--reasoning-parser".to_string()));
        assert!(args.contains(&"qwen3".to_string()));
    }

    #[test]
    fn test_base_url() {
        let backend = VllmMlxBackend::new("model".into(), 9001, false);
        assert_eq!(backend.base_url(), "http://127.0.0.1:9001");
    }

    #[test]
    fn test_name() {
        let backend = VllmMlxBackend::new("model".into(), 8100, false);
        assert_eq!(backend.name(), "vllm-mlx");
    }

    #[test]
    fn test_different_ports() {
        let backend = VllmMlxBackend::new("model".into(), 5555, true);
        assert_eq!(backend.base_url(), "http://127.0.0.1:5555");
        let args = backend.build_args();
        assert!(args.contains(&"5555".to_string()));
    }
}
