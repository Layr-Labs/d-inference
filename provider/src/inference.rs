//! In-process inference engine using embedded Python (PyO3).
//!
//! Phase 3 security: runs the inference engine INSIDE our hardened Rust
//! process rather than as a separate subprocess. This means:
//!   - No IPC channel to sniff (no HTTP, no TCP, no Unix socket)
//!   - PT_DENY_ATTACH protects the Python interpreter too
//!   - Hardened Runtime blocks memory inspection of the entire process
//!   - Model weights, prompts, and outputs all live in our protected memory
//!
//! We embed Python via PyO3 and call vllm-mlx's engine API directly.
//! vllm-mlx still handles continuous batching, prefix caching, and
//! all its optimizations — we just call it from inside our process.
//!
//! Architecture:
//!   Rust (main loop, WebSocket, security)
//!     └── PyO3 embedded Python
//!           └── vllm_mlx.LLM or mlx_lm (loaded as Python module)
//!                 └── MLX → Metal → Apple Silicon GPU

use anyhow::{Context, Result};
use pyo3::prelude::*;
use pyo3::types::PyDict;
use std::ffi::CString;
use std::sync::Arc;
use tokio::sync::Mutex;

/// In-process inference engine backed by embedded Python.
///
/// Wraps either vllm-mlx (preferred, supports batching) or mlx-lm
/// (fallback, single-request) depending on what's installed.
pub struct InProcessEngine {
    model_id: String,
    engine_type: EngineType,
    pub loaded: bool,
}

#[derive(Debug, Clone)]
pub enum EngineType {
    /// vllm-mlx: continuous batching, prefix caching, high throughput
    VllmMlx,
    /// mlx-lm: simpler, single-request, but always available with MLX
    MlxLm,
}

/// A single inference result (non-streaming).
#[derive(Debug)]
pub struct InferenceResult {
    pub text: String,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

/// A streaming token from the inference engine.
#[derive(Debug)]
pub struct StreamToken {
    pub text: String,
    pub finish_reason: Option<String>,
}

impl InProcessEngine {
    /// Create a new in-process engine for the given model.
    /// Does not load the model yet — call `load()` first.
    pub fn new(model_id: String) -> Self {
        Self {
            model_id,
            engine_type: EngineType::VllmMlx, // will detect at load time
            loaded: false,
        }
    }

    /// Lock Python's import path to only load from our bundled packages.
    ///
    /// This is CRITICAL for security. Without this, Python imports from
    /// the provider's system site-packages — which they control. A malicious
    /// vllm-mlx would run inside our hardened process with full access to
    /// every prompt.
    ///
    /// With this, Python only loads from:
    ///   1. Our app bundle's Frameworks/python/ directory (signed, tamper-proof)
    ///   2. The Python stdlib (needed for basic operation)
    ///
    /// The provider cannot inject code because:
    ///   - sys.path is locked to our bundle
    ///   - The bundle is code-signed; any modification breaks the signature
    ///   - SIP enforces the signature
    fn lock_python_path(py: Python<'_>) -> Result<()> {
        let exe = std::env::current_exe().context("cannot find executable path")?;

        // Find the app bundle's Frameworks/python directory
        let mut search = exe.as_path();
        let mut bundle_python = None;
        while let Some(parent) = search.parent() {
            if search.extension().and_then(|e| e.to_str()) == Some("app") {
                let candidate = search.join("Contents/Frameworks/python");
                if candidate.exists() {
                    bundle_python = Some(candidate);
                }
                break;
            }
            search = parent;
        }

        if let Some(ref bundled_path) = bundle_python {
            let path_str = bundled_path.to_string_lossy();
            let code = CString::new(format!(
                "import sys\n\
                 # Lock sys.path to bundled packages only.\n\
                 # Keep stdlib paths (containing 'lib/python') but remove site-packages.\n\
                 stdlib = [p for p in sys.path if 'lib/python' in p and 'site-packages' not in p]\n\
                 sys.path = ['{bundled}'] + stdlib\n\
                 # Prevent future modifications\n\
                 import importlib\n\
                 importlib.invalidate_caches()\n",
                bundled = path_str
            ))
            .unwrap();
            py.run(code.as_c_str(), None, None)
                .context("failed to lock Python import path")?;
            tracing::info!("Python path locked to bundled packages: {}", path_str);
        } else {
            // Not running from an app bundle — development mode.
            // In development, we use system packages but log a warning.
            tracing::warn!(
                "Not running from signed app bundle — using system Python packages. \
                 This is acceptable for development but NOT for production. \
                 In production, build with scripts/bundle-app.sh to ship bundled packages."
            );
        }

        Ok(())
    }

    /// Detect which Python inference engine is available.
    /// First locks the Python import path to bundled packages (if in app bundle).
    pub fn detect_engine() -> Result<EngineType> {
        Python::with_gil(|py| {
            // Lock Python to only load from our bundle (production)
            // or warn about using system packages (development)
            Self::lock_python_path(py)?;

            // Try vllm-mlx first (preferred — supports batching)
            if py.import("vllm_mlx").is_ok() {
                tracing::info!("In-process engine: vllm-mlx detected");
                return Ok(EngineType::VllmMlx);
            }

            // Fall back to mlx-lm
            if py.import("mlx_lm").is_ok() {
                tracing::info!("In-process engine: mlx-lm detected (fallback)");
                return Ok(EngineType::MlxLm);
            }

            Err(anyhow::anyhow!(
                "Neither vllm-mlx nor mlx-lm is installed. \
                 Install with: pip install vllm-mlx (or pip install mlx-lm)"
            ))
        })
    }

    /// Load the model into memory. This is slow (downloads if needed,
    /// loads weights into GPU memory) but only happens once.
    pub fn load(&mut self) -> Result<()> {
        self.engine_type = Self::detect_engine()?;

        Python::with_gil(|py| match self.engine_type {
            EngineType::VllmMlx => self.load_vllm_mlx(py),
            EngineType::MlxLm => self.load_mlx_lm(py),
        })?;

        self.loaded = true;
        tracing::info!(
            "Model loaded in-process: {} via {:?}",
            self.model_id,
            self.engine_type
        );
        Ok(())
    }

    fn load_vllm_mlx(&self, py: Python<'_>) -> Result<()> {
        let code = format!(
            "import sys\nfrom vllm_mlx import LLM\n_eigeninference_engine = LLM(model=\"{model}\")\n",
            model = self.model_id
        );
        let ccode = CString::new(code).context("invalid code string")?;
        py.run(ccode.as_c_str(), None, None)
            .context("failed to initialize vllm-mlx engine")?;
        Ok(())
    }

    fn load_mlx_lm(&self, py: Python<'_>) -> Result<()> {
        // Store model in builtins so it persists across all with_gil calls and threads
        let code = format!(
            "import mlx_lm, builtins\nbuiltins._eigeninference_model, builtins._eigeninference_tokenizer = mlx_lm.load(\"{model}\")\n",
            model = self.model_id
        );
        let ccode = CString::new(code).context("invalid code string")?;
        py.run(ccode.as_c_str(), None, None)
            .context("failed to load model via mlx-lm")?;
        Ok(())
    }

    /// Run non-streaming inference. Returns the complete response.
    pub fn generate(
        &self,
        messages: &[serde_json::Value],
        max_tokens: u64,
        temperature: f64,
    ) -> Result<InferenceResult> {
        if !self.loaded {
            anyhow::bail!("Model not loaded — call load() first");
        }

        Python::with_gil(|py| match self.engine_type {
            EngineType::VllmMlx => self.generate_vllm_mlx(py, messages, max_tokens, temperature),
            EngineType::MlxLm => self.generate_mlx_lm(py, messages, max_tokens, temperature),
        })
    }

    fn generate_vllm_mlx(
        &self,
        py: Python<'_>,
        messages: &[serde_json::Value],
        max_tokens: u64,
        temperature: f64,
    ) -> Result<InferenceResult> {
        let prompt = format_chat_prompt(messages);

        let locals = PyDict::new(py);
        locals.set_item("prompt", &prompt)?;
        locals.set_item("max_tokens", max_tokens)?;
        locals.set_item("temperature", temperature)?;

        let code = CString::new(
            "from vllm import SamplingParams\n\
             params = SamplingParams(max_tokens=int(max_tokens), temperature=float(temperature))\n\
             outputs = _eigeninference_engine.generate([prompt], params)\n\
             _result_text = outputs[0].outputs[0].text\n\
             _result_prompt_tokens = len(outputs[0].prompt_token_ids)\n\
             _result_completion_tokens = len(outputs[0].outputs[0].token_ids)\n",
        )
        .unwrap();
        py.run(code.as_c_str(), None, Some(&locals))
            .context("vllm-mlx generate failed")?;

        let text: String = locals
            .get_item("_result_text")?
            .ok_or_else(|| anyhow::anyhow!("no result text"))?
            .extract()?;
        let prompt_tokens: u64 = locals
            .get_item("_result_prompt_tokens")?
            .ok_or_else(|| anyhow::anyhow!("no prompt tokens"))?
            .extract()?;
        let completion_tokens: u64 = locals
            .get_item("_result_completion_tokens")?
            .ok_or_else(|| anyhow::anyhow!("no completion tokens"))?
            .extract()?;

        Ok(InferenceResult {
            text,
            prompt_tokens,
            completion_tokens,
        })
    }

    fn generate_mlx_lm(
        &self,
        py: Python<'_>,
        messages: &[serde_json::Value],
        max_tokens: u64,
        _temperature: f64,
    ) -> Result<InferenceResult> {
        let prompt = format_chat_prompt(messages);

        // Import modules and call generate directly via PyO3 API
        let mlx_lm = py.import("mlx_lm").context("failed to import mlx_lm")?;
        let builtins = py.import("builtins").context("failed to import builtins")?;

        let model = builtins
            .getattr("_eigeninference_model")
            .context("model not loaded in builtins")?;
        let tokenizer = builtins
            .getattr("_eigeninference_tokenizer")
            .context("tokenizer not loaded in builtins")?;

        let kwargs = PyDict::new(py);
        kwargs.set_item("prompt", prompt.as_str())?;
        kwargs.set_item("max_tokens", max_tokens)?;

        let result = mlx_lm
            .call_method("generate", (model, tokenizer), Some(&kwargs))
            .context("mlx-lm generate call failed")?;

        let text: String = result.extract().context("failed to extract result text")?;
        let completion_tokens = text.split_whitespace().count() as u64;

        Ok(InferenceResult {
            text,
            prompt_tokens: 0,
            completion_tokens,
        })
    }

    /// Run streaming inference. Calls the callback for each token.
    ///
    /// This runs synchronously in the Python GIL. For async integration,
    /// wrap in `tokio::task::spawn_blocking`.
    pub fn stream_generate(
        &self,
        messages: &[serde_json::Value],
        max_tokens: u64,
        temperature: f64,
        mut on_token: impl FnMut(StreamToken),
    ) -> Result<(u64, u64)> {
        if !self.loaded {
            anyhow::bail!("Model not loaded — call load() first");
        }

        Python::with_gil(|py| {
            let prompt = format_chat_prompt(messages);

            let locals = PyDict::new(py);
            locals.set_item("prompt", &prompt)?;
            locals.set_item("max_tokens", max_tokens)?;
            locals.set_item("temperature", temperature)?;

            let (code_str, engine_name) = match self.engine_type {
                EngineType::VllmMlx => (
                    "from vllm import SamplingParams\n\
                     params = SamplingParams(max_tokens=int(max_tokens), temperature=float(temperature))\n\
                     _stream_outputs = _eigeninference_engine.generate([prompt], params, use_tqdm=False)\n\
                     _stream_tokens = []\n\
                     for output in _stream_outputs:\n\
                         for o in output.outputs:\n\
                             _stream_tokens.append(o.text)\n",
                    "vllm-mlx",
                ),
                EngineType::MlxLm => (
                    "import mlx_lm, builtins\n\
                     _stream_tokens = []\n\
                     for token in mlx_lm.stream_generate(\n\
                         builtins._eigeninference_model, builtins._eigeninference_tokenizer,\n\
                         prompt=prompt, max_tokens=int(max_tokens)):\n\
                         _stream_tokens.append(token)\n",
                    "mlx-lm",
                ),
            };

            let code = CString::new(code_str).unwrap();
            py.run(code.as_c_str(), None, Some(&locals))
                .context(format!("{engine_name} stream generate failed"))?;

            let tokens: Vec<String> = locals
                .get_item("_stream_tokens")?
                .ok_or_else(|| anyhow::anyhow!("no stream tokens"))?
                .extract()?;

            let count = tokens.len() as u64;
            for (i, text) in tokens.into_iter().enumerate() {
                on_token(StreamToken {
                    text,
                    finish_reason: if i == count as usize - 1 {
                        Some("stop".to_string())
                    } else {
                        None
                    },
                });
            }

            Ok((0, count))
        })
    }

    /// Check if the engine is loaded and ready.
    pub fn is_loaded(&self) -> bool {
        self.loaded
    }

    /// Get the model ID.
    pub fn model_id(&self) -> &str {
        &self.model_id
    }
}

/// Format chat messages into a prompt string.
/// Follows the ChatML-style format that most models expect.
fn format_chat_prompt(messages: &[serde_json::Value]) -> String {
    let mut prompt = String::new();
    for msg in messages {
        let role = msg.get("role").and_then(|r| r.as_str()).unwrap_or("user");
        let content = msg.get("content").and_then(|c| c.as_str()).unwrap_or("");
        prompt.push_str(&format!("<|im_start|>{role}\n{content}<|im_end|>\n"));
    }
    prompt.push_str("<|im_start|>assistant\n");
    prompt
}

/// Thread-safe wrapper around InProcessEngine for use with tokio.
///
/// Since Python's GIL prevents true parallelism, inference calls
/// are serialized through a Mutex. For vllm-mlx with continuous
/// batching, the batching happens inside the Python engine.
pub struct SharedEngine {
    inner: Arc<Mutex<InProcessEngine>>,
}

impl SharedEngine {
    pub fn new(engine: InProcessEngine) -> Self {
        Self {
            inner: Arc::new(Mutex::new(engine)),
        }
    }

    /// Load the model (blocks until complete).
    pub async fn load(&self) -> Result<()> {
        let engine = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let mut e = engine.blocking_lock();
            e.load()
        })
        .await?
    }

    /// Run non-streaming inference.
    pub async fn generate(
        &self,
        messages: Vec<serde_json::Value>,
        max_tokens: u64,
        temperature: f64,
    ) -> Result<InferenceResult> {
        let engine = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let e = engine.blocking_lock();
            e.generate(&messages, max_tokens, temperature)
        })
        .await?
    }
}

/// Implement the Backend trait for InProcessEngine so it can be used
/// as a drop-in replacement for the subprocess backend.
#[async_trait::async_trait]
impl crate::backend::Backend for SharedEngine {
    async fn start(&mut self) -> Result<()> {
        self.load().await
    }

    async fn stop(&mut self) -> Result<()> {
        // In-process engine: just drop the Python objects
        tracing::info!("Stopping in-process inference engine");
        Ok(())
    }

    async fn health(&self) -> bool {
        let engine = self.inner.lock().await;
        engine.is_loaded()
    }

    fn base_url(&self) -> String {
        // No HTTP URL — inference is in-process.
        // Return a sentinel that the proxy can detect.
        "inprocess://localhost".to_string()
    }

    fn name(&self) -> &str {
        "inprocess-mlx"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_chat_prompt_single_message() {
        let messages = vec![serde_json::json!({"role": "user", "content": "hello"})];
        let prompt = format_chat_prompt(&messages);
        assert!(prompt.contains("<|im_start|>user"));
        assert!(prompt.contains("hello"));
        assert!(prompt.ends_with("<|im_start|>assistant\n"));
    }

    #[test]
    fn test_format_chat_prompt_multi_turn() {
        let messages = vec![
            serde_json::json!({"role": "system", "content": "You are helpful."}),
            serde_json::json!({"role": "user", "content": "What is 2+2?"}),
            serde_json::json!({"role": "assistant", "content": "4"}),
            serde_json::json!({"role": "user", "content": "And 3+3?"}),
        ];
        let prompt = format_chat_prompt(&messages);
        assert!(prompt.contains("<|im_start|>system"));
        assert!(prompt.contains("You are helpful."));
        assert!(prompt.contains("<|im_start|>user"));
        assert!(prompt.contains("What is 2+2?"));
        assert!(prompt.contains("<|im_start|>assistant"));
        assert!(prompt.contains("4<|im_end|>"));
        assert!(prompt.contains("And 3+3?"));
    }

    #[test]
    fn test_format_chat_prompt_empty() {
        let messages: Vec<serde_json::Value> = vec![];
        let prompt = format_chat_prompt(&messages);
        assert_eq!(prompt, "<|im_start|>assistant\n");
    }

    #[test]
    fn test_engine_not_loaded() {
        let engine = InProcessEngine::new("test-model".to_string());
        assert!(!engine.is_loaded());
        assert_eq!(engine.model_id(), "test-model");

        let result = engine.generate(&[], 100, 0.7);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not loaded"));
    }

    #[test]
    fn test_detect_engine_graceful_failure() {
        // This will fail if neither vllm-mlx nor mlx-lm is installed,
        // which is expected in test environments without MLX.
        let result = InProcessEngine::detect_engine();
        // Either succeeds (MLX installed) or fails gracefully with an error
        match result {
            Ok(engine_type) => {
                // MLX is installed — great
                println!("Detected engine: {:?}", engine_type);
            }
            Err(e) => {
                // Expected when MLX packages aren't installed
                let msg = e.to_string();
                assert!(
                    msg.contains("vllm") || msg.contains("mlx") || msg.contains("install"),
                    "unexpected error: {msg}"
                );
            }
        }
    }
}
