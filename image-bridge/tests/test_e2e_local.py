"""
End-to-end local test for the image generation pipeline.

Tests the full stack: gRPCServerCLI → image bridge → HTTP API.
Requires model files downloaded locally. Skipped in CI.

Usage:
    PYTHONPATH=. pytest tests/test_e2e_local.py -v --timeout=300

Prereqs:
    - gRPCServerCLI binary (built from draw-things-community)
    - FLUX model files in /tmp/flux-klein-4b-complete/ or /tmp/flux-klein-9b-complete/
"""

import os
import sys
import time
import signal
import subprocess
import json
import base64
import pytest
import httpx

# Skip in CI — these need local GPU + model files
pytestmark = pytest.mark.skipif(
    os.environ.get("CI") == "true" or os.environ.get("GITHUB_ACTIONS") == "true",
    reason="Requires local GPU and model files"
)

GRPC_SERVER_CLI = os.path.expanduser("~/.eigeninference/bin/gRPCServerCLI")
if not os.path.exists(GRPC_SERVER_CLI):
    # Try build output
    alt = "/tmp/draw-things-community/.build/arm64-apple-macosx/release/gRPCServerCLI"
    if os.path.exists(alt):
        GRPC_SERVER_CLI = alt

# Prefer 4B (faster, smaller) for testing
MODEL_DIR_4B = "/tmp/flux-klein-4b-complete"
MODEL_DIR_9B = "/tmp/flux-klein-9b-complete"

def find_model_dir():
    """Find a complete model directory for testing."""
    for d in [MODEL_DIR_4B, MODEL_DIR_9B]:
        if not os.path.isdir(d):
            continue
        files = os.listdir(d)
        has_model = any(f.endswith(".ckpt") and "klein" in f for f in files)
        has_vae = "flux_2_vae_f16.ckpt" in files
        has_encoder = any(f.startswith("qwen_3_") and f.endswith(".ckpt") for f in files)
        has_meta = "models.json" in files
        if has_model and has_vae and has_encoder and has_meta:
            return d
    return None


MODEL_DIR = find_model_dir()

BRIDGE_PORT = 19876
GRPC_PORT = 19877


@pytest.fixture(scope="module")
def grpc_server():
    """Start gRPCServerCLI as a subprocess for the test session."""
    if not os.path.exists(GRPC_SERVER_CLI):
        pytest.skip(f"gRPCServerCLI not found at {GRPC_SERVER_CLI}")
    if MODEL_DIR is None:
        pytest.skip("No complete model directory found")

    proc = subprocess.Popen(
        [GRPC_SERVER_CLI, MODEL_DIR, "--port", str(GRPC_PORT), "--no-tls"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    # Wait for server to be ready (check TCP port)
    start = time.time()
    ready = False
    while time.time() - start < 180:  # 3 min timeout for model loading
        import socket
        try:
            s = socket.create_connection(("127.0.0.1", GRPC_PORT), timeout=2)
            s.close()
            ready = True
            break
        except (ConnectionRefusedError, OSError):
            time.sleep(2)

    if not ready:
        proc.kill()
        stdout = proc.stdout.read().decode() if proc.stdout else ""
        pytest.fail(f"gRPCServerCLI failed to start within 180s.\nOutput: {stdout[:1000]}")

    yield proc

    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()


@pytest.fixture(scope="module")
def bridge_server(grpc_server):
    """Start the image bridge pointing at the gRPC server."""
    # Find Python with the bridge deps
    python = os.path.expanduser("~/.eigeninference/python/bin/python3.12")
    if not os.path.exists(python):
        python = sys.executable

    bridge_src = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "eigeninference_image_bridge",
    )

    # Determine model name from files
    model_files = [f for f in os.listdir(MODEL_DIR) if "klein" in f and f.endswith(".ckpt")]
    model_name = model_files[0] if model_files else "flux_2_klein_4b_q8p.ckpt"

    env = os.environ.copy()
    env["PYTHONPATH"] = os.path.dirname(bridge_src)
    if os.path.exists(os.path.expanduser("~/.eigeninference/python")):
        env["PYTHONHOME"] = os.path.expanduser("~/.eigeninference/python")

    proc = subprocess.Popen(
        [
            python, "-m", "eigeninference_image_bridge",
            "--port", str(BRIDGE_PORT),
            "--grpc-port", str(GRPC_PORT),
            "--model", model_name,
            "--system-memory-gb", "24",
        ],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    # Wait for bridge HTTP server
    start = time.time()
    ready = False
    while time.time() - start < 30:
        try:
            r = httpx.get(f"http://127.0.0.1:{BRIDGE_PORT}/health", timeout=2)
            if r.status_code == 200:
                ready = True
                break
        except httpx.ConnectError:
            time.sleep(1)

    if not ready:
        proc.kill()
        stdout = proc.stdout.read().decode() if proc.stdout else ""
        pytest.fail(f"Image bridge failed to start within 30s.\nOutput: {stdout[:1000]}")

    yield proc

    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


class TestImageBridgeE2E:
    """End-to-end tests for the image generation pipeline."""

    def test_health(self, bridge_server):
        """Bridge health endpoint returns 200."""
        r = httpx.get(f"http://127.0.0.1:{BRIDGE_PORT}/health", timeout=5)
        assert r.status_code == 200

    def test_generate_image_512(self, bridge_server):
        """Generate a 512x512 image."""
        r = httpx.post(
            f"http://127.0.0.1:{BRIDGE_PORT}/v1/images/generations",
            json={
                "prompt": "a red apple on a white table",
                "size": "512x512",
                "n": 1,
                "steps": 2,  # minimal steps for speed
                "response_format": "b64_json",
            },
            timeout=120,
        )
        assert r.status_code == 200
        data = r.json()
        assert "data" in data
        assert len(data["data"]) == 1
        # Verify it's valid base64 PNG
        img_b64 = data["data"][0]["b64_json"]
        img_bytes = base64.b64decode(img_b64)
        assert img_bytes[:8] == b"\x89PNG\r\n\x1a\n", "Not a valid PNG"
        assert len(img_bytes) > 1000, "Image too small"
        print(f"  Generated 512x512 image: {len(img_bytes)} bytes")

    def test_generate_image_1024(self, bridge_server):
        """Generate a 1024x1024 image."""
        r = httpx.post(
            f"http://127.0.0.1:{BRIDGE_PORT}/v1/images/generations",
            json={
                "prompt": "a mountain landscape at sunset, photorealistic",
                "size": "1024x1024",
                "n": 1,
                "steps": 2,
                "response_format": "b64_json",
            },
            timeout=180,
        )
        assert r.status_code == 200
        data = r.json()
        assert len(data["data"]) == 1
        img_bytes = base64.b64decode(data["data"][0]["b64_json"])
        assert img_bytes[:8] == b"\x89PNG\r\n\x1a\n"
        print(f"  Generated 1024x1024 image: {len(img_bytes)} bytes")

    def test_generate_multiple(self, bridge_server):
        """Generate 2 images in one request."""
        r = httpx.post(
            f"http://127.0.0.1:{BRIDGE_PORT}/v1/images/generations",
            json={
                "prompt": "a blue cat",
                "size": "512x512",
                "n": 2,
                "steps": 2,
                "response_format": "b64_json",
            },
            timeout=180,
        )
        assert r.status_code == 200
        data = r.json()
        assert len(data["data"]) == 2
        for d in data["data"]:
            img_bytes = base64.b64decode(d["b64_json"])
            assert img_bytes[:8] == b"\x89PNG\r\n\x1a\n"
        print(f"  Generated 2 images")

    def test_invalid_size_rejected(self, bridge_server):
        """Oversized dimensions should be rejected."""
        r = httpx.post(
            f"http://127.0.0.1:{BRIDGE_PORT}/v1/images/generations",
            json={
                "prompt": "test",
                "size": "4096x4096",
                "n": 1,
            },
            timeout=10,
        )
        assert r.status_code in (400, 422)

    def test_empty_prompt_rejected(self, bridge_server):
        """Empty prompt should be rejected."""
        r = httpx.post(
            f"http://127.0.0.1:{BRIDGE_PORT}/v1/images/generations",
            json={
                "prompt": "",
                "size": "512x512",
                "n": 1,
            },
            timeout=10,
        )
        assert r.status_code in (400, 422)
