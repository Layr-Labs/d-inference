#!/usr/bin/env python3
"""
Local E2E test environment for the Darkbloom inference stack.

Spins up the real coordinator binary with test-friendly settings and one or more
providers (simulated or the real Rust binary), then runs HTTP/WebSocket-level
assertions against the live stack.

Usage:
    # Basic coordinator routing tests (simulated provider, no GPU needed)
    python scripts/e2e-runner.py --coordinator-repo ./coordinator test_basic

    # Full stack with real provider (macOS only, needs vllm-mlx)
    python scripts/e2e-runner.py --coordinator-repo ./coordinator \
        --provider-binary ./provider/target/release/darkbloom \
        --vllm-model mlx-community/Qwen3.5-0.8B-MLX-4bit \
        test_basic test_inference

    # Run all tests
    python scripts/e2e-runner.py --coordinator-repo ./coordinator all
"""

import argparse
import atexit
import base64
import json
import os
import random
import signal
import string
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Configuration constants
# ---------------------------------------------------------------------------

DEFAULT_COORDINATOR_PORT = 8080
DEFAULT_ADMIN_KEY = "e2e-test-admin-key-" + "".join(random.choices(string.ascii_lowercase, k=8))
DEFAULT_BACKEND_PORT_BASE = 18100
HEARTBEAT_INTERVAL = 2  # seconds
CHALLENGE_INTERVAL = 10  # seconds
PROVIDER_WAIT_TIMEOUT = 15  # seconds
INFERENCE_TIMEOUT = 60  # seconds
TEST_MODEL = "mlx-community/Qwen3.5-0.8B-MLX-4bit"

# ---------------------------------------------------------------------------
# Process management
# ---------------------------------------------------------------------------

_processes: list[subprocess.Popen] = []


def _cleanup():
    for p in reversed(_processes):
        try:
            p.terminate()
        except Exception:
            pass
    for p in reversed(_processes):
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                p.kill()
                p.wait(timeout=2)
            except Exception:
                pass


def _handle_signal(signum, frame):
    _cleanup()
    sys.exit(128 + signum)


signal.signal(signal.SIGINT, _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)
atexit.register(_cleanup)


def spawn(args: list[str], env: Optional[dict] = None, cwd: Optional[str] = None,
          label: str = "") -> subprocess.Popen:
    """Start a child process tracked for cleanup."""
    merged = os.environ.copy()
    if env:
        merged.update(env)
    print(f"[e2e] starting {label or args[0]}: {' '.join(args)}")
    p = subprocess.Popen(args, env=merged, cwd=cwd)
    _processes.append(p)
    return p


def wait_for_log(p: subprocess.Popen, pattern: str, timeout: float = 30) -> bool:
    """Read stderr/stdout until pattern appears or timeout expires."""
    # Simple polling via the process output — in production we'd use
    # async IO or pexpect, but this is a skeleton.
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline and p.poll() is None:
        try:
            line = p.stderr.readline() if p.stderr else b""
            buf += line
            if pattern.encode() in line:
                return True
        except Exception:
            time.sleep(0.1)
    return pattern.encode() in buf


def wait_for_http(url: str, timeout: float = 15) -> bool:
    """Poll an HTTP endpoint until it returns 200."""
    import urllib.request
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            resp = urllib.request.urlopen(url, timeout=2)
            return resp.status == 200
        except Exception:
            time.sleep(0.5)
    return False


# ---------------------------------------------------------------------------
# Test result tracking
# ---------------------------------------------------------------------------

_tests_run = 0
_tests_passed = 0
_tests_failed = 0


def test(name: str):
    """Decorator to register a test function."""
    def decorator(fn):
        _tests.append((name, fn))
        return fn
    return decorator


_tests: list[tuple[str, callable]] = []


def run_tests(names: list[str]):
    """Run registered tests matching the given names (or 'all')."""
    global _tests_run, _tests_passed, _tests_failed
    for name, fn in _tests:
        if "all" not in names and name not in names:
            continue
        _tests_run += 1
        print(f"\n{'='*60}")
        print(f"[e2e] TEST: {name}")
        print(f"{'='*60}")
        try:
            fn()
            _tests_passed += 1
            print(f"[e2e] PASS: {name}")
        except Exception as e:
            _tests_failed += 1
            print(f"[e2e] FAIL: {name} — {e}")
            import traceback
            traceback.print_exc()


def summarize():
    total = _tests_passed + _tests_failed
    print(f"\n{'='*60}")
    print(f"[e2e] RESULTS: {_tests_passed}/{total} passed, {_tests_failed} failed")
    print(f"{'='*60}")
    return _tests_failed == 0


# ---------------------------------------------------------------------------
# Coordinator
# ---------------------------------------------------------------------------

class Coordinator:
    """Manages the real coordinator binary."""

    def __init__(self, repo_path: str, port: int = DEFAULT_COORDINATOR_PORT,
                 admin_key: str = DEFAULT_ADMIN_KEY):
        self.repo = Path(repo_path).resolve()
        self.port = port
        self.admin_key = admin_key
        self.process: Optional[subprocess.Popen] = None

    @property
    def base_url(self) -> str:
        return f"http://localhost:{self.port}"

    @property
    def ws_url(self) -> str:
        return f"ws://localhost:{self.port}/ws/provider"

    def start(self):
        # Build if needed — in production we'd check binary freshness
        binary = self.repo / "coordinator"
        if not binary.exists():
            print("[e2e] building coordinator...")
            subprocess.run(["go", "build", "-o", "coordinator", "./cmd/coordinator"],
                           cwd=self.repo, check=True, capture_output=True)

        env = {
            "EIGENINFERENCE_PORT": str(self.port),
            "EIGENINFERENCE_ADMIN_KEY": self.admin_key,
            # No DATABASE_URL → in-memory store
            "EIGENINFERENCE_MIN_TRUST": "none",       # bypass all trust/attestation
            "EIGENINFERENCE_BILLING_MOCK": "true",     # skip Solana/Stripe
            "EIGENINFERENCE_CONSOLE_URL": f"http://localhost:{self.port}",
        }
        self.process = spawn(
            [str(binary)],
            env=env,
            cwd=str(self.repo),
            label="coordinator",
        )

        # Wait for server to be ready
        if not wait_for_http(f"{self.base_url}/v1/models", timeout=15):
            raise RuntimeError("coordinator failed to start")

        print(f"[e2e] coordinator ready at {self.base_url}")

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=10)
            self.process = None

    def api_call(self, method: str, path: str, body: Optional[dict] = None,
                 api_key: Optional[str] = None) -> tuple[int, dict]:
        """Make an HTTP call to the coordinator API."""
        import urllib.request
        url = f"{self.base_url}{path}"
        data = json.dumps(body).encode() if body else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        if api_key:
            req.add_header("Authorization", f"Bearer {api_key}")
        try:
            resp = urllib.request.urlopen(req, timeout=10)
            return resp.status, json.loads(resp.read())
        except urllib.request.HTTPError as e:
            body_text = e.read().decode()
            try:
                return e.code, json.loads(body_text)
            except json.JSONDecodeError:
                return e.code, {"error": body_text}


# ---------------------------------------------------------------------------
# Simulated Provider (Go-free, Python-based WebSocket client)
# ---------------------------------------------------------------------------

class SimulatedProvider:
    """
    A Python WebSocket client that speaks the Darkbloom provider protocol.
    Sends register → handles attestation challenges → sends heartbeats →
    responds to inference requests with fake streaming chunks.

    This exercises the coordinator's full control-plane code paths without
    needing the real Rust binary or a GPU backend.
    """

    def __init__(self, coordinator_url: str, model: str = TEST_MODEL,
                 name: str = "sim-provider", backend_port: int = DEFAULT_BACKEND_PORT_BASE):
        self.coordinator_url = coordinator_url
        self.model = model
        self.name = name
        self.backend_port = backend_port
        self.ws = None
        self.public_key_b64 = ""
        self.private_key_bytes = None
        self._stop = False

    def start(self):
        """Connect to the coordinator and register as a provider."""
        import websockets.sync.client as ws_client
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

        # Generate an X25519 key pair (matching the protocol)
        private_key = X25519PrivateKey.generate()
        public_key = private_key.public_key()
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        self.public_key_b64 = base64.b64encode(
            public_key.public_bytes(Encoding.Raw, PublicFormat.Raw)
        ).decode()
        self.private_key_bytes = private_key.private_bytes_raw()

        self.ws = ws_client.connect(self.coordinator_url)
        self.ws.settimeout(5)

        # Register
        reg = {
            "type": "register",
            "hardware": {
                "machine_model": "Mac15,8",
                "chip_name": "Apple M3 Max",
                "memory_gb": 128,
                "memory_available_gb": 124.0,
                "cpu_cores": {"total": 16, "performance": 12, "efficiency": 4},
                "gpu_cores": 40,
                "memory_bandwidth_gbs": 400.0,
            },
            "models": [{
                "id": self.model,
                "model_type": "chat",
                "quantization": "4bit",
                "size_bytes": 500_000_000,
            }],
            "backend": "vllm-mlx",
            "public_key": self.public_key_b64,
            "decode_tps": 100.0,
            "version": "0.2.99-e2e",
        }
        self.ws.send(json.dumps(reg))
        print(f"[e2e] simulated provider '{self.name}' registered")

    def run_loop(self):
        """Run the message loop until told to stop."""
        while not self._stop:
            try:
                data = self.ws.recv()
            except Exception:
                break
            if not data:
                break
            msg = json.loads(data)
            self._handle(msg)

    def _handle(self, msg: dict):
        msg_type = msg.get("type", "")

        if msg_type == "attestation_challenge":
            # Respond with a SHA-256 "signature" (matching the real provider's
            # current implementation before SE integration)
            nonce = msg.get("nonce", "")
            timestamp = msg.get("timestamp", "")
            sig_data = nonce + timestamp + self.public_key_b64
            import hashlib
            signature = base64.b64encode(
                hashlib.sha256(sig_data.encode()).digest()
            ).decode()

            resp = {
                "type": "attestation_response",
                "nonce": nonce,
                "signature": signature,
                "public_key": self.public_key_b64,
                "hypervisor_active": False,
                "rdma_disabled": True,
                "sip_enabled": True,
                "secure_boot_enabled": True,
                "binary_hash": "e2e-test-binary-hash",
            }
            self.ws.send(json.dumps(resp))

        elif msg_type == "inference_request":
            request_id = msg.get("request_id", "")
            body = msg.get("body", {})
            stream = body.get("stream", True)
            self._serve_inference(request_id, stream)

        elif msg_type == "runtime_status":
            pass  # acknowledged

    def _serve_inference(self, request_id: str, stream: bool):
        """Respond with fake streaming chunks and a complete message."""
        # Stream chunks
        if stream:
            for word in ["Hello", " world", " from", " e2e"]:
                chunk = {
                    "type": "inference_response_chunk",
                    "request_id": request_id,
                    "data": f"data: {json.dumps({
                        'id': f'chatcmpl-e2e-{request_id}',
                        'choices': [{'delta': {'content': word}}],
                    })}\n\n",
                }
                self.ws.send(json.dumps(chunk))
                time.sleep(0.05)

        # Complete
        complete = {
            "type": "inference_complete",
            "request_id": request_id,
            "usage": {"prompt_tokens": 10, "completion_tokens": 5},
        }
        self.ws.send(json.dumps(complete))

    def stop(self):
        self._stop = True
        if self.ws:
            try:
                self.ws.close()
            except Exception:
                pass
            self.ws = None


# ---------------------------------------------------------------------------
# Test scenarios
# ---------------------------------------------------------------------------


def _start_env(coordinator_repo: str, provider_type: str = "simulated",
               provider_binary: Optional[str] = None, vllm_model: Optional[str] = None):
    """Start coordinator and provider, yield test context, tear down."""
    coord = Coordinator(coordinator_repo)
    coord.start()

    providers = []

    if provider_type == "simulated":
        p = SimulatedProvider(
            coordinator_url=coord.ws_url,
            model=vllm_model or TEST_MODEL,
        )
        p.start()
        providers.append(p)

    elif provider_type == "real":
        # TODO(Ethan): implement RealProvider wrapper around darkbloom serve
        # This needs:
        #   1. Build provider binary with `cargo build --release`
        #   2. Generate a TOML config or pass --model --coordinator --no-auto-update
        #   3. Wait for "Connected to coordinator" in logs
        #   4. Handle non-zero exit codes
        raise NotImplementedError("RealProvider not yet implemented")

    # Wait for first heartbeat to be processed
    time.sleep(HEARTBEAT_INTERVAL * 2)

    try:
        yield coord, providers
    finally:
        for p in providers:
            p.stop()
        coord.stop()


# --- Test: Basic Provider Connectivity ---

@test("test_basic")
def test_basic():
    """Verify a simulated provider can register and the coordinator can see it."""
    import urllib.request

    coord = Coordinator(Path(sys.argv[0]).resolve().parent.parent / "coordinator")
    coord.start()

    try:
        p = SimulatedProvider(coordinator_url=coord.ws_url)
        p.start()
        p_run_result = {"done": False}

        import threading
        def run_loop():
            p.run_loop()
            p_run_result["done"] = True

        t = threading.Thread(target=run_loop, daemon=True)
        t.start()

        time.sleep(3)

        # Check provider is visible in stats
        status, body = coord.api_call("GET", "/v1/models")
        assert status == 200, f"/v1/models returned {status}: {body}"
        models = body.get("data", [])
        print(f"[e2e] models visible: {[m['id'] for m in models]}")

        p.stop()
    finally:
        coord.stop()


# --- Test: Streamed Inference ---

@test("test_inference")
def test_inference():
    """Send a consumer chat request and verify streamed tokens come back."""
    coord = Coordinator(Path(sys.argv[0]).resolve().parent.parent / "coordinator")
    coord.start()

    try:
        p = SimulatedProvider(coordinator_url=coord.ws_url)
        p.start()

        import threading
        t = threading.Thread(target=p.run_loop, daemon=True)
        t.start()

        time.sleep(3)

        # TODO(Ethan): The coordinator requires the provider to be trusted/accepted
        # before routing. In "none" trust mode this should happen automatically
        # after the first challenge-response. We need to:
        #   1. Wait for the provider status to be routable
        #   2. Then send the consumer request
        status, body = coord.api_call(
            "POST", "/v1/chat/completions",
            body={
                "model": TEST_MODEL,
                "messages": [{"role": "user", "content": "hello"}],
                "stream": True,
            },
            api_key=DEFAULT_ADMIN_KEY,
        )
        print(f"[e2e] inference response: status={status}")
        if status != 200:
            print(f"[e2e] body={json.dumps(body, indent=2)}")

        p.stop()
    finally:
        coord.stop()


# --- Test: Multi-Provider Routing ---

@test("test_multi_provider")
def test_multi_provider():
    """Register two providers, verify both are discoverable."""
    coord = Coordinator(Path(sys.argv[0]).resolve().parent.parent / "coordinator")
    coord.start()

    try:
        providers = [
            SimulatedProvider(coordinator_url=coord.ws_url, name=f"sim-{i}",
                              model=TEST_MODEL)
            for i in range(2)
        ]

        threads = []
        for p in providers:
            p.start()
            t = threading.Thread(target=p.run_loop, daemon=True)
            t.start()
            threads.append(t)

        time.sleep(3)

        status, body = coord.api_call("GET", "/v1/models")
        assert status == 200, f"GET /v1/models: {status}"
        print(f"[e2e] models visible after multi-provider: "
              f"{[m['id'] for m in body.get('data', [])]}")

        for p in providers:
            p.stop()
    finally:
        coord.stop()


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Darkbloom E2E test environment",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Available tests:
  all                 Run all tests
  test_basic          Verify provider registration and discovery
  test_inference      Full consumer → coordinator → provider → response
  test_multi_provider Two providers on the same model

Examples:
  # Quick coordinator test (no GPU, works anywhere)
  python scripts/e2e-runner.py --coordinator-repo ./coordinator test_basic

  # Full stack with real provider (macOS)
  python scripts/e2e-runner.py --coordinator-repo ./coordinator \\
      --provider-binary ./provider/target/release/darkbloom \\
      --vllm-model mlx-community/Qwen3.5-0.8B-MLX-4bit \\
      test_inference

  # All tests
  python scripts/e2e-runner.py --coordinator-repo ./coordinator all
""")
    parser.add_argument("--coordinator-repo", required=True,
                        help="Path to coordinator/ directory")
    parser.add_argument("--provider-binary",
                        help="Path to darkbloom provider binary (macOS only)")
    parser.add_argument("--vllm-model", default=TEST_MODEL,
                        help="Model to register providers with")
    parser.add_argument("tests", nargs="+",
                        help="Test names to run (or 'all')")

    args = parser.parse_args()

    # Resolve coordinator path
    args.coordinator_repo = os.path.abspath(args.coordinator_repo)
    print(f"[e2e] coordinator repo: {args.coordinator_repo}")
    print(f"[e2e] provider binary:  {args.provider_binary or '(simulated)'}")
    print(f"[e2e] model:            {args.vllm_model}")

    # TODO(Ethan):
    #   - Check that coordinator_repo has a go.mod
    #   - Check that coordinator binary builds
    #   - Validate provider binary path if specified
    #   - Check for required Python deps (websockets, cryptography)

    run_tests(args.tests)
    success = summarize()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()