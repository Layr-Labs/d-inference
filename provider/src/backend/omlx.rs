//! omlx inference backend integration.
//!
//! omlx is a Python-based MLX inference engine for Apple Silicon that serves
//! multiple models from a directory simultaneously with continuous batching
//! and tiered KV caching. It exposes an OpenAI-compatible HTTP API.
//! Install with: `pip install omlx` or `brew install omlx`.
//!
//! Unlike vllm-mlx (one process per model), omlx is a single server that
//! manages a whole model directory:
//!
//!   omlx serve --model-dir <dir>
//!
//! The port defaults to 8000 and is overridden via the `OMLX_PORT` env var.
//!
//! The `model_dir` should contain model subdirectories in a flat or two-level
//! `<owner>/<model-name>/` layout.

use anyhow::{Context, Result};
use async_trait::async_trait;
use std::path::PathBuf;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

use super::{Backend, binary_exists, check_health};

/// Backend that runs `omlx serve --model-dir <model_dir>`.
///
/// A single omlx process serves all models found in `model_dir`, making it
/// a multi-model backend unlike the single-model vllm-mlx approach.
pub struct OmlxBackend {
    /// Directory containing model subdirectories to serve.
    model_dir: PathBuf,
    /// Port for the HTTP API. Set via `OMLX_PORT` env var when spawning.
    port: u16,
    child: Option<Child>,
}

impl OmlxBackend {
    pub fn new(model_dir: PathBuf, port: u16) -> Self {
        Self {
            model_dir,
            port,
            child: None,
        }
    }

    pub fn build_args(&self) -> Vec<String> {
        vec![
            "serve".to_string(),
            "--model-dir".to_string(),
            self.model_dir.to_string_lossy().to_string(),
        ]
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
                    "stdout" => tracing::info!(target: "omlx", "{}", line),
                    "stderr" => tracing::warn!(target: "omlx", "{}", line),
                    _ => tracing::debug!(target: "omlx", "{}", line),
                }
            }
        });
    }
}

#[async_trait]
impl Backend for OmlxBackend {
    async fn start(&mut self) -> Result<()> {
        if self.child.is_some() {
            anyhow::bail!("omlx backend is already running");
        }

        if !binary_exists("omlx") {
            anyhow::bail!(
                "omlx not found on PATH. Install it with: pip install omlx  (or: brew install omlx)"
            );
        }

        let args = self.build_args();
        tracing::info!("Starting omlx with args: {:?}", args);

        let mut child = Command::new("omlx")
            .args(&args)
            // omlx reads the port from OMLX_PORT; if not set it defaults to 8000.
            .env("OMLX_PORT", self.port.to_string())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("failed to spawn omlx process")?;

        if let Some(stdout) = child.stdout.take() {
            Self::spawn_log_forwarder(stdout, "stdout");
        }
        if let Some(stderr) = child.stderr.take() {
            Self::spawn_log_forwarder(stderr, "stderr");
        }

        self.child = Some(child);
        tracing::info!("omlx started on port {}", self.port);
        Ok(())
    }

    async fn stop(&mut self) -> Result<()> {
        if let Some(mut child) = self.child.take() {
            tracing::info!("Stopping omlx...");

            #[cfg(unix)]
            {
                if let Some(pid) = child.id() {
                    unsafe {
                        libc::kill(pid as i32, libc::SIGTERM);
                    }

                    match tokio::time::timeout(std::time::Duration::from_secs(10), child.wait())
                        .await
                    {
                        Ok(Ok(status)) => {
                            tracing::info!("omlx exited with status: {status}");
                            return Ok(());
                        }
                        Ok(Err(e)) => {
                            tracing::warn!("Error waiting for omlx: {e}");
                        }
                        Err(_) => {
                            tracing::warn!("omlx did not exit within 10s, sending SIGKILL");
                        }
                    }
                }
            }

            let _ = child.kill().await;
            let _ = child.wait().await;
            tracing::info!("omlx stopped");
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
        "omlx"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_args() {
        let backend = OmlxBackend::new(PathBuf::from("/home/user/models"), 8000);
        let args = backend.build_args();
        assert_eq!(args[0], "serve");
        assert_eq!(args[1], "--model-dir");
        assert_eq!(args[2], "/home/user/models");
        assert!(!args.contains(&"--port".to_string()), "port is via OMLX_PORT env var");
    }

    #[test]
    fn test_base_url() {
        let backend = OmlxBackend::new(PathBuf::from("/models"), 8000);
        assert_eq!(backend.base_url(), "http://127.0.0.1:8000");
    }

    #[test]
    fn test_name() {
        let backend = OmlxBackend::new(PathBuf::from("/models"), 8000);
        assert_eq!(backend.name(), "omlx");
    }
}
