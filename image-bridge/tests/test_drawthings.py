"""Tests for the Draw Things gRPC backend.

Tests FlatBuffers config construction and image response decoding.
Also includes a mock gRPC server test for the full generate flow.
"""

import io
import struct
import threading
import time
from concurrent import futures

import grpc
import numpy as np
import pytest
from PIL import Image

from dginf_image_bridge.drawthings_backend import (
    DrawThingsBackend,
    build_config_bytes,
    convert_response_image,
)
from dginf_image_bridge.generated import imageService_pb2, imageService_pb2_grpc


# ---------------------------------------------------------------------------
# FlatBuffers config tests
# ---------------------------------------------------------------------------


class TestBuildConfig:
    def test_basic_config(self):
        """Config bytes should be non-empty valid FlatBuffers data."""
        data = build_config_bytes(
            width=1024, height=1024, steps=4, seed=42, model="flux-schnell"
        )
        assert isinstance(data, bytes)
        assert len(data) > 0

    def test_different_sizes(self):
        """Different dimensions should produce different configs."""
        a = build_config_bytes(width=512, height=512, steps=4, seed=1, model="test")
        b = build_config_bytes(width=1024, height=1024, steps=4, seed=1, model="test")
        assert a != b

    def test_different_seeds(self):
        """Different seeds should produce different configs."""
        a = build_config_bytes(width=512, height=512, steps=4, seed=1, model="test")
        b = build_config_bytes(width=512, height=512, steps=4, seed=2, model="test")
        assert a != b

    def test_config_deserializable(self):
        """Config bytes should be valid FlatBuffers that can be read back."""
        import flatbuffers
        from dginf_image_bridge.generated.config_generated import GenerationConfiguration

        data = build_config_bytes(
            width=768, height=1024, steps=20, seed=123, model="flux-dev"
        )
        # Should not raise
        config = GenerationConfiguration.GetRootAs(data, 0)
        assert config.StartWidth() == 768 // 64  # 12
        assert config.StartHeight() == 1024 // 64  # 16
        assert config.Steps() == 20
        assert config.Seed() == 123


# ---------------------------------------------------------------------------
# Image response decoding tests
# ---------------------------------------------------------------------------


def make_test_response_image(width: int, height: int, channels: int = 3) -> bytes:
    """Build a fake Draw Things image response with the correct header format.

    Header: 68 bytes (17 uint32 values)
      - [6] = height, [7] = width, [8] = channels
    Body: float16 pixel data in [-1, 1] range
    """
    header = np.zeros(17, dtype=np.uint32)
    header[6] = height
    header[7] = width
    header[8] = channels

    # Generate pixel data: all zeros = mid-gray after conversion
    pixel_count = width * height * channels
    pixels = np.zeros(pixel_count, dtype=np.float16)

    return header.tobytes() + pixels.tobytes()


class TestConvertResponseImage:
    def test_basic_decode(self):
        raw = make_test_response_image(64, 64, 3)
        img = convert_response_image(raw)
        assert img is not None
        assert img.size == (64, 64)
        assert img.mode == "RGB"

    def test_rgba_decode(self):
        raw = make_test_response_image(32, 32, 4)
        img = convert_response_image(raw)
        assert img is not None
        assert img.mode == "RGBA"

    def test_pixel_values(self):
        """Pixels at 0.0 should map to 127 (mid-gray)."""
        raw = make_test_response_image(2, 2, 3)
        img = convert_response_image(raw)
        px = np.array(img)
        assert np.all(px == 127)

    def test_white_pixels(self):
        """Pixels at 1.0 should map to 254 (near-white)."""
        header = np.zeros(17, dtype=np.uint32)
        header[6] = 2
        header[7] = 2
        header[8] = 3
        pixels = np.ones(2 * 2 * 3, dtype=np.float16)
        raw = header.tobytes() + pixels.tobytes()
        img = convert_response_image(raw)
        px = np.array(img)
        assert np.all(px == 254)

    def test_too_small_data(self):
        assert convert_response_image(b"too short") is None

    def test_zero_dimensions(self):
        header = np.zeros(17, dtype=np.uint32)
        assert convert_response_image(header.tobytes()) is None


# ---------------------------------------------------------------------------
# Mock gRPC server for integration test
# ---------------------------------------------------------------------------


class MockImageGenerationServicer(imageService_pb2_grpc.ImageGenerationServiceServicer):
    """Mock gRPC server that returns a test image."""

    def Echo(self, request, context):
        return imageService_pb2.EchoReply(message="mock-server")

    def GenerateImage(self, request, context):
        # Parse dimensions from the request config
        # For simplicity, generate a fixed 64x64 RGB image
        width, height, channels = 64, 64, 3
        raw_image = make_test_response_image(width, height, channels)

        response = imageService_pb2.ImageGenerationResponse(
            generatedImages=[raw_image],
        )
        yield response


@pytest.fixture(scope="module")
def mock_grpc_server():
    """Start a mock gRPC server and return the port."""
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=2))
    imageService_pb2_grpc.add_ImageGenerationServiceServicer_to_server(
        MockImageGenerationServicer(), server
    )
    port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    yield port
    server.stop(grace=1)


class TestDrawThingsBackendWithMockServer:
    def test_is_ready(self, mock_grpc_server):
        backend = DrawThingsBackend(model="flux-klein-4b", grpc_port=mock_grpc_server)
        assert backend.is_ready()

    def test_generate_single_image(self, mock_grpc_server):
        backend = DrawThingsBackend(model="flux-klein-4b", grpc_port=mock_grpc_server)
        images = backend.generate(
            prompt="a test image",
            negative_prompt=None,
            width=64,
            height=64,
            steps=1,
            seed=42,
            n=1,
        )
        assert len(images) == 1
        # Should be valid PNG
        img = Image.open(io.BytesIO(images[0]))
        assert img.format == "PNG"
        assert img.size == (64, 64)

    def test_generate_multiple_images(self, mock_grpc_server):
        backend = DrawThingsBackend(model="flux-klein-4b", grpc_port=mock_grpc_server)
        images = backend.generate(
            prompt="batch test",
            negative_prompt="blurry",
            width=64,
            height=64,
            steps=2,
            seed=100,
            n=3,
        )
        assert len(images) == 3
        for img_bytes in images:
            img = Image.open(io.BytesIO(img_bytes))
            assert img.format == "PNG"

    def test_not_ready_wrong_port(self):
        backend = DrawThingsBackend(model="test", grpc_port=19999)
        assert not backend.is_ready()


class TestDrawThingsFullStack:
    """Test the full HTTP → DrawThingsBackend → mock gRPC → response flow."""

    def test_http_to_grpc_flow(self, mock_grpc_server):
        from fastapi.testclient import TestClient
        from dginf_image_bridge.server import create_app

        backend = DrawThingsBackend(model="flux-klein-4b", grpc_port=mock_grpc_server)
        app = create_app(backend=backend)
        client = TestClient(app)

        resp = client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "test via draw things grpc",
            "size": "64x64",
            "steps": 1,
            "seed": 42,
        })
        assert resp.status_code == 200
        data = resp.json()
        assert len(data["data"]) == 1
        assert "b64_json" in data["data"][0]

        # Verify the image is valid
        import base64
        img_bytes = base64.b64decode(data["data"][0]["b64_json"])
        img = Image.open(io.BytesIO(img_bytes))
        assert img.size == (64, 64)
        assert img.format == "PNG"
