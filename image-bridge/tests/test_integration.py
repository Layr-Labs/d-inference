"""Integration test: simulates the provider proxy calling the bridge.

Starts the bridge server on a random port, sends an OpenAI-format request
(the same way proxy.rs would), and verifies the full response chain.
"""

import base64
import io
import threading
import time

import httpx
import pytest
import uvicorn
from PIL import Image

from dginf_image_bridge.server import ImageBackend, create_app


class MockBackend(ImageBackend):
    """Generates small test PNGs."""

    def is_ready(self):
        return True

    def model_name(self):
        return "flux-klein-4b"

    def generate(self, prompt, negative_prompt, width, height, steps, seed, n):
        images = []
        for _ in range(n):
            img = Image.new("RGB", (width, height), color=(255, 0, 128))
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            images.append(buf.getvalue())
        return images


@pytest.fixture(scope="module")
def bridge_url():
    """Start the bridge on a random port and return its URL."""
    app = create_app(backend=MockBackend())

    # Find a free port
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]

    config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    # Wait for server to start
    url = f"http://127.0.0.1:{port}"
    for _ in range(50):
        try:
            httpx.get(f"{url}/health", timeout=1.0)
            break
        except httpx.ConnectError:
            time.sleep(0.1)

    yield url

    server.should_exit = True


class TestProxyIntegration:
    """Tests that simulate what the Rust provider proxy does."""

    def test_health_check(self, bridge_url):
        """Proxy checks /health before forwarding requests."""
        resp = httpx.get(f"{bridge_url}/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ok"
        assert data["model"] == "flux-klein-4b"

    def test_generate_image_like_proxy(self, bridge_url):
        """Simulate the exact JSON body that proxy.rs sends."""
        # This matches do_image_generation() in proxy.rs
        req_body = {
            "model": "flux-klein-4b",
            "prompt": "a beautiful sunset over mountains",
            "negative_prompt": None,
            "n": 1,
            "size": "512x512",
            "steps": 4,
            "seed": 42,
            "response_format": "b64_json",
        }

        resp = httpx.post(
            f"{bridge_url}/v1/images/generations",
            json=req_body,
            timeout=30.0,
        )
        assert resp.status_code == 200

        data = resp.json()
        assert "created" in data
        assert "data" in data
        assert len(data["data"]) == 1

        # Verify the image is valid
        img_b64 = data["data"][0]["b64_json"]
        img_bytes = base64.b64decode(img_b64)
        img = Image.open(io.BytesIO(img_bytes))
        assert img.size == (512, 512)
        assert img.format == "PNG"

    def test_generate_multiple_images(self, bridge_url):
        """Generate multiple images in one request."""
        resp = httpx.post(
            f"{bridge_url}/v1/images/generations",
            json={
                "model": "flux-klein-4b",
                "prompt": "test batch",
                "n": 3,
                "size": "256x256",
                "steps": 2,
            },
            timeout=30.0,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert len(data["data"]) == 3

        # All should be valid PNGs
        for item in data["data"]:
            img_bytes = base64.b64decode(item["b64_json"])
            img = Image.open(io.BytesIO(img_bytes))
            assert img.size == (256, 256)

    def test_error_handling(self, bridge_url):
        """Invalid request should return proper error."""
        resp = httpx.post(
            f"{bridge_url}/v1/images/generations",
            json={
                "model": "flux-klein-4b",
                "prompt": "test",
                "size": "not-a-size",
            },
            timeout=10.0,
        )
        assert resp.status_code == 400
