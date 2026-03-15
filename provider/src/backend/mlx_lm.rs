//! mlx-lm inference backend integration.
//!
//! mlx-lm is Apple's MLX framework-based inference server, run as
//! `python -m mlx_lm.server`. It provides a simpler alternative to
//! vllm-mlx without continuous batching support. This module manages
//! the Python process lifecycle: spawning, health checking, graceful
//! shutdown, and log forwarding.
//!
//! The backend exposes an OpenAI-compatible HTTP API on localhost.
//! It auto-detects whether `python3` or `python` is available on PATH.

use anyhow::{Context, Result};
use async_trait::async_trait;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

use super::{binary_exists, check_health, Backend};

/// Backend that runs `python -m mlx_lm.server`.
pub struct MlxLmBackend {
    model: String,
    port: u16,
    child: Option<Child>,
}

impl MlxLmBackend {
    pub fn new(model: String, port: u16) -> Self {
        Self {
            model,
            port,
            child: None,
        }
    }

    /// Build the command arguments for spawning mlx_lm.server.
    pub fn build_args(&self) -> Vec<String> {
        vec![
            "-m".to_string(),
            "mlx_lm.server".to_string(),
            "--model".to_string(),
            self.model.clone(),
            "--port".to_string(),
            self.port.to_string(),
        ]
    }

    fn spawn_log_forwarder(stream: impl tokio::io::AsyncRead + Unpin + Send + 'static, label: &'static str) {
        tokio::spawn(async move {
            let reader = BufReader::new(stream);
            let mut lines = reader.lines();
            while let Ok(Some(line)) = lines.next_line().await {
                match label {
                    "stdout" => tracing::info!(target: "mlx_lm", "{}", line),
                    "stderr" => tracing::warn!(target: "mlx_lm", "{}", line),
                    _ => tracing::debug!(target: "mlx_lm", "{}", line),
                }
            }
        });
    }
}

#[async_trait]
impl Backend for MlxLmBackend {
    async fn start(&mut self) -> Result<()> {
        if self.child.is_some() {
            anyhow::bail!("mlx_lm backend is already running");
        }

        if !binary_exists("python") && !binary_exists("python3") {
            anyhow::bail!(
                "Python not found on PATH. Install Python and mlx-lm: pip install mlx-lm"
            );
        }

        let python = if binary_exists("python3") {
            "python3"
        } else {
            "python"
        };

        let args = self.build_args();
        tracing::info!("Starting mlx_lm.server with: {} {:?}", python, args);

        let mut child = Command::new(python)
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("failed to spawn mlx_lm.server process")?;

        // Forward stdout/stderr to tracing
        if let Some(stdout) = child.stdout.take() {
            Self::spawn_log_forwarder(stdout, "stdout");
        }
        if let Some(stderr) = child.stderr.take() {
            Self::spawn_log_forwarder(stderr, "stderr");
        }

        self.child = Some(child);
        tracing::info!("mlx_lm.server started on port {}", self.port);
        Ok(())
    }

    async fn stop(&mut self) -> Result<()> {
        if let Some(mut child) = self.child.take() {
            tracing::info!("Stopping mlx_lm.server...");

            #[cfg(unix)]
            {
                if let Some(pid) = child.id() {
                    unsafe {
                        libc::kill(pid as i32, libc::SIGTERM);
                    }

                    match tokio::time::timeout(
                        std::time::Duration::from_secs(10),
                        child.wait(),
                    )
                    .await
                    {
                        Ok(Ok(status)) => {
                            tracing::info!("mlx_lm.server exited with status: {status}");
                            return Ok(());
                        }
                        Ok(Err(e)) => {
                            tracing::warn!("Error waiting for mlx_lm.server: {e}");
                        }
                        Err(_) => {
                            tracing::warn!(
                                "mlx_lm.server did not exit within 10s, sending SIGKILL"
                            );
                        }
                    }
                }
            }

            let _ = child.kill().await;
            let _ = child.wait().await;
            tracing::info!("mlx_lm.server stopped");
        }
        Ok(())
    }

    async fn health(&self) -> bool {
        check_health(&self.base_url()).await
    }

    fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    fn name(&self) -> &str {
        "mlx-lm"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_args() {
        let backend = MlxLmBackend::new("mlx-community/Qwen2.5-7B-4bit".into(), 8100);
        let args = backend.build_args();
        assert_eq!(
            args,
            vec![
                "-m",
                "mlx_lm.server",
                "--model",
                "mlx-community/Qwen2.5-7B-4bit",
                "--port",
                "8100"
            ]
        );
    }

    #[test]
    fn test_base_url() {
        let backend = MlxLmBackend::new("model".into(), 9002);
        assert_eq!(backend.base_url(), "http://127.0.0.1:9002");
    }

    #[test]
    fn test_name() {
        let backend = MlxLmBackend::new("model".into(), 8100);
        assert_eq!(backend.name(), "mlx-lm");
    }

    #[test]
    fn test_different_port() {
        let backend = MlxLmBackend::new("test-model".into(), 7777);
        assert_eq!(backend.base_url(), "http://127.0.0.1:7777");
        let args = backend.build_args();
        assert!(args.contains(&"7777".to_string()));
        assert!(args.contains(&"test-model".to_string()));
    }
}
