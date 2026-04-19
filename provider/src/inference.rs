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
use sha2::{Digest, Sha256};
use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::Mutex;

/// In-process inference engine backed by embedded Python.
///
/// Wraps either vllm-mlx (preferred, supports batching) or mlx-lm
/// (fallback, single-request) depending on what's installed.
pub struct InProcessEngine {
    model_id: String,
    cache_key: String,
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

/// A raw completions-style response produced by the in-process engine.
#[derive(Debug)]
pub struct CompletionJsonResult {
    pub response_json: serde_json::Value,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

/// A streaming token from the inference engine.
#[derive(Debug)]
pub struct StreamToken {
    pub text: String,
    pub finish_reason: Option<String>,
}

const VLLM_ENGINE_STORE: &str = "_eigeninference_vllm_engines";
const MLX_ENGINE_STORE: &str = "_eigeninference_mlx_engines";

fn engine_cache_key_for(model_id: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(model_id.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn python_runtime_roots(exe: &Path, home_dir: Option<&Path>) -> Vec<PathBuf> {
    let mut roots = Vec::new();

    // App bundle layouts.
    let mut search = exe;
    while let Some(parent) = search.parent() {
        if search.extension().and_then(|e| e.to_str()) == Some("app") {
            for rel in [
                "Contents/python",
                "Contents/Frameworks/python",
                "Contents/Resources/python",
            ] {
                let candidate = search.join(rel);
                if candidate.exists() {
                    roots.push(candidate);
                }
            }
            break;
        }
        search = parent;
    }

    // Shared CLI runtime installed by install.sh.
    if let Some(home) = home_dir {
        let candidate = home.join(".darkbloom/python");
        if candidate.exists() {
            roots.push(candidate);
        }
    }

    roots
}

impl InProcessEngine {
    /// Create a new in-process engine for the given model.
    /// Does not load the model yet — call `load()` first.
    pub fn new(model_id: String) -> Self {
        Self {
            cache_key: engine_cache_key_for(&model_id),
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
    ///   1. Our signed app bundle runtime (preferred)
    ///   2. The verified `~/.darkbloom/python` runtime installed by the CLI
    ///
    /// The provider cannot inject code because:
    ///   - sys.path is locked to our approved runtime roots
    ///   - app bundle runtimes are code-signed
    ///   - CLI runtimes are hash-verified against the coordinator manifest
    fn lock_python_path(py: Python<'_>) -> Result<()> {
        let exe = std::env::current_exe().context("cannot find executable path")?;

        let allowed_roots = python_runtime_roots(&exe, dirs::home_dir().as_deref());
        if !allowed_roots.is_empty() {
            let allowed_roots: Vec<String> = allowed_roots
                .iter()
                .map(|p| p.to_string_lossy().to_string())
                .collect();
            let allowed_json =
                serde_json::to_string(&allowed_roots).context("failed to encode runtime roots")?;
            let code = CString::new(format!(
                "import importlib\n\
                 import os\n\
                 import sys\n\
                 allowed = [os.path.realpath(p) for p in {allowed_json}]\n\
                 locked = []\n\
                 for root in allowed:\n\
                     lib = os.path.join(root, 'lib', 'python3.12')\n\
                     site = os.path.join(lib, 'site-packages')\n\
                     dyn = os.path.join(lib, 'lib-dynload')\n\
                     for candidate in (site, dyn, lib):\n\
                         if os.path.exists(candidate) and candidate not in locked:\n\
                             locked.append(candidate)\n\
                 for path in sys.path:\n\
                     real = os.path.realpath(path or '.')\n\
                     if any(real == root or real.startswith(root + os.sep) for root in allowed):\n\
                         if path not in locked:\n\
                             locked.append(path)\n\
                 sys.path = locked\n\
                 importlib.invalidate_caches()\n",
                allowed_json = allowed_json
            ))
            .unwrap();
            py.run(code.as_c_str(), None, None)
                .context("failed to lock Python import path")?;
            tracing::info!("Python path locked to runtime roots: {:?}", allowed_roots);
        } else {
            // Development fallback only.
            tracing::warn!(
                "No approved Python runtime roots found — using system Python packages. \
                 This is acceptable for development but NOT for production."
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

    /// Drop the Python-side model objects so GPU memory can be reclaimed.
    pub fn unload(&mut self) -> Result<()> {
        if !self.loaded {
            return Ok(());
        }

        Python::with_gil(|py| match self.engine_type {
            EngineType::VllmMlx => self.unload_vllm_mlx(py),
            EngineType::MlxLm => self.unload_mlx_lm(py),
        })?;

        self.loaded = false;
        tracing::info!("Model unloaded in-process: {}", self.model_id);
        Ok(())
    }

    fn load_vllm_mlx(&self, py: Python<'_>) -> Result<()> {
        let model = serde_json::to_string(&self.model_id).context("invalid model path")?;
        let cache_key = serde_json::to_string(&self.cache_key).context("invalid cache key")?;
        let code = format!(
            "import builtins\n\
             from vllm_mlx import LLM\n\
             if not hasattr(builtins, '{store}'):\n\
                 builtins.{store} = {{}}\n\
             builtins.{store}[{cache_key}] = LLM(model={model})\n",
            store = VLLM_ENGINE_STORE,
            cache_key = cache_key,
            model = model
        );
        let ccode = CString::new(code).context("invalid code string")?;
        py.run(ccode.as_c_str(), None, None)
            .context("failed to initialize vllm-mlx engine")?;
        Ok(())
    }

    fn load_mlx_lm(&self, py: Python<'_>) -> Result<()> {
        let model = serde_json::to_string(&self.model_id).context("invalid model path")?;
        let cache_key = serde_json::to_string(&self.cache_key).context("invalid cache key")?;
        let code = format!(
            "import builtins\n\
             import mlx_lm\n\
             if not hasattr(builtins, '{store}'):\n\
                 builtins.{store} = {{}}\n\
             builtins.{store}[{cache_key}] = mlx_lm.load({model})\n",
            store = MLX_ENGINE_STORE,
            cache_key = cache_key,
            model = model
        );
        let ccode = CString::new(code).context("invalid code string")?;
        py.run(ccode.as_c_str(), None, None)
            .context("failed to load model via mlx-lm")?;
        Ok(())
    }

    fn unload_vllm_mlx(&self, py: Python<'_>) -> Result<()> {
        let cache_key = serde_json::to_string(&self.cache_key).context("invalid cache key")?;
        let code = format!(
            "import builtins, gc\n\
             store = getattr(builtins, '{store}', None)\n\
             if isinstance(store, dict):\n\
                 store.pop({cache_key}, None)\n\
             gc.collect()\n",
            store = VLLM_ENGINE_STORE,
            cache_key = cache_key
        );
        let ccode = CString::new(code).context("invalid code string")?;
        py.run(ccode.as_c_str(), None, None)
            .context("failed to unload vllm-mlx engine")?;
        Ok(())
    }

    fn unload_mlx_lm(&self, py: Python<'_>) -> Result<()> {
        let cache_key = serde_json::to_string(&self.cache_key).context("invalid cache key")?;
        let code = format!(
            "import builtins, gc\n\
             store = getattr(builtins, '{store}', None)\n\
             if isinstance(store, dict):\n\
                 store.pop({cache_key}, None)\n\
             gc.collect()\n",
            store = MLX_ENGINE_STORE,
            cache_key = cache_key
        );
        let ccode = CString::new(code).context("invalid code string")?;
        py.run(ccode.as_c_str(), None, None)
            .context("failed to unload mlx-lm engine")?;
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

    /// Run a raw completions-style request, preserving prompt/echo/logprobs.
    pub fn generate_completion_json(
        &self,
        model_name: &str,
        prompt: &str,
        max_tokens: u64,
        temperature: f64,
        echo: bool,
        logprobs: u64,
    ) -> Result<CompletionJsonResult> {
        if !self.loaded {
            anyhow::bail!("Model not loaded — call load() first");
        }

        Python::with_gil(|py| match self.engine_type {
            EngineType::VllmMlx => self.generate_completion_json_vllm_mlx(
                py,
                model_name,
                prompt,
                max_tokens,
                temperature,
                echo,
                logprobs,
            ),
            EngineType::MlxLm => anyhow::bail!(
                "mlx-lm backend does not support raw completions logprobs/echo"
            ),
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
        locals.set_item("engine_key", &self.cache_key)?;
        locals.set_item("prompt", &prompt)?;
        locals.set_item("max_tokens", max_tokens)?;
        locals.set_item("temperature", temperature)?;

        let code = CString::new(
            "import builtins\n\
             from vllm import SamplingParams\n\
             params = SamplingParams(max_tokens=int(max_tokens), temperature=float(temperature))\n\
             engine = builtins._eigeninference_vllm_engines[engine_key]\n\
             outputs = engine.generate([prompt], params)\n\
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

    fn generate_completion_json_vllm_mlx(
        &self,
        py: Python<'_>,
        model_name: &str,
        prompt: &str,
        max_tokens: u64,
        temperature: f64,
        echo: bool,
        logprobs: u64,
    ) -> Result<CompletionJsonResult> {
        let locals = PyDict::new(py);
        locals.set_item("engine_key", &self.cache_key)?;
        locals.set_item("model_name", model_name)?;
        locals.set_item("prompt", prompt)?;
        locals.set_item("max_tokens", max_tokens)?;
        locals.set_item(
            "engine_max_tokens",
            if echo && max_tokens == 0 { 1 } else { max_tokens },
        )?;
        locals.set_item("temperature", temperature)?;
        locals.set_item("echo", echo)?;
        locals.set_item("logprobs_k", logprobs)?;

        let code = CString::new(
            "import builtins\n\
             import json\n\
             from vllm import SamplingParams\n\
             engine = builtins._eigeninference_vllm_engines[engine_key]\n\
             tokenizer = engine.get_tokenizer()\n\
             num_logprobs = int(logprobs_k)\n\
             params = SamplingParams(\n\
                 max_tokens=int(engine_max_tokens),\n\
                 temperature=float(temperature),\n\
                 logprobs=(num_logprobs if num_logprobs > 0 else None),\n\
                 prompt_logprobs=(num_logprobs if bool(echo) and num_logprobs > 0 else None),\n\
             )\n\
             outputs = engine.generate([prompt], params, use_tqdm=False)\n\
             if not outputs or not outputs[0].outputs:\n\
                 raise RuntimeError('no completion outputs')\n\
             request_output = outputs[0]\n\
             completion = request_output.outputs[0]\n\
             prompt_ids = list(request_output.prompt_token_ids or [])\n\
             prompt_logprobs = list(request_output.prompt_logprobs) if request_output.prompt_logprobs is not None else []\n\
             completion_ids = list(completion.token_ids or [])\n\
             completion_logprobs = list(completion.logprobs) if completion.logprobs is not None else []\n\
             trim_completion_tokens = 0 if bool(echo) and int(max_tokens) == 0 else len(completion_ids)\n\
             completion_text = completion.text if trim_completion_tokens == len(completion_ids) else ''\n\
             def decode_token(token_id, position):\n\
                 if position is not None and token_id in position:\n\
                     decoded = getattr(position[token_id], 'decoded_token', None)\n\
                     if decoded is not None:\n\
                         return decoded\n\
                 return tokenizer.decode([token_id])\n\
             def serialize_position(token_id, position):\n\
                 token = decode_token(token_id, position)\n\
                 chosen_logprob = None\n\
                 top_logprobs = None\n\
                 if position is not None:\n\
                     top_logprobs = {}\n\
                     for cand_id, cand_lp in position.items():\n\
                         decoded = getattr(cand_lp, 'decoded_token', None)\n\
                         if decoded is None:\n\
                             decoded = tokenizer.decode([cand_id])\n\
                         top_logprobs[decoded] = cand_lp.logprob\n\
                         if cand_id == token_id:\n\
                             chosen_logprob = cand_lp.logprob\n\
                 return token, chosen_logprob, top_logprobs\n\
             tokens = []\n\
             token_logprobs = []\n\
             top_logprobs = []\n\
             text_offset = []\n\
             offset = 0\n\
             if bool(echo):\n\
                 for idx, token_id in enumerate(prompt_ids):\n\
                     position = prompt_logprobs[idx] if idx < len(prompt_logprobs) else None\n\
                     token, chosen, top = serialize_position(token_id, position)\n\
                     tokens.append(token)\n\
                     token_logprobs.append(chosen)\n\
                     top_logprobs.append(top)\n\
                     text_offset.append(offset)\n\
                     offset += len(token.encode('utf-8'))\n\
             for idx, token_id in enumerate(completion_ids[:trim_completion_tokens]):\n\
                 position = completion_logprobs[idx] if idx < len(completion_logprobs) else None\n\
                 token, chosen, top = serialize_position(token_id, position)\n\
                 tokens.append(token)\n\
                 token_logprobs.append(chosen)\n\
                 top_logprobs.append(top)\n\
                 text_offset.append(offset)\n\
                 offset += len(token.encode('utf-8'))\n\
             finish_reason = completion.finish_reason or 'stop'\n\
             if bool(echo) and int(max_tokens) == 0:\n\
                 finish_reason = 'stop'\n\
             response = {\n\
                 'id': f'cmpl-{engine_key[:12]}',\n\
                 'object': 'text_completion',\n\
                 'model': model_name,\n\
                 'choices': [{\n\
                     'index': 0,\n\
                     'text': (prompt + completion_text) if bool(echo) else completion_text,\n\
                     'finish_reason': finish_reason,\n\
                     'logprobs': {\n\
                         'tokens': tokens,\n\
                         'token_logprobs': token_logprobs,\n\
                         'top_logprobs': top_logprobs,\n\
                         'text_offset': text_offset,\n\
                     } if num_logprobs > 0 else None,\n\
                 }],\n\
                 'usage': {\n\
                     'prompt_tokens': len(prompt_ids),\n\
                     'completion_tokens': trim_completion_tokens,\n\
                     'total_tokens': len(prompt_ids) + trim_completion_tokens,\n\
                 },\n\
             }\n\
             _result_json = json.dumps(response)\n",
        )
        .unwrap();
        py.run(code.as_c_str(), None, Some(&locals))
            .context("vllm-mlx raw completion failed")?;

        let raw_json: String = locals
            .get_item("_result_json")?
            .ok_or_else(|| anyhow::anyhow!("no completion json"))?
            .extract()?;
        let response_json: serde_json::Value =
            serde_json::from_str(&raw_json).context("failed to parse completion json")?;
        let prompt_tokens = response_json
            .get("usage")
            .and_then(|u| u.get("prompt_tokens"))
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        let completion_tokens = response_json
            .get("usage")
            .and_then(|u| u.get("completion_tokens"))
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        Ok(CompletionJsonResult {
            response_json,
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
        let engines = builtins
            .getattr(MLX_ENGINE_STORE)
            .context("mlx-lm engine store not initialized")?;
        let entry = engines
            .get_item(self.cache_key.as_str())
            .context("mlx-lm engine not loaded for model")?;
        let (model, tokenizer): (PyObject, PyObject) = entry.extract()?;

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
            locals.set_item("engine_key", &self.cache_key)?;
            locals.set_item("prompt", &prompt)?;
            locals.set_item("max_tokens", max_tokens)?;
            locals.set_item("temperature", temperature)?;

            let (code_str, engine_name) = match self.engine_type {
                EngineType::VllmMlx => (
                    "import builtins\n\
                     from vllm import SamplingParams\n\
                     params = SamplingParams(max_tokens=int(max_tokens), temperature=float(temperature))\n\
                     engine = builtins._eigeninference_vllm_engines[engine_key]\n\
                     _stream_outputs = engine.generate([prompt], params, use_tqdm=False)\n\
                     _stream_tokens = []\n\
                     for output in _stream_outputs:\n\
                         for o in output.outputs:\n\
                             _stream_tokens.append(o.text)\n",
                    "vllm-mlx",
                ),
                EngineType::MlxLm => (
                    "import mlx_lm, builtins\n\
                     _engine = builtins._eigeninference_mlx_engines[engine_key]\n\
                     _model = _engine[0]\n\
                     _tokenizer = _engine[1]\n\
                     _stream_tokens = []\n\
                     for token in mlx_lm.stream_generate(\n\
                         _model, _tokenizer,\n\
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

    /// Run a raw completions-style request preserving prompt/echo/logprobs.
    pub async fn generate_completion_json(
        &self,
        model_name: String,
        prompt: String,
        max_tokens: u64,
        temperature: f64,
        echo: bool,
        logprobs: u64,
    ) -> Result<CompletionJsonResult> {
        let engine = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let e = engine.blocking_lock();
            e.generate_completion_json(
                model_name.as_str(),
                prompt.as_str(),
                max_tokens,
                temperature,
                echo,
                logprobs,
            )
        })
        .await?
    }

    /// Run streaming inference and collect the emitted tokens.
    pub async fn stream_generate(
        &self,
        messages: Vec<serde_json::Value>,
        max_tokens: u64,
        temperature: f64,
    ) -> Result<(u64, u64, Vec<StreamToken>)> {
        let engine = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let e = engine.blocking_lock();
            let mut tokens = Vec::new();
            let (prompt_tokens, completion_tokens) =
                e.stream_generate(&messages, max_tokens, temperature, |token| {
                    tokens.push(token);
                })?;
            Ok((prompt_tokens, completion_tokens, tokens))
        })
        .await?
    }

    /// Unload the model so GPU memory can be reclaimed.
    pub async fn unload(&self) -> Result<()> {
        let engine = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let mut e = engine.blocking_lock();
            e.unload()
        })
        .await?
    }

    /// Report whether the underlying engine is loaded.
    pub async fn is_loaded(&self) -> bool {
        let engine = self.inner.lock().await;
        engine.is_loaded()
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
        self.unload().await
    }

    async fn health(&self) -> bool {
        self.is_loaded().await
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
    fn test_engine_cache_key_stable_and_unique() {
        let a = engine_cache_key_for("model-a");
        let b = engine_cache_key_for("model-a");
        let c = engine_cache_key_for("model-b");

        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(a.len(), 64);
    }

    #[test]
    fn test_python_runtime_roots_discovers_bundle_and_home_runtime() {
        let tmp = tempfile::tempdir().unwrap();
        let app_root = tmp.path().join("EigenInference.app");
        let exe = app_root.join("Contents/MacOS/darkbloom");
        let frameworks_python = app_root.join("Contents/Frameworks/python");
        let resources_python = app_root.join("Contents/Resources/python");
        let home = tmp.path().join("home");
        let home_python = home.join(".darkbloom/python");

        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        std::fs::write(&exe, b"").unwrap();
        std::fs::create_dir_all(&frameworks_python).unwrap();
        std::fs::create_dir_all(&resources_python).unwrap();
        std::fs::create_dir_all(&home_python).unwrap();

        let roots = python_runtime_roots(&exe, Some(home.as_path()));

        assert_eq!(
            roots,
            vec![frameworks_python, resources_python, home_python]
        );
    }

    #[test]
    fn test_python_runtime_roots_falls_back_to_home_runtime() {
        let tmp = tempfile::tempdir().unwrap();
        let exe = tmp.path().join("bin/darkbloom");
        let home = tmp.path().join("home");
        let home_python = home.join(".darkbloom/python");

        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        std::fs::write(&exe, b"").unwrap();
        std::fs::create_dir_all(&home_python).unwrap();

        let roots = python_runtime_roots(&exe, Some(home.as_path()));

        assert_eq!(roots, vec![home_python]);
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
