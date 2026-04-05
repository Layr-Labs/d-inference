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
    compute_max_batch_size,
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

    def test_batch_size_in_config(self):
        """batch_size parameter should be encoded in FlatBuffers config."""
        from dginf_image_bridge.generated.config_generated import GenerationConfiguration

        data = build_config_bytes(
            width=1024, height=1024, steps=4, seed=1, model="test",
            batch_size=3,
        )
        config = GenerationConfiguration.GetRootAs(data, 0)
        assert config.BatchSize() == 3

    def test_batch_size_passthrough(self):
        """Any batch_size value should be passed through to FlatBuffer."""
        from dginf_image_bridge.generated.config_generated import GenerationConfiguration

        data = build_config_bytes(
            width=1024, height=1024, steps=4, seed=1, model="test",
            batch_size=30,
        )
        config = GenerationConfiguration.GetRootAs(data, 0)
        assert config.BatchSize() == 30

    def test_default_batch_size_is_one(self):
        """Default batch_size should be 1 for backwards compatibility."""
        from dginf_image_bridge.generated.config_generated import GenerationConfiguration

        data = build_config_bytes(
            width=1024, height=1024, steps=4, seed=1, model="test",
        )
        config = GenerationConfiguration.GetRootAs(data, 0)
        assert config.BatchSize() == 1


# ---------------------------------------------------------------------------
# Adaptive batch size computation tests
# ---------------------------------------------------------------------------


class TestComputeMaxBatchSize:
    def test_flux_4b_on_16gb(self):
        """16 GB barely fits the model — batch=1."""
        batch = compute_max_batch_size(16, 8.1, "flux-klein-4b")
        assert batch == 1

    def test_flux_4b_on_36gb(self):
        """36 GB has plenty of headroom — high batch."""
        batch = compute_max_batch_size(36, 8.1, "flux-klein-4b")
        # free = 36 - 8.1 - 4 - 2 = 21.9, overhead = 2.0 → 10
        assert batch == 10

    def test_flux_4b_on_24gb(self):
        """24 GB should allow batch >= 2."""
        batch = compute_max_batch_size(24, 8.1, "flux-klein-4b")
        assert batch >= 2

    def test_flux_9b_on_24gb(self):
        """24 GB with 13 GB model — tight, batch=1-2."""
        batch = compute_max_batch_size(24, 13.0, "flux-klein-9b")
        assert batch >= 1
        assert batch <= 2

    def test_flux_9b_on_48gb(self):
        """48 GB has lots of room — high batch."""
        batch = compute_max_batch_size(48, 13.0, "flux-klein-9b")
        # free = 48 - 13 - 4 - 2 = 29, overhead = 3.5 → 8
        assert batch == 8

    def test_zero_memory_returns_one(self):
        batch = compute_max_batch_size(0, 8.0, "unknown")
        assert batch == 1

    def test_model_larger_than_memory(self):
        batch = compute_max_batch_size(8, 12.0, "big-model")
        assert batch == 1

    def test_scales_with_memory(self):
        """Batch size grows with available memory — no artificial cap."""
        batch = compute_max_batch_size(512, 8.0, "flux-klein-4b")
        # free = 512 - 8 - 4 - 2 = 498, overhead = 2.0 → 249
        assert batch == 249

    def test_higher_resolution_reduces_batch(self):
        """2048x2048 uses 4x the activation memory of 1024x1024."""
        batch_1k = compute_max_batch_size(36, 8.1, "flux-klein-4b", 1024, 1024)
        batch_2k = compute_max_batch_size(36, 8.1, "flux-klein-4b", 2048, 2048)
        assert batch_2k <= batch_1k

    def test_lower_resolution_allows_more_batching(self):
        """512x512 uses less activation memory, allowing larger batches."""
        batch_512 = compute_max_batch_size(24, 8.1, "flux-klein-4b", 512, 512)
        batch_1k = compute_max_batch_size(24, 8.1, "flux-klein-4b", 1024, 1024)
        assert batch_512 >= batch_1k

    def test_unknown_model_uses_default_overhead(self):
        """Unknown models use 25% of model size as per-image overhead."""
        batch = compute_max_batch_size(36, 10.0, "unknown-model")
        # free = 36 - 10 - 4 - 2 = 20, overhead = 10*0.25 = 2.5, batch = 20/2.5 = 8
        assert batch == 8


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
        # Parse batch_size from FlatBuffers config to simulate real Draw Things behavior
        batch_size = 1
        if request.configuration:
            try:
                from dginf_image_bridge.generated.config_generated import GenerationConfiguration
                config = GenerationConfiguration.GetRootAs(request.configuration, 0)
                batch_size = max(1, config.BatchSize())
            except Exception:
                pass

        width, height, channels = 64, 64, 3
        raw_images = [make_test_response_image(width, height, channels) for _ in range(batch_size)]

        response = imageService_pb2.ImageGenerationResponse(
            generatedImages=raw_images,
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

    def test_generate_batched(self, mock_grpc_server):
        """With enough memory, n=4 images should use batching."""
        backend = DrawThingsBackend(
            model="flux-klein-4b",
            grpc_port=mock_grpc_server,
            system_memory_gb=24,  # enough for batch > 1
            model_size_gb=8.1,
        )
        images = backend.generate(
            prompt="batch test",
            negative_prompt=None,
            width=64,
            height=64,
            steps=1,
            seed=1,
            n=4,
        )
        assert len(images) == 4
        for img_bytes in images:
            img = Image.open(io.BytesIO(img_bytes))
            assert img.format == "PNG"

    def test_generate_low_memory_sequential(self, mock_grpc_server):
        """With low memory, images should be generated one at a time."""
        backend = DrawThingsBackend(
            model="flux-klein-4b",
            grpc_port=mock_grpc_server,
            system_memory_gb=16,  # tight memory
            model_size_gb=8.1,
        )
        images = backend.generate(
            prompt="sequential test",
            negative_prompt=None,
            width=64,
            height=64,
            steps=1,
            seed=1,
            n=3,
        )
        assert len(images) == 3

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
