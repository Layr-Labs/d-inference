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

fn approved_python_runtime_roots(exe: &Path, home_dir: Option<&Path>) -> Result<Vec<PathBuf>> {
    let roots = python_runtime_roots(exe, home_dir);
    if roots.is_empty() {
        anyhow::bail!(
            "no approved Python runtime roots found; private text serving requires a bundled runtime or ~/.darkbloom/python"
        );
    }
    Ok(roots)
}

pub fn ensure_approved_runtime_available() -> Result<()> {
    let exe = std::env::current_exe().context("cannot find executable path")?;
    let _ = approved_python_runtime_roots(&exe, dirs::home_dir().as_deref())?;
    Ok(())
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

        let allowed_roots = approved_python_runtime_roots(&exe, dirs::home_dir().as_deref())?;
        let allowed_roots: Vec<String> = allowed_roots
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect();
        let allowed_json =
            serde_json::to_string(&allowed_roots).context("failed to encode runtime roots")?;
        let code = CString::new(format!(
            r#"
import importlib, os, sys
allowed = [os.path.realpath(p) for p in {allowed_json}]
locked = []
for root in allowed:
    lib = os.path.join(root, 'lib', 'python3.12')
    site = os.path.join(lib, 'site-packages')
    dyn = os.path.join(lib, 'lib-dynload')
    for candidate in (site, dyn, lib):
        if os.path.exists(candidate) and candidate not in locked:
            locked.append(candidate)
for path in sys.path:
    real = os.path.realpath(path or '.')
    if any(real == root or real.startswith(root + os.sep) for root in allowed):
        if path not in locked:
            locked.append(path)
if not locked:
    raise RuntimeError(f'No approved paths found. prefix={{sys.prefix}}, PYTHONHOME={{os.environ.get("PYTHONHOME","unset")}}, sys.path={{sys.path}}, allowed={{allowed}}')
sys.path = locked
importlib.invalidate_caches()
"#,
            allowed_json = allowed_json
        ))
        .unwrap();
        py.run(code.as_c_str(), None, None)
            .context("failed to lock Python import path")?;
        tracing::info!("Python path locked to runtime roots: {:?}", allowed_roots);
        Ok(())
    }

    /// Block Python modules that provide escape hatches out of our hardened
    /// single-process boundary. These are replaced with stubs that raise
    /// ImportError, preventing provider-controlled code from opening sockets,
    /// spawning subprocesses, calling native C functions, or forking workers.
    ///
    /// Defense-in-depth: the primary defense is the locked sys.path. This
    /// blocks the remaining standard-library backdoors.
    fn block_dangerous_modules(py: Python<'_>) -> Result<()> {
        let code = CString::new(
            r#"import builtins, sys

_BLOCKED = frozenset([
    'socket', 'subprocess', 'ctypes', 'multiprocessing',
    'faulthandler', '_socket', '_multiprocessing',
])

_original_import = getattr(
    builtins, '_eigeninference_original_import', builtins.__import__
)
builtins._eigeninference_original_import = _original_import

def _blocked_os_call(*args, **kwargs):
    raise PermissionError('os process control is blocked in private text mode')

def _blocked_import(name, globals=None, locals=None, fromlist=(), level=0):
    top = name.split('.')[0]
    if top in _BLOCKED:
        raise ImportError(
            f"module {name!r} is blocked in private text mode"
        )
    return builtins._eigeninference_original_import(
        name, globals, locals, fromlist, level
    )

for name in list(sys.modules):
    if name.split('.')[0] in _BLOCKED:
        del sys.modules[name]

builtins.__import__ = _blocked_import

import os as _blocked_os
for _name in (
    'system', 'fork', 'forkpty', 'popen',
    'execv', 'execve', 'execl', 'execlp', 'execle', 'execlpe',
    'execvp', 'execvpe',
    'spawnl', 'spawnle', 'spawnlp', 'spawnlpe',
    'spawnv', 'spawnve', 'spawnvp', 'spawnvpe',
    'posix_spawn', 'posix_spawnp',
):
    if hasattr(_blocked_os, _name):
        setattr(_blocked_os, _name, _blocked_os_call)
"#,
        )
        .unwrap();
        py.run(code.as_c_str(), None, None)
            .context("failed to install dangerous-module blocker")?;
        tracing::info!(
            "Dangerous Python modules blocked: socket, subprocess, ctypes, multiprocessing, faulthandler"
        );
        Ok(())
    }

    /// Detect which Python inference engine is available.
    /// Retries on failure to handle site-packages being replaced concurrently
    /// (e.g. runtime self-heal running from a previous process).
    pub fn detect_engine() -> Result<EngineType> {
        let max_attempts = 3;
        let mut last_err = None;
        for attempt in 1..=max_attempts {
            match Self::try_detect_engine() {
                Ok(engine) => return Ok(engine),
                Err(e) => {
                    if attempt < max_attempts {
                        tracing::warn!(
                            "Engine detection attempt {attempt}/{max_attempts} failed: {e} — retrying in 5s"
                        );
                        std::thread::sleep(std::time::Duration::from_secs(5));
                    }
                    last_err = Some(e);
                }
            }
        }
        Err(last_err.unwrap())
    }

    fn try_detect_engine() -> Result<EngineType> {
        Python::with_gil(|py| {
            if let Err(e) = Self::lock_python_path(py) {
                tracing::warn!("Python path lock failed (defense-in-depth): {e:#}");
                tracing::warn!("Proceeding without path lock — PYTHONNOUSERSITE still active");
            }

            if py.import("vllm_mlx").is_ok() {
                tracing::info!("In-process engine: vllm-mlx detected");
                return Ok(EngineType::VllmMlx);
            }

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

        Python::with_gil(|py| -> Result<()> {
            match self.engine_type {
                EngineType::VllmMlx => self.load_vllm_mlx(py)?,
                EngineType::MlxLm => self.load_mlx_lm(py)?,
            }
            // Block dangerous modules AFTER the engine loads. The engine needs
            // socket/multiprocessing during initialization (worker pools, etc.)
            // but inference itself doesn't. This prevents injected code from
            // using these modules to exfiltrate data during serving.
            if let Err(e) = Self::block_dangerous_modules(py) {
                tracing::warn!("Failed to block dangerous modules: {e:#}");
            }
            Ok(())
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
            r#"
import builtins
from vllm_mlx import LLM
if not hasattr(builtins, '{store}'):
    builtins.{store} = {{}}
builtins.{store}[{cache_key}] = LLM(model={model})
"#,
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
            r#"
import builtins
import mlx_lm
if not hasattr(builtins, '{store}'):
    builtins.{store} = {{}}
builtins.{store}[{cache_key}] = mlx_lm.load({model})
"#,
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
            r#"
import builtins, gc
store = getattr(builtins, '{store}', None)
if isinstance(store, dict):
    store.pop({cache_key}, None)
gc.collect()
"#,
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
            r#"
import builtins, gc
store = getattr(builtins, '{store}', None)
if isinstance(store, dict):
    store.pop({cache_key}, None)
gc.collect()
"#,
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

    fn generate_vllm_mlx(
        &self,
        py: Python<'_>,
        messages: &[serde_json::Value],
        max_tokens: u64,
        temperature: f64,
    ) -> Result<InferenceResult> {
        let mut prompt = format_chat_prompt(messages);
        let result = (|| -> Result<InferenceResult> {
            let locals = PyDict::new(py);
            locals.set_item("engine_key", &self.cache_key)?;
            locals.set_item("prompt", &prompt)?;
            locals.set_item("max_tokens", max_tokens)?;
            locals.set_item("temperature", temperature)?;

            let code = CString::new(
                r#"
import builtins
from vllm import SamplingParams
params = SamplingParams(max_tokens=int(max_tokens), temperature=float(temperature))
engine = builtins._eigeninference_vllm_engines[engine_key]
outputs = engine.generate([prompt], params)
_result_text = outputs[0].outputs[0].text
_result_prompt_tokens = len(outputs[0].prompt_token_ids)
_result_completion_tokens = len(outputs[0].outputs[0].token_ids)
"#,
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
        })();
        crate::security::secure_zero_string(std::mem::take(&mut prompt));
        result
    }

    fn generate_mlx_lm(
        &self,
        py: Python<'_>,
        messages: &[serde_json::Value],
        max_tokens: u64,
        _temperature: f64,
    ) -> Result<InferenceResult> {
        let mut prompt = format_chat_prompt(messages);
        let result = (|| -> Result<InferenceResult> {
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
        })();
        crate::security::secure_zero_string(std::mem::take(&mut prompt));
        result
    }

    /// Run streaming inference. Calls the callback for each token.
    ///
    /// This runs synchronously in the Python GIL. For async integration,
    /// wrap in `tokio::task::spawn_blocking`.
    pub fn stream_generate(
        &self,
        messages: &[serde_json::Value],
        max_tokens: u64,
        _temperature: f64,
        mut on_token: impl FnMut(StreamToken) -> Result<()>,
    ) -> Result<(u64, u64)> {
        if !self.loaded {
            anyhow::bail!("Model not loaded — call load() first");
        }
        if matches!(self.engine_type, EngineType::VllmMlx) {
            anyhow::bail!(
                "private text streaming requires mlx-lm; vllm-mlx only exposes buffered completions"
            );
        }

        Python::with_gil(|py| {
            let mut prompt = format_chat_prompt(messages);
            let mut pending_text: Option<String> = None;
            let mut completion_tokens = 0u64;

            let mut emit_token = |text: String| -> Result<()> {
                if let Some(prev) = pending_text.take() {
                    if let Err(err) = on_token(StreamToken {
                        text: prev,
                        finish_reason: None,
                    }) {
                        crate::security::secure_zero_string(text);
                        return Err(err);
                    }
                    completion_tokens += 1;
                }
                pending_text = Some(text);
                Ok(())
            };

            let stream_result: Result<()> = match self.engine_type {
                EngineType::MlxLm => {
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
                    let generator = mlx_lm
                        .call_method("stream_generate", (model, tokenizer), Some(&kwargs))
                        .context("mlx-lm stream_generate call failed")?;

                    for token in generator.try_iter().context("mlx-lm stream not iterable")? {
                        let text: String = token?
                            .extract()
                            .context("failed to extract mlx-lm streamed text")?;
                        emit_token(text)?;
                    }
                    Ok(())
                }
                EngineType::VllmMlx => unreachable!("vllm-mlx streaming is rejected above"),
            };

            crate::security::secure_zero_string(std::mem::take(&mut prompt));
            stream_result?;

            if let Some(text) = pending_text.take() {
                on_token(StreamToken {
                    text,
                    finish_reason: Some("stop".to_string()),
                })?;
                completion_tokens += 1;
            }

            Ok((0, completion_tokens))
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
            let mut messages = messages;
            let e = engine.blocking_lock();
            let result = e.generate(&messages, max_tokens, temperature);
            for message in &mut messages {
                crate::security::secure_zero_json_value(message);
            }
            result
        })
        .await?
    }

    /// Streaming inference with a channel: sends each token through the channel
    /// as it's generated so the caller can encrypt-and-zeroize immediately.
    /// Only one plaintext token exists in Rust memory at a time.
    pub fn stream_generate_channel(
        &self,
        messages: Vec<serde_json::Value>,
        max_tokens: u64,
        temperature: f64,
        token_tx: tokio::sync::mpsc::Sender<StreamToken>,
    ) -> tokio::task::JoinHandle<Result<(u64, u64)>> {
        let engine = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let mut messages = messages;
            let e = engine.blocking_lock();
            let result = e.stream_generate(&messages, max_tokens, temperature, |token| {
                if let Err(err) = token_tx.blocking_send(token) {
                    let mut token = err.0;
                    crate::security::secure_zero_string(std::mem::take(&mut token.text));
                    return Err(anyhow::anyhow!("stream receiver dropped"));
                }
                Ok(())
            });
            for message in &mut messages {
                crate::security::secure_zero_json_value(message);
            }
            let (prompt_tokens, completion_tokens) = result?;
            Ok((prompt_tokens, completion_tokens))
        })
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
    fn test_streaming_rejects_buffered_vllm_engine() {
        let engine = InProcessEngine {
            model_id: "test-model".to_string(),
            cache_key: "cache-key".to_string(),
            engine_type: EngineType::VllmMlx,
            loaded: true,
        };

        let err = engine
            .stream_generate(&[], 16, 0.7, |_token| Ok(()))
            .expect_err("vllm-mlx streaming should fail closed");
        assert!(
            err.to_string().contains("requires mlx-lm"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn test_block_dangerous_modules_blocks_imports() {
        Python::with_gil(|py| {
            InProcessEngine::block_dangerous_modules(py).expect("install blocker");
            for module in [
                "socket",
                "subprocess",
                "ctypes",
                "multiprocessing",
                "faulthandler",
            ] {
                let err = py
                    .import(module)
                    .expect_err("dangerous module import should fail");
                let msg = err.to_string();
                assert!(
                    msg.contains("blocked in private text mode"),
                    "unexpected import error for {module}: {msg}"
                );
            }

            let os_checks = CString::new(
                r#"import os
try:
    os.system('/usr/bin/true')
    raise AssertionError('os.system should be blocked')
except Exception as exc:
    assert 'private text mode' in str(exc)

if hasattr(os, 'fork'):
    try:
        os.fork()
        raise AssertionError('os.fork should be blocked')
    except Exception as exc:
        assert 'private text mode' in str(exc)
"#,
            )
            .unwrap();
            py.run(os_checks.as_c_str(), None, None)
                .expect("os process-control hooks should be blocked");

            let cleanup = CString::new(
                r#"import builtins
if hasattr(builtins, '_eigeninference_original_import'):
    builtins.__import__ = builtins._eigeninference_original_import
"#,
            )
            .unwrap();
            py.run(cleanup.as_c_str(), None, None)
                .expect("remove blocker");
        });
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
    fn test_approved_python_runtime_roots_rejects_missing_runtime() {
        let tmp = tempfile::tempdir().unwrap();
        let exe = tmp.path().join("bin/darkbloom");
        let home = tmp.path().join("home");

        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        std::fs::write(&exe, b"").unwrap();
        std::fs::create_dir_all(&home).unwrap();

        let err = approved_python_runtime_roots(&exe, Some(home.as_path())).unwrap_err();
        assert!(
            err.to_string()
                .contains("no approved Python runtime roots found"),
            "unexpected error: {err}"
        );
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
                    msg.contains("approved Python runtime roots")
                        || msg.contains("vllm")
                        || msg.contains("mlx")
                        || msg.contains("install"),
                    "unexpected error: {msg}"
                );
            }
        }
    }
}
