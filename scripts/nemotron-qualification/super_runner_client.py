"""Shared stdlib client for the Nemotron Super qualification runner.

Loaded by path from bench_super.py and memory_calibration.py (both run with
``python3 -I``, so the script directory is not importable). Talks only to the
runner's 127.0.0.1 listeners with the per-run bearer token from its state dir.
"""
import contextlib
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import random
import signal
import socket
import struct
import subprocess
import threading
import time
import zlib

MODEL_ID = "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4"
READY_FILE = "runner-ready.json"
EVENTS_FILE = "runner-events.jsonl"


class RunnerError(RuntimeError):
    pass


def exit_on_sigterm():
    """Turn SIGTERM (e.g. from timeout(1)) into SystemExit so cleanup stops a launched runner."""
    def handler(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, handler)


class Runner:
    """A running runner, found through its ready file; optionally launched here."""

    def __init__(self, state_dir, process=None, launch=None):
        self.state_dir = Path(state_dir)
        self.process = process
        self.launch = launch or {}
        ready = json.loads((self.state_dir / READY_FILE).read_text())
        self.ready = ready
        self.base_url = ready["base_url"]
        self.diagnostics_url = ready["diagnostics_url"]
        self.token = Path(ready["auth_token_file"]).read_text().strip()
        self.events_file = Path(ready["events_file"])

    @classmethod
    def launch_process(cls, command, work_dir, timeout=3600.0, abort_timeout=120.0):
        """Start ``command`` (which must not contain --state-dir) with a new state dir.

        A runner that does not become ready, or whose launch is interrupted, is
        stopped and reaped before the error propagates: it runs in its own
        session, so nothing else would signal it while it holds the model.
        """
        work_dir = Path(work_dir)
        work_dir.mkdir(parents=True, exist_ok=True)
        index = 0
        while (work_dir / f"runner-state-{index}").exists():
            index += 1
        state_dir = work_dir / f"runner-state-{index}"
        output_log = work_dir / f"runner-{index}.output.log"
        argv = list(command) + ["--state-dir", str(state_dir)]
        started = time.monotonic()
        # The child writes through its own copy of the descriptor.
        with open(output_log, "wb") as output:
            process = subprocess.Popen(argv, stdout=output, stderr=subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = started + timeout
            while not (state_dir / READY_FILE).exists():
                if process.poll() is not None:
                    raise RunnerError(f"runner exited with {process.returncode} before ready; "
                                      f"see {output_log}")
                if time.monotonic() > deadline:
                    raise RunnerError("runner did not become ready in time")
                time.sleep(0.05)
            launch = {"command": list(command), "argv": argv,
                      "process_start_to_ready_s": time.monotonic() - started,
                      "output_log": str(output_log)}
            return cls(state_dir, process=process, launch=launch)
        except BaseException:
            _terminate(process, abort_timeout)
            raise

    def stop(self, signum=signal.SIGINT, timeout=900.0):
        """Signal a launched runner and wait for its clean-drain exit code."""
        if self.process is None:
            raise RunnerError("runner was not launched by this script")
        if self.process.poll() is None:
            self.process.send_signal(signum)
        try:
            return self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RunnerError("runner did not exit after drain timeout") from None

    # Diagnostics -----------------------------------------------------------
    def _diagnostics(self, method, path, body=None):
        host, port = _host_port(self.diagnostics_url)
        headers = {"Authorization": "Bearer " + self.token}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        connection = http.client.HTTPConnection(host, port, timeout=60)
        try:
            connection.request(method, path, body=data, headers=headers)
            response = connection.getresponse()
            payload = response.read()
        finally:
            connection.close()
        if response.status != 200:
            raise RunnerError(f"diagnostics {path} returned {response.status}")
        return json.loads(payload)

    def memory(self):
        return self._diagnostics("GET", "/runner/memory")

    def status(self):
        return self._diagnostics("GET", "/runner/status")

    def reset_peaks(self):
        return self._diagnostics("POST", "/runner/peaks/reset", {})

    def set_ballast(self, value):
        return self._diagnostics("POST", "/runner/ballast", {"bytes": int(max(0, value))})

    def events(self, name=None):
        result = []
        for line in self.events_file.read_text().splitlines():
            if not line.strip():
                continue
            event = json.loads(line)
            if name is None or event.get("event") == name:
                result.append(event)
        return result

    def chat(self, body, timeout=900.0, abort=None, on_first_delta=None):
        return stream_chat(self.base_url, self.token, body, timeout=timeout, abort=abort,
                           on_first_delta=on_first_delta)


def _terminate(process, timeout):
    """Interrupt ``process`` (the runner cancels its load or drains), kill it
    after ``timeout`` seconds, and reap it."""
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGINT)
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def _host_port(url):
    rest = url.split("://", 1)[1].split("/", 1)[0]
    host, port = rest.rsplit(":", 1)
    if host not in ("127.0.0.1", "localhost", "[::1]"):
        raise RunnerError("refusing a non-loopback runner endpoint")
    return host, int(port)


class AbortHandle:
    """Closes the request socket with RST from another thread (client disconnect)."""

    def __init__(self):
        self._lock = threading.Lock()
        self._socket = None
        self.aborted_at = None

    def bind(self, sock):
        with self._lock:
            self._socket = sock

    def abort(self):
        with self._lock:
            sock = self._socket
            self.aborted_at = time.perf_counter()
        if sock is not None:
            # The peer may already have closed or reset the connection; the
            # socket is closed below either way.
            with contextlib.suppress(OSError):
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                sock.shutdown(socket.SHUT_RDWR)
            sock.close()


def stream_chat(base_url, token, body, timeout=900.0, abort=None, on_first_delta=None):
    """POST a streamed chat completion and time every SSE delta.

    Times are seconds since the request was written. ``ttft_s`` is the first
    delta carrying content or reasoning text (HTTP and template time included).
    ``on_first_delta`` runs on this thread when that delta arrives.
    """
    host, port = _host_port(base_url)
    body = dict(body)
    body["stream"] = True
    body.setdefault("stream_options", {"include_usage": True})
    data = json.dumps(body).encode()
    result = {"status": None, "ttft_s": None, "deltas": [], "usage": None, "error": None,
              "finish_reason": None, "output_chars": 0, "body_bytes": len(data), "aborted": False}
    connection = http.client.HTTPConnection(host, port, timeout=timeout)
    start = time.perf_counter()  # replaced once the request is written
    try:
        connection.connect()
        if abort is not None:
            abort.bind(connection.sock)
        connection.request("POST", "/v1/chat/completions", body=data, headers={
            "Authorization": "Bearer " + token, "Content-Type": "application/json"})
        start = time.perf_counter()
        response = connection.getresponse()
        result["status"] = response.status
        result["headers_s"] = time.perf_counter() - start
        if response.status != 200:
            result["error"] = _error_text(response.read())
            return _finish(result, start)
        while True:
            line = response.readline()
            if not line:
                break
            line = line.strip()
            if not line.startswith(b"data:"):
                continue
            payload = line[5:].strip()
            if payload == b"[DONE]":
                result["done"] = True
                break
            now = time.perf_counter() - start
            chunk = json.loads(payload)
            if "error" in chunk:
                result["error"] = _error_text(payload)
                continue
            if chunk.get("usage"):
                result["usage"] = chunk["usage"]
            for choice in chunk.get("choices") or []:
                delta = choice.get("delta") or {}
                text = (delta.get("content") or "") + (delta.get("reasoning_content") or "")
                if text:
                    if result["ttft_s"] is None:
                        result["ttft_s"] = now
                        if on_first_delta is not None:
                            on_first_delta()
                    result["deltas"].append(now)
                    result["output_chars"] += len(text)
                if choice.get("finish_reason"):
                    result["finish_reason"] = choice["finish_reason"]
    except (OSError, http.client.HTTPException, ValueError) as error:
        if abort is None or abort.aborted_at is None:
            result["error"] = f"{type(error).__name__}: {error}"
    finally:
        connection.close()
    # An abort from on_first_delta ends the read loop without an exception.
    result["aborted"] = abort is not None and abort.aborted_at is not None
    return _finish(result, start)


def _finish(result, start):
    result["total_s"] = time.perf_counter() - start
    usage = result.get("usage") or {}
    prompt = usage.get("prompt_tokens")
    completion = usage.get("completion_tokens")
    deltas = result["deltas"]
    result["prompt_tokens"] = prompt
    result["completion_tokens"] = completion
    cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
    result["cached_prompt_tokens"] = cached
    if prompt and result["ttft_s"]:
        result["prefill_tokens_per_s"] = prompt / result["ttft_s"]
    if completion and completion > 1 and len(deltas) > 1 and deltas[-1] > deltas[0]:
        result["decode_tokens_per_s"] = (completion - 1) / (deltas[-1] - deltas[0])
    if completion and result["total_s"] > 0:
        result["e2e_output_tokens_per_s"] = completion / result["total_s"]
    result["delta_count"] = len(deltas)
    result["first_delta_s"] = deltas[0] if deltas else None
    result["last_delta_s"] = deltas[-1] if deltas else None
    del result["deltas"]
    return result


def _error_text(payload):
    try:
        value = json.loads(payload)
        error = value.get("error", value)
        if isinstance(error, dict):
            return str(error.get("message") or error.get("type") or error)[:300]
        return str(error)[:300]
    except ValueError:
        return payload[:300].decode(errors="replace")


# Workload construction -------------------------------------------------------

WORDS = ("time year people way day man thing woman life child world school state family "
         "student group country problem hand part place case week company system program "
         "question work government number night point home water room mother area money "
         "story fact month lot right study book eye job word business issue side kind head "
         "house service friend father power hour game line end member law car city community "
         "name president team minute idea kid body information back parent face others level "
         "office door health person art war history party result change morning reason "
         "research girl guy moment air teacher force education").split()


def prompt_text(words, seed, nonce):
    """Deterministic filler text; the nonce leads so no prefix is shared."""
    rng = random.Random(seed)
    filler = " ".join(rng.choice(WORDS) for _ in range(max(0, words)))
    return (f"Reference {nonce}. Read the notes and then count upward from one, "
            f"separating numbers with spaces. Notes: {filler}")


def chat_body(text, max_tokens, seed, extra=None, image_png=None, thinking=False):
    content = text
    if image_png is not None:
        import base64
        content = [{"type": "text", "text": text},
                   {"type": "image_url", "image_url": {
                       "url": "data:image/png;base64," + base64.b64encode(image_png).decode()}}]
    body = {"model": MODEL_ID, "messages": [{"role": "user", "content": content}],
            "max_tokens": max_tokens, "temperature": 0, "top_p": 1, "seed": seed}
    if thinking is not None:
        body["enable_thinking"] = bool(thinking)
    body.update(extra or {})
    return body


def png_rgb(width, height, seed):
    """Deterministic, compressible RGB8 PNG (gradients and a seeded checker)."""
    rows = []
    phase = seed % 7
    for y in range(height):
        row = bytearray([0])
        g = (y * 255) // max(1, height - 1)
        for x in range(width):
            r = (x * 255) // max(1, width - 1)
            b = 255 if ((x // 32) + (y // 32) + phase) % 2 else 0
            row += bytes((r, g, b))
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(kind, data):
        payload = kind + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", raw) + chunk(b"IEND", b"")


def parse_contexts(text):
    """``name=tokens,...`` -> ordered {name: tokens}."""
    result = {}
    for item in filter(None, text.split(",")):
        name, tokens = item.split("=")
        result[name.strip()] = int(tokens)
    return result


def parse_images(text):
    """``WxH,...`` -> [(width, height)]."""
    return [tuple(int(v) for v in item.lower().split("x")) for item in filter(None, text.split(","))]


# Statistics ------------------------------------------------------------------

def percentile(values, q):
    """Linear interpolation between closest ranks (numpy's default method)."""
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    position = (len(values) - 1) * q
    low = int(position)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (position - low)


def summarize(values):
    values = [v for v in values if v is not None]
    if not values:
        return {"n": 0}
    return {"n": len(values), "p50": percentile(values, 0.5), "p90": percentile(values, 0.9),
            "p99": percentile(values, 0.99), "mean": sum(values) / len(values),
            "min": min(values), "max": max(values)}


# Provenance --------------------------------------------------------------------

def _run(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return None


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def git_state(path):
    """HEAD, branch and a hash of the tracked diff plus untracked file contents."""
    path = _run(["git", "-C", str(Path(path).resolve()), "rev-parse", "--show-toplevel"])
    head = path and _run(["git", "-C", path, "rev-parse", "HEAD"])
    if not head:
        return {"path": path, "error": "not a git checkout"}
    diff = subprocess.run(["git", "-C", path, "diff", "HEAD", "--binary"],
                          capture_output=True, timeout=120).stdout
    untracked = _run(["git", "-C", path, "ls-files", "--others", "--exclude-standard"]) or ""
    digest = hashlib.sha256(diff)
    names = [name for name in untracked.splitlines() if name]
    for name in sorted(names):
        digest.update(name.encode() + b"\0")
        try:
            digest.update(Path(path, name).read_bytes())
        except OSError:
            digest.update(b"<unreadable>")
    return {"path": path, "head": head,
            "branch": _run(["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"]),
            "dirty": bool(diff) or bool(names), "untracked_files": len(names),
            "dirty_sha256": digest.hexdigest()}


def hardware():
    def sysctl(name):
        return _run(["sysctl", "-n", name])
    ioreg = _run(["ioreg", "-rc", "AGXAccelerator", "-d", "1"]) or ""
    gpu_cores = None
    for line in ioreg.splitlines():
        if '"gpu-core-count"' in line:
            gpu_cores = line.split("=")[-1].strip()
    return {"chip": sysctl("machdep.cpu.brand_string"), "memory_bytes": int(sysctl("hw.memsize") or 0),
            "cpu_cores": sysctl("hw.ncpu"), "performance_cores": sysctl("hw.perflevel0.physicalcpu"),
            "efficiency_cores": sysctl("hw.perflevel1.physicalcpu"), "gpu_cores": gpu_cores,
            "model": sysctl("hw.model"),
            "os": {"product": _run(["sw_vers", "-productVersion"]), "build": _run(["sw_vers", "-buildVersion"]),
                   "kernel": platform.release()},
            "thermal_pressure": _run(["pmset", "-g", "therm"]),
            "memory_pressure": (_run(["memory_pressure", "-Q"]) or "").splitlines()[-1:] or None,
            "load_average": os.getloadavg()}


def model_revision(model_dir):
    """Revision facts recorded in a local checkpoint directory, when present."""
    if not model_dir:
        return None
    root = Path(model_dir)
    facts = {"path": str(root)}
    for name in ("model.safetensors.index.json", "config.json", "chat_template.jinja"):
        target = root / name
        if target.is_file():
            facts[name + ".sha256"] = file_sha256(target)
    metadata = root / ".cache" / "huggingface" / "download"
    if metadata.is_dir():
        commits = set()
        for entry in metadata.glob("*.metadata"):
            lines = entry.read_text(errors="replace").splitlines()
            if lines:
                commits.add(lines[0].strip())
        facts["hf_download_commits"] = sorted(commits)
    return facts


def provenance(runner, sources, model_dir):
    """Hardware, checkouts, model identity and runner binary facts for a receipt."""
    return {"hardware": hardware(),
            "sources": {name: git_state(path) for name, path in (item.split("=", 1) for item in sources)},
            "model": {"identity": runner.ready.get("identity"), "local_revision": model_revision(model_dir)},
            "runner": {"ready": runner.ready, "launch": runner.launch,
                       "executable_sha256": file_sha256(runner.ready["executable"])}}


def claim_scope(runner):
    if (runner.ready.get("identity") or {}).get("mode") == "synthetic":
        return "SYNTHETIC fixture: validates tooling only; no model speed, memory or quality claim"
    return "full checkpoint through the qualification runner"


def load_settings_hash(settings):
    return hashlib.sha256(json.dumps(settings, sort_keys=True).encode()).hexdigest()
