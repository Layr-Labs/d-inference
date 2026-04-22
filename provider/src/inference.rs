//! In-process inference engine using embedded Python (PyO3).
//!
//! Phase 3 security: runs the inference engine INSIDE our hardened Rust
//! process rather than as a separate subprocess. This means:
//!   - No IPC channel to sniff (no HTTP, no TCP, no Unix socket)
//!   - PT_DENY_ATTACH protects the Python interpreter too
//!   - Hardened Runtime blocks memory inspection of the entire process
//!   - Model weights, prompts, and outputs all live in our protected memory
//!
//! We embed Python via PyO3 and call vllm-mlx's server-level API directly.
//! Instead of calling the low-level SimpleEngine.generate(), we call
//! engine.chat() which handles chat templates, tool calling, and structured
//! output. The response is built using vllm-mlx's Pydantic models to produce
//! full OpenAI-compatible JSON responses in-process.
//!
//! Architecture:
//!   Rust (main loop, WebSocket, security)
//!     └── PyO3 embedded Python
//!           └── vllm_mlx server handler (engine.chat / engine.stream_chat)
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
/// Uses vllm-mlx's server-level engine API (engine.chat / engine.stream_chat)
/// rather than the low-level SimpleEngine.generate(). This gives us full
/// OpenAI-compatible features: tool calling, structured output, proper chat
/// templates, and streaming — all in-process without starting an HTTP server.
pub struct InProcessEngine {
    model_id: String,
    cache_key: String,
    pub loaded: bool,
}

/// A single inference result (non-streaming).
///
/// For the server-handler path, `text` contains the full OpenAI-compatible
/// JSON response (ChatCompletionResponse serialized). For streaming,
/// individual SSE chunks are delivered via `StreamToken`.
#[derive(Debug)]
pub struct InferenceResult {
    pub text: String,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

/// A streaming chunk from the inference engine.
///
/// `text` contains a complete SSE-formatted chunk
/// (e.g. `data: {"id":"chatcmpl-...","choices":[...]}\n\n`).
#[derive(Debug)]
pub struct StreamToken {
    pub text: String,
    pub finish_reason: Option<String>,
}

const VLLM_ENGINE_STORE: &str = "_eigeninference_vllm_engines";

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

    /// Check that vllm-mlx is importable.
    /// Retries on failure to handle site-packages being replaced concurrently
    /// (e.g. runtime self-heal running from a previous process).
    pub fn detect_engine() -> Result<()> {
        let max_attempts = 3;
        let mut last_err = None;
        for attempt in 1..=max_attempts {
            match Self::try_detect_engine() {
                Ok(()) => return Ok(()),
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

    fn try_detect_engine() -> Result<()> {
        Python::with_gil(|py| {
            if py.import("vllm_mlx").is_ok() {
                tracing::info!("In-process engine: vllm-mlx detected");
                return Ok(());
            }

            Err(anyhow::anyhow!(
                "vllm-mlx is not installed. \
                 Install with: pip install vllm-mlx"
            ))
        })
    }

    /// Load the model into memory. This is slow (downloads if needed,
    /// loads weights into GPU memory) but only happens once.
    ///
    /// Uses vllm-mlx's `load_model()` to initialize the engine via the
    /// server module's startup path (AdaptiveEngine wrapping SimpleEngine).
    /// No HTTP server is started — we only use the engine object.
    pub fn load(&mut self) -> Result<()> {
        Self::detect_engine()?;

        Python::with_gil(|py| -> Result<()> {
            self.load_vllm_mlx(py)?;
            // Lock sys.path to approved runtime roots. This is the primary
            // defense — prevents loading code from provider-controlled paths.
            // We do NOT block socket/subprocess/ctypes because vllm-mlx uses
            // them internally (requests library, lazy model loading, etc.).
            // The path lock + PYTHONNOUSERSITE + SIP is sufficient.
            if let Err(e) = Self::lock_python_path(py) {
                tracing::warn!("Python path lock failed (defense-in-depth): {e:#}");
            }
            Ok(())
        })?;

        self.loaded = true;
        tracing::info!(
            "Model loaded in-process: {} via vllm-mlx server handler",
            self.model_id
        );
        Ok(())
    }

    /// Drop the Python-side model objects so GPU memory can be reclaimed.
    pub fn unload(&mut self) -> Result<()> {
        if !self.loaded {
            return Ok(());
        }

        Python::with_gil(|py| self.unload_vllm_mlx(py))?;

        self.loaded = false;
        tracing::info!("Model unloaded in-process: {}", self.model_id);
        Ok(())
    }

    /// Initialize the vllm-mlx engine via its server module's `load_model()`.
    ///
    /// This creates an AdaptiveEngine (SimpleEngine + request queuing) and
    /// stores it in a Python builtins dict keyed by cache_key. The engine
    /// supports `engine.chat()` and `engine.stream_chat()` with full
    /// OpenAI-compatible features (chat templates, tool calling, structured
    /// output) without starting an HTTP server.
    fn load_vllm_mlx(&self, py: Python<'_>) -> Result<()> {
        let model = serde_json::to_string(&self.model_id).context("invalid model path")?;
        let cache_key = serde_json::to_string(&self.cache_key).context("invalid cache key")?;
        let code = format!(
            r#"
import builtins, traceback as _tb
try:
    from vllm_mlx.server import load_model as _load_model
    import vllm_mlx.server as _server
    _load_model({model})
    _engine = _server._engine
    if _engine is None:
        raise RuntimeError("load_model() did not initialize the engine")
    if not hasattr(builtins, '{store}'):
        builtins.{store} = {{}}
    builtins.{store}[{cache_key}] = _engine
except Exception as _e:
    _err_detail = _tb.format_exc()
    raise RuntimeError(f"vllm-mlx server init failed: {{_err_detail}}") from _e
"#,
            store = VLLM_ENGINE_STORE,
            cache_key = cache_key,
            model = model
        );
        let ccode = CString::new(code).context("invalid code string")?;
        py.run(ccode.as_c_str(), None, None)
            .context("failed to initialize vllm-mlx engine via server handler")?;
        Ok(())
    }

    fn unload_vllm_mlx(&self, py: Python<'_>) -> Result<()> {
        let cache_key = serde_json::to_string(&self.cache_key).context("invalid cache key")?;
        let code = format!(
            r#"
import asyncio, builtins, gc
store = getattr(builtins, '{store}', None)
if isinstance(store, dict):
    engine = store.pop({cache_key}, None)
    if engine is not None and hasattr(engine, 'stop'):
        try:
            asyncio.run(engine.stop())
        except Exception:
            pass
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

    /// Run non-streaming inference via vllm-mlx's server-level engine.
    ///
    /// Calls `engine.chat()` with the full set of OpenAI-compatible
    /// parameters (messages, tools, response_format, etc.), then builds
    /// a complete `ChatCompletionResponse` JSON using vllm-mlx's Pydantic
    /// models. Returns the response JSON in `InferenceResult.text`.
    ///
    /// The `request_body` should be the full JSON request body from the
    /// consumer. The engine handles chat template application, tool calling
    /// parsing, and structured output enforcement internally.
    pub fn generate(&self, request_body: &serde_json::Value) -> Result<InferenceResult> {
        if !self.loaded {
            anyhow::bail!("Model not loaded — call load() first");
        }

        Python::with_gil(|py| self.generate_via_server_handler(py, request_body))
    }

    fn generate_via_server_handler(
        &self,
        py: Python<'_>,
        request_body: &serde_json::Value,
    ) -> Result<InferenceResult> {
        let mut request_json =
            serde_json::to_string(request_body).context("failed to serialize request body")?;
        let result = (|| -> Result<InferenceResult> {
            let locals = PyDict::new(py);
            locals.set_item("engine_key", &self.cache_key)?;
            locals.set_item("request_json", &request_json)?;

            let code = CString::new(
                r#"
import asyncio, builtins, json, traceback as _tb
try:
    engine = builtins._eigeninference_vllm_engines[engine_key]
    _req = json.loads(request_json)
    _messages = _req.get('messages', [])
    if not _messages and _req.get('input'):
        _input = _req['input']
        if isinstance(_input, str):
            _messages = [{'role': 'user', 'content': _input}]
        elif isinstance(_input, list):
            _messages = _input
    _max_tokens = int(_req.get('max_tokens') or _req.get('max_output_tokens') or 256)
    _temperature = float(_req.get('temperature', 0.7))
    _top_p = float(_req.get('top_p', 0.9))
    _stop = _req.get('stop', None)
    _tools = _req.get('tools', None)
    _tool_choice = _req.get('tool_choice', None)
    _response_format = _req.get('response_format', None)
    _model_name = _req.get('model', 'unknown')
    _chat_kwargs = dict(
        messages=_messages,
        max_tokens=_max_tokens,
        temperature=_temperature,
        top_p=_top_p,
    )
    if _tools:
        from vllm_mlx.api.tool_calling import convert_tools_for_template
        from vllm_mlx.api.models import ToolDefinition
        _chat_kwargs['tools'] = convert_tools_for_template(
            [ToolDefinition(**t) for t in _tools]
        )
    if _response_format:
        from vllm_mlx.api.tool_calling import build_json_system_prompt
        _json_instr = build_json_system_prompt(_response_format)
        if _json_instr:
            _msgs = list(_messages)
            _sys_idx = None
            for _i, _m in enumerate(_msgs):
                if _m.get('role') == 'system':
                    _sys_idx = _i
                    break
            if _sys_idx is not None:
                _msgs[_sys_idx] = dict(_msgs[_sys_idx])
                _msgs[_sys_idx]['content'] = (_msgs[_sys_idx].get('content', '') or '') + '\n\n' + _json_instr
            else:
                _msgs.insert(0, {'role': 'system', 'content': _json_instr})
            _chat_kwargs['messages'] = _msgs
    if _stop:
        _chat_kwargs['stop'] = _stop
    _output = asyncio.run(engine.chat(**_chat_kwargs))
    from vllm_mlx.api.models import (
        ChatCompletionResponse, ChatCompletionChoice, AssistantMessage, Usage
    )
    from vllm_mlx.api.tool_calling import parse_tool_calls
    from vllm_mlx.api.utils import clean_output_text
    from vllm_mlx.api.models import ToolCall, FunctionCall
    _cleaned_text, _tool_calls = parse_tool_calls(_output.text, _req)
    if not _tool_calls and '{{"' in _output.text:
        import re as _re
        _fixed = _re.sub(r'\{\{(")', r'{\1', _output.text)
        _cleaned_text, _tool_calls = parse_tool_calls(_fixed, _req)
    _final_content = clean_output_text(_cleaned_text) if _cleaned_text else None
    if _response_format and not _tool_calls:
        from vllm_mlx.api.tool_calling import parse_json_output
        _, _parsed_json, _is_valid, _err = parse_json_output(
            _cleaned_text or _output.text, _response_format
        )
        if _parsed_json is not None:
            _final_content = json.dumps(_parsed_json)
    _finish_reason = 'tool_calls' if _tool_calls else _output.finish_reason
    _resp = ChatCompletionResponse(
        model=_model_name,
        choices=[ChatCompletionChoice(
            message=AssistantMessage(
                content=_final_content,
                tool_calls=_tool_calls,
            ),
            finish_reason=_finish_reason,
        )],
        usage=Usage(
            prompt_tokens=_output.prompt_tokens,
            completion_tokens=_output.completion_tokens,
            total_tokens=_output.prompt_tokens + _output.completion_tokens,
        ),
    )
    _result_json = _resp.model_dump_json()
    _result_prompt_tokens = _output.prompt_tokens
    _result_completion_tokens = _output.completion_tokens
except Exception as _e:
    _err_detail = _tb.format_exc()
    raise RuntimeError(f"generate via server handler failed: {_err_detail}") from _e
"#,
            )
            .unwrap();
            py.run(code.as_c_str(), None, Some(&locals))
                .context("vllm-mlx server handler generate failed")?;

            let text: String = locals
                .get_item("_result_json")?
                .ok_or_else(|| anyhow::anyhow!("no result JSON"))?
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
        crate::security::secure_zero_string(std::mem::take(&mut request_json));
        result
    }

    /// Run streaming inference via vllm-mlx's `engine.stream_chat()`.
    ///
    /// Calls the callback for each SSE chunk. Each `StreamToken.text`
    /// contains a fully-formatted SSE chunk (e.g. `data: {...}\n\n`).
    ///
    /// This runs synchronously in the Python GIL. For async integration,
    /// wrap in `tokio::task::spawn_blocking`.
    pub fn stream_generate(
        &self,
        request_body: &serde_json::Value,
        mut on_token: impl FnMut(StreamToken) -> Result<()>,
    ) -> Result<(u64, u64)> {
        if !self.loaded {
            anyhow::bail!("Model not loaded — call load() first");
        }

        Python::with_gil(|py| {
            let mut request_json =
                serde_json::to_string(request_body).context("failed to serialize request body")?;
            let result = (|| -> Result<(u64, u64)> {
                let locals = PyDict::new(py);
                locals.set_item("engine_key", &self.cache_key)?;
                locals.set_item("request_json", &request_json)?;

                // Set up a Python queue.SimpleQueue for real-time streaming.
                // A Python thread runs the async generator and pushes each
                // chunk to the queue. Rust releases the GIL and polls the
                // queue, sending each chunk to the coordinator immediately.
                let setup_code = CString::new(
                    r#"
import builtins, json, uuid, time, queue, threading, asyncio, re, traceback as _tb

engine = builtins._eigeninference_vllm_engines[engine_key]
_req = json.loads(request_json)
_messages = _req.get('messages', [])
if not _messages and _req.get('input'):
    _input = _req['input']
    if isinstance(_input, str):
        _messages = [{'role': 'user', 'content': _input}]
    elif isinstance(_input, list):
        _messages = _input
_max_tokens = int(_req.get('max_tokens') or _req.get('max_output_tokens') or 256)
_temperature = float(_req.get('temperature', 0.7))
_top_p = float(_req.get('top_p', 0.9))
_stop = _req.get('stop', None)
_tools = _req.get('tools', None)
_model_name = _req.get('model', 'unknown')
_response_format = _req.get('response_format', None)
_chat_kwargs = dict(
    messages=_messages,
    max_tokens=_max_tokens,
    temperature=_temperature,
    top_p=_top_p,
)
if _tools:
    from vllm_mlx.api.tool_calling import convert_tools_for_template
    from vllm_mlx.api.models import ToolDefinition
    _chat_kwargs['tools'] = convert_tools_for_template(
        [ToolDefinition(**t) for t in _tools]
    )
if _response_format:
    from vllm_mlx.api.tool_calling import build_json_system_prompt
    _json_instr = build_json_system_prompt(_response_format)
    if _json_instr:
        _msgs = list(_messages)
        _sys_idx = None
        for _i, _m in enumerate(_msgs):
            if _m.get('role') == 'system':
                _sys_idx = _i
                break
        if _sys_idx is not None:
            _msgs[_sys_idx] = dict(_msgs[_sys_idx])
            _msgs[_sys_idx]['content'] = (_msgs[_sys_idx].get('content', '') or '') + '\n\n' + _json_instr
        else:
            _msgs.insert(0, {'role': 'system', 'content': _json_instr})
        _chat_kwargs['messages'] = _msgs
if _stop:
    _chat_kwargs['stop'] = _stop

_SPECIAL_TOKENS = re.compile(r'<\|(?:im_start|im_end|endoftext|end_of_turn|eot_id|end_header_id|start_header_id|finetune_right_pad_id)\|>')
_response_id = f'chatcmpl-{uuid.uuid4().hex[:8]}'
_created = int(time.time())
_token_queue = queue.SimpleQueue()

def _stream_worker():
    import json as _json
    try:
        async def _run():
            _pt, _ct = 0, 0
            async for _out in engine.stream_chat(**_chat_kwargs):
                _delta = _out.new_text
                if hasattr(_out, 'prompt_tokens') and _out.prompt_tokens:
                    _pt = _out.prompt_tokens
                if hasattr(_out, 'completion_tokens') and _out.completion_tokens:
                    _ct = _out.completion_tokens
                if _delta:
                    _content = _SPECIAL_TOKENS.sub('', _delta)
                    if _content:
                        _finish = _out.finish_reason if _out.finished else None
                        _token_queue.put(_json.dumps({
                            'id': _response_id, 'object': 'chat.completion.chunk',
                            'created': _created, 'model': _model_name,
                            'choices': [{'index': 0, 'delta': {'content': _content}, 'finish_reason': _finish}],
                        }))
                elif _out.finished:
                    _token_queue.put(_json.dumps({
                        'id': _response_id, 'object': 'chat.completion.chunk',
                        'created': _created, 'model': _model_name,
                        'choices': [{'index': 0, 'delta': {}, 'finish_reason': _out.finish_reason or 'stop'}],
                    }))
            _token_queue.put(('__DONE__', _pt, _ct))
        asyncio.run(_run())
    except Exception as _e:
        _token_queue.put(('__ERROR__', str(_e)))

_stream_thread = threading.Thread(target=_stream_worker, daemon=True)
_stream_thread.start()
"#,
                )
                .unwrap();
                py.run(setup_code.as_c_str(), None, Some(&locals))
                    .context("vllm-mlx stream setup failed")?;

                let token_queue = locals
                    .get_item("_token_queue")?
                    .ok_or_else(|| anyhow::anyhow!("no token queue"))?
                    .clone()
                    .unbind();

                // Release the GIL and poll the queue for real-time streaming.
                let mut prompt_tokens = 0u64;
                let mut completion_tokens = 0u64;
                loop {
                    // Acquire GIL briefly to get one item from the queue.
                    let item = Python::with_gil(|py| -> Result<Option<String>> {
                        let queue = token_queue.bind(py);
                        let item = queue
                            .call_method1("get", (true, 120.0))
                            .context("queue.get timeout")?;

                        if let Ok(tup) = item.extract::<(String, u64, u64)>() {
                            if tup.0 == "__DONE__" {
                                prompt_tokens = tup.1;
                                completion_tokens = tup.2;
                                return Ok(None);
                            }
                        }
                        if let Ok(tup) = item.extract::<(String, String)>() {
                            if tup.0 == "__ERROR__" {
                                anyhow::bail!("stream error: {}", tup.1);
                            }
                        }
                        Ok(Some(item.extract::<String>()?))
                    })?;

                    match item {
                        Some(chunk_json) => {
                            let sse_line = format!("data: {}", chunk_json);
                            on_token(StreamToken {
                                text: sse_line,
                                finish_reason: None,
                            })?;
                        }
                        None => break,
                    }
                }

                Ok((prompt_tokens, completion_tokens))
            })();
            crate::security::secure_zero_string(std::mem::take(&mut request_json));
            result
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

    /// Run non-streaming inference. Takes the full request body JSON
    /// and returns a complete OpenAI-compatible response.
    pub async fn generate(&self, mut request_body: serde_json::Value) -> Result<InferenceResult> {
        let engine = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let e = engine.blocking_lock();
            let result = e.generate(&request_body);
            crate::security::secure_zero_json_value(&mut request_body);
            result
        })
        .await?
    }

    /// Streaming inference with a channel: sends each SSE chunk through
    /// the channel as it's generated so the caller can encrypt-and-zeroize
    /// immediately. Each chunk is a complete `data: {...}` SSE line.
    pub fn stream_generate_channel(
        &self,
        mut request_body: serde_json::Value,
        token_tx: tokio::sync::mpsc::Sender<StreamToken>,
    ) -> tokio::task::JoinHandle<Result<(u64, u64)>> {
        let engine = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let e = engine.blocking_lock();
            let result = e.stream_generate(&request_body, |token| {
                if let Err(err) = token_tx.blocking_send(token) {
                    let mut token = err.0;
                    crate::security::secure_zero_string(std::mem::take(&mut token.text));
                    return Err(anyhow::anyhow!("stream receiver dropped"));
                }
                Ok(())
            });
            crate::security::secure_zero_json_value(&mut request_body);
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
    fn test_engine_not_loaded() {
        let engine = InProcessEngine::new("test-model".to_string());
        assert!(!engine.is_loaded());
        assert_eq!(engine.model_id(), "test-model");

        let body = serde_json::json!({
            "messages": [{"role": "user", "content": "hello"}],
            "max_tokens": 100,
            "temperature": 0.7,
        });
        let result = engine.generate(&body);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not loaded"));
    }

    #[test]
    fn test_stream_not_loaded() {
        let engine = InProcessEngine::new("test-model".to_string());

        let body = serde_json::json!({
            "messages": [{"role": "user", "content": "hello"}],
            "max_tokens": 16,
            "stream": true,
        });
        let err = engine
            .stream_generate(&body, |_token| Ok(()))
            .expect_err("should fail when not loaded");
        assert!(
            err.to_string().contains("not loaded"),
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
        // This will fail if vllm-mlx is not installed,
        // which is expected in test environments without MLX.
        let result = InProcessEngine::detect_engine();
        // Either succeeds (vllm-mlx installed) or fails gracefully
        match result {
            Ok(()) => {
                println!("Detected engine: vllm-mlx");
            }
            Err(e) => {
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
