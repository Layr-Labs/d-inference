"""Tests for the image bridge server.

Uses a mock backend so tests run without gRPCServerCLI/GPU dependencies.
"""

import base64
import io
import time

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from eigeninference_image_bridge.server import (
    ImageBackend,
    ImageGenerationRequest,
    create_app,
)


class MockBackend(ImageBackend):
    """Mock backend that generates solid-color PNG images for testing."""

    def __init__(self, ready: bool = True, fail: bool = False):
        self._ready = ready
        self._fail = fail
        self._calls: list[dict] = []

    def is_ready(self) -> bool:
        return self._ready

    def model_name(self) -> str:
        return "mock-model"

    def generate(self, prompt, negative_prompt, width, height, steps, seed, n):
        self._calls.append({
            "prompt": prompt,
            "negative_prompt": negative_prompt,
            "width": width,
            "height": height,
            "steps": steps,
            "seed": seed,
            "n": n,
        })

        if self._fail:
            raise RuntimeError("mock generation failure")

        images = []
        for i in range(n):
            # Create a small test image
            img = Image.new("RGB", (width, height), color=(100 + i * 50, 50, 200))
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            images.append(buf.getvalue())
        return images


@pytest.fixture
def mock_backend():
    return MockBackend()


@pytest.fixture
def client(mock_backend):
    app = create_app(backend=mock_backend)
    return TestClient(app)


@pytest.fixture
def failing_client():
    app = create_app(backend=MockBackend(fail=True))
    return TestClient(app)


@pytest.fixture
def unready_client():
    app = create_app(backend=MockBackend(ready=False))
    return TestClient(app)


# ---------------------------------------------------------------------------
# Health endpoint tests
# ---------------------------------------------------------------------------


class TestHealth:
    def test_health_ok(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ok"
        assert data["model"] == "mock-model"

    def test_health_not_ready(self, unready_client):
        resp = unready_client.get("/health")
        assert resp.status_code == 503
        data = resp.json()
        assert data["status"] == "not_ready"

    def test_health_no_backend(self):
        app = create_app(backend=None)
        client = TestClient(app)
        resp = client.get("/health")
        assert resp.status_code == 503


# ---------------------------------------------------------------------------
# Image generation endpoint tests
# ---------------------------------------------------------------------------


class TestImageGeneration:
    def test_basic_generation(self, client, mock_backend):
        resp = client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "a cat wearing a hat",
        })
        assert resp.status_code == 200
        data = resp.json()

        assert "created" in data
        assert len(data["data"]) == 1
        assert "b64_json" in data["data"][0]

        # Verify it's valid base64 PNG
        img_bytes = base64.b64decode(data["data"][0]["b64_json"])
        img = Image.open(io.BytesIO(img_bytes))
        assert img.size == (1024, 1024)  # default size

        # Verify backend was called correctly
        assert len(mock_backend._calls) == 1
        call = mock_backend._calls[0]
        assert call["prompt"] == "a cat wearing a hat"
        assert call["width"] == 1024
        assert call["height"] == 1024
        assert call["steps"] == 4  # default
        assert call["n"] == 1

    def test_custom_size(self, client, mock_backend):
        resp = client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "landscape",
            "size": "512x512",
        })
        assert resp.status_code == 200
        call = mock_backend._calls[0]
        assert call["width"] == 512
        assert call["height"] == 512

    def test_custom_steps_and_seed(self, client, mock_backend):
        resp = client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "test",
            "steps": 20,
            "seed": 42,
        })
        assert resp.status_code == 200
        call = mock_backend._calls[0]
        assert call["steps"] == 20
        assert call["seed"] == 42

    def test_negative_prompt(self, client, mock_backend):
        resp = client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "beautiful sunset",
            "negative_prompt": "blurry, watermark",
        })
        assert resp.status_code == 200
        call = mock_backend._calls[0]
        assert call["negative_prompt"] == "blurry, watermark"

    def test_multiple_images(self, client, mock_backend):
        resp = client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "test",
            "n": 3,
        })
        assert resp.status_code == 200
        data = resp.json()
        assert len(data["data"]) == 3

        # Each should be a valid PNG
        for item in data["data"]:
            img_bytes = base64.b64decode(item["b64_json"])
            img = Image.open(io.BytesIO(img_bytes))
            assert img.format == "PNG"

    def test_invalid_size_format(self, client):
        resp = client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "test",
            "size": "invalid",
        })
        assert resp.status_code == 400

    def test_missing_prompt(self, client):
        resp = client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
        })
        assert resp.status_code == 422  # pydantic validation

    def test_missing_model(self, client):
        resp = client.post("/v1/images/generations", json={
            "prompt": "test",
        })
        assert resp.status_code == 422

    def test_backend_failure(self, failing_client):
        resp = failing_client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "test",
        })
        assert resp.status_code == 500
        assert "mock generation failure" in resp.json()["detail"]

    def test_backend_not_ready(self, unready_client):
        resp = unready_client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "test",
        })
        assert resp.status_code == 503

    def test_response_format(self, client):
        resp = client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "test",
        })
        data = resp.json()
        # Matches OpenAI images API format
        assert isinstance(data["created"], int)
        assert abs(data["created"] - int(time.time())) < 5
        assert isinstance(data["data"], list)
        assert all("b64_json" in item for item in data["data"])

    def test_rectangular_size(self, client, mock_backend):
        resp = client.post("/v1/images/generations", json={
            "model": "flux-klein-4b",
            "prompt": "portrait",
            "size": "768x1024",
        })
        assert resp.status_code == 200
        call = mock_backend._calls[0]
        assert call["width"] == 768
        assert call["height"] == 1024


# ---------------------------------------------------------------------------
# Request model tests
# ---------------------------------------------------------------------------


class TestRequestModel:
    def test_defaults(self):
        req = ImageGenerationRequest(model="test", prompt="hello")
        assert req.n == 1
        assert req.size == "1024x1024"
        assert req.response_format == "b64_json"
        assert req.steps is None
        assert req.seed is None
        assert req.negative_prompt is None

    def test_all_fields(self):
        req = ImageGenerationRequest(
            model="flux-klein-4b",
            prompt="a dog",
            negative_prompt="blurry",
            n=2,
            size="512x512",
            steps=8,
            seed=123,
            response_format="b64_json",
        )
        assert req.model == "flux-klein-4b"
        assert req.prompt == "a dog"
        assert req.negative_prompt == "blurry"
        assert req.n == 2
        assert req.steps == 8
        assert req.seed == 123
