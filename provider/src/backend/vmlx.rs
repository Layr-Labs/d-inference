//! vmlx (MLX Studio engine) inference backend integration.
//!
//! vmlx is the inference engine powering MLX Studio. It exposes an
//! OpenAI-compatible HTTP API and is invoked per-model:
//!
//!   vmlx serve <model_path> --port <port>
//!
//! Install with: `uv tool install vmlx`  or  `pipx install vmlx`
//!
//! vmlx supports the same tool-call and reasoning parser flags as vllm-mlx,
//! plus continuous batching, prefix caching, paged KV cache, and speculative
//! decoding. It defaults to port 8000 but accepts `--port`.

use anyhow::{Context, Result};
use async_trait::async_trait;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

use super::{Backend, binary_exists, check_health};

/// Backend that runs `vmlx serve <model> --port <port>`.
pub struct VmlxBackend {
    model: String,
    port: u16,
    continuous_batching: bool,
    child: Option<Child>,
}

impl VmlxBackend {
    pub fn new(model: String, port: u16, continuous_batching: bool) -> Self {
        Self {
            model,
            port,
            continuous_batching,
            child: None,
        }
    }

    pub fn build_args(&self) -> Vec<String> {
        let mut args = vec![
            "serve".to_string(),
            self.model.clone(),
            "--port".to_string(),
            self.port.to_string(),
        ];

        if self.continuous_batching {
            args.push("--continuous-batching".to_string());
        }

        // Tool-call parser — mirrors the vllm-mlx selection logic.
        let model_lower = self.model.to_lowercase();
        let tool_parser = if model_lower.contains("gemma") {
            "none" // vmlx doesn't have a gemma4 parser; disable to avoid errors
        } else if model_lower.contains("deepseek") || model_lower.contains("trinity") {
            "deepseek"
        } else if model_lower.contains("qwen") {
            "qwen"
        } else if model_lower.contains("llama") {
            "llama"
        } else {
            "auto"
        };
        args.push("--enable-auto-tool-choice".to_string());
        args.push("--tool-call-parser".to_string());
        args.push(tool_parser.to_string());

        // Reasoning parser (extract <think>…</think> into reasoning_content).
        if let Some(parser) = reasoning_parser_for_model(&model_lower) {
            args.push("--reasoning-parser".to_string());
            args.push(parser.to_string());
        }

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
                    "stdout" => tracing::info!(target: "vmlx", "{}", line),
                    "stderr" => tracing::warn!(target: "vmlx", "{}", line),
                    _ => tracing::debug!(target: "vmlx", "{}", line),
                }
            }
        });
    }
}

/// Choose a reasoning parser for a model based on its name.
/// Returns None for models that don't output reasoning tags.
fn reasoning_parser_for_model(model_lower: &str) -> Option<&'static str> {
    if model_lower.contains("deepseek")
        || model_lower.contains("trinity")
        || model_lower.contains("minimax")
    {
        Some("deepseek_r1")
    } else if model_lower.contains("qwen") || model_lower.contains("gemma") {
        Some("qwen3")
    } else {
        None
    }
}

#[async_trait]
impl Backend for VmlxBackend {
    async fn start(&mut self) -> Result<()> {
        if self.child.is_some() {
            anyhow::bail!("vmlx backend is already running");
        }

        if !binary_exists("vmlx") {
            anyhow::bail!(
                "vmlx not found on PATH. Install it with: uv tool install vmlx  (or: pipx install vmlx)"
            );
        }

        let args = self.build_args();
        tracing::info!("Starting vmlx with args: {:?}", args);

        let mut child = Command::new("vmlx")
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("failed to spawn vmlx process")?;

        if let Some(stdout) = child.stdout.take() {
            Self::spawn_log_forwarder(stdout, "stdout");
        }
        if let Some(stderr) = child.stderr.take() {
            Self::spawn_log_forwarder(stderr, "stderr");
        }

        self.child = Some(child);
        tracing::info!("vmlx started on port {}", self.port);
        Ok(())
    }

    async fn stop(&mut self) -> Result<()> {
        if let Some(mut child) = self.child.take() {
            tracing::info!("Stopping vmlx...");

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
                            tracing::info!("vmlx exited with status: {status}");
                            return Ok(());
                        }
                        Ok(Err(e)) => {
                            tracing::warn!("Error waiting for vmlx: {e}");
                        }
                        Err(_) => {
                            tracing::warn!("vmlx did not exit within 10s, sending SIGKILL");
                        }
                    }
                }
            }

            let _ = child.kill().await;
            let _ = child.wait().await;
            tracing::info!("vmlx stopped");
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
        "vmlx"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_args_basic() {
        let backend = VmlxBackend::new("mlx-community/Qwen3-8B-4bit".into(), 8100, false);
        let args = backend.build_args();
        assert_eq!(args[0], "serve");
        assert_eq!(args[1], "mlx-community/Qwen3-8B-4bit");
        assert!(args.contains(&"--port".to_string()));
        assert!(args.contains(&"8100".to_string()));
        assert!(!args.contains(&"--continuous-batching".to_string()));
    }

    #[test]
    fn test_build_args_continuous_batching() {
        let backend = VmlxBackend::new("mlx-community/Qwen3-8B-4bit".into(), 8100, true);
        let args = backend.build_args();
        assert!(args.contains(&"--continuous-batching".to_string()));
    }

    #[test]
    fn test_build_args_qwen_parsers() {
        let backend = VmlxBackend::new("mlx-community/Qwen3-8B-4bit".into(), 8100, false);
        let args = backend.build_args();
        assert!(args.contains(&"--tool-call-parser".to_string()));
        assert!(args.contains(&"qwen".to_string()));
        assert!(args.contains(&"--reasoning-parser".to_string()));
        assert!(args.contains(&"qwen3".to_string()));
    }

    #[test]
    fn test_build_args_deepseek_parsers() {
        let backend = VmlxBackend::new("mlx-community/DeepSeek-R1-7B".into(), 8100, false);
        let args = backend.build_args();
        assert!(args.contains(&"deepseek".to_string()));
        assert!(args.contains(&"deepseek_r1".to_string()));
    }

    #[test]
    fn test_build_args_llama_no_reasoning() {
        let backend = VmlxBackend::new("mlx-community/Llama-3-8B".into(), 8100, false);
        let args = backend.build_args();
        assert!(args.contains(&"llama".to_string()));
        assert!(!args.contains(&"--reasoning-parser".to_string()));
    }

    #[test]
    fn test_base_url() {
        let backend = VmlxBackend::new("model".into(), 9001, false);
        assert_eq!(backend.base_url(), "http://127.0.0.1:9001");
    }

    #[test]
    fn test_name() {
        let backend = VmlxBackend::new("model".into(), 8100, false);
        assert_eq!(backend.name(), "vmlx");
    }
}
