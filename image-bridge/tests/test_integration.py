"""Integration test: simulates the provider proxy calling the bridge.

Starts a mock gRPC server (standing in for gRPCServerCLI), then starts the
bridge server backed by DrawThingsBackend, and sends HTTP requests the same
way proxy.rs would.
"""

import base64
import io
import threading
import time
from concurrent import futures

import grpc
import httpx
import numpy as np
import pytest
import uvicorn
from PIL import Image

from eigeninference_image_bridge.drawthings_backend import DrawThingsBackend
from eigeninference_image_bridge.generated import imageService_pb2, imageService_pb2_grpc
from eigeninference_image_bridge.server import create_app


def make_test_response_image(width: int, height: int, channels: int = 3) -> bytes:
    """Build a fake Draw Things image response with correct header format."""
    header = np.zeros(17, dtype=np.uint32)
    header[6] = height
    header[7] = width
    header[8] = channels
    pixels = np.zeros(width * height * channels, dtype=np.float16)
    return header.tobytes() + pixels.tobytes()


class MockGRPCServicer(imageService_pb2_grpc.ImageGenerationServiceServicer):
    def Echo(self, request, context):
        return imageService_pb2.EchoReply(message="mock-grpc")

    def GenerateImage(self, request, context):
        yield imageService_pb2.ImageGenerationResponse(
            generatedImages=[make_test_response_image(64, 64, 3)],
        )


@pytest.fixture(scope="module")
def bridge_url():
    """Start mock gRPC server + bridge HTTP server, return the bridge URL."""
    # Start mock gRPC server
    grpc_server = grpc.server(futures.ThreadPoolExecutor(max_workers=2))
    imageService_pb2_grpc.add_ImageGenerationServiceServicer_to_server(
        MockGRPCServicer(), grpc_server
    )
    grpc_port = grpc_server.add_insecure_port("127.0.0.1:0")
    grpc_server.start()

    # Create bridge backed by DrawThingsBackend pointing at mock gRPC
    backend = DrawThingsBackend(model="flux-klein-4b", grpc_port=grpc_port)
    app = create_app(backend=backend)

    # Find a free HTTP port
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        http_port = s.getsockname()[1]

    config = uvicorn.Config(app, host="127.0.0.1", port=http_port, log_level="error")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    url = f"http://127.0.0.1:{http_port}"
    for _ in range(50):
        try:
            httpx.get(f"{url}/health", timeout=1.0)
            break
        except httpx.ConnectError:
            time.sleep(0.1)

    yield url

    server.should_exit = True
    grpc_server.stop(grace=1)


class TestProxyIntegration:
    """Tests that simulate what the Rust provider proxy does."""

    def test_health_check(self, bridge_url):
        resp = httpx.get(f"{bridge_url}/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ok"
        assert data["model"] == "flux-klein-4b"

    def test_generate_image_like_proxy(self, bridge_url):
        """Simulate the exact JSON body that proxy.rs sends."""
        resp = httpx.post(
            f"{bridge_url}/v1/images/generations",
            json={
                "model": "flux-klein-4b",
                "prompt": "a beautiful sunset over mountains",
                "negative_prompt": None,
                "n": 1,
                "size": "64x64",
                "steps": 4,
                "seed": 42,
                "response_format": "b64_json",
            },
            timeout=30.0,
        )
        assert resp.status_code == 200

        data = resp.json()
        assert "created" in data
        assert len(data["data"]) == 1

        img_bytes = base64.b64decode(data["data"][0]["b64_json"])
        img = Image.open(io.BytesIO(img_bytes))
        assert img.size == (64, 64)
        assert img.format == "PNG"

    def test_generate_multiple_images(self, bridge_url):
        resp = httpx.post(
            f"{bridge_url}/v1/images/generations",
            json={
                "model": "flux-klein-4b",
                "prompt": "test batch",
                "n": 3,
                "size": "64x64",
                "steps": 2,
            },
            timeout=30.0,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert len(data["data"]) == 3

        for item in data["data"]:
            img_bytes = base64.b64decode(item["b64_json"])
            img = Image.open(io.BytesIO(img_bytes))
            assert img.size == (64, 64)

    def test_error_handling(self, bridge_url):
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
