"""FastAPI server exposing OpenAI-compatible /v1/images/generations endpoint.

Uses mflux (MLX-native diffusion) as the image generation backend.
The model is loaded once at startup and kept in memory between requests.
"""

import base64
import io
import logging
import time
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

logger = logging.getLogger("dginf_image_bridge")

# ---------------------------------------------------------------------------
# Request / response models (OpenAI images API format)
# ---------------------------------------------------------------------------


class ImageGenerationRequest(BaseModel):
    model: str
    prompt: str
    negative_prompt: Optional[str] = None
    n: int = Field(default=1, ge=1, le=4)
    size: str = "1024x1024"
    steps: Optional[int] = None
    seed: Optional[int] = None
    response_format: str = "b64_json"


class ImageDataResponse(BaseModel):
    b64_json: str


class ImageGenerationResponse(BaseModel):
    created: int
    data: list[ImageDataResponse]


# ---------------------------------------------------------------------------
# Backend abstraction
# ---------------------------------------------------------------------------


class ImageBackend:
    """Abstract interface for image generation backends."""

    def is_ready(self) -> bool:
        raise NotImplementedError

    def generate(
        self,
        prompt: str,
        negative_prompt: Optional[str],
        width: int,
        height: int,
        steps: int,
        seed: Optional[int],
        n: int,
    ) -> list[bytes]:
        """Generate n images, returning PNG bytes for each."""
        raise NotImplementedError

    def model_name(self) -> str:
        raise NotImplementedError


class MfluxBackend(ImageBackend):
    """Image generation backend using mflux (MLX-native FLUX implementation)."""

    def __init__(self, model: str, quantize: Optional[int] = 8):
        self._model_id = model
        self._quantize = quantize
        self._flux = None
        self._load_model()

    def _load_model(self):
        try:
            from mflux import Flux1

            # Map model IDs to mflux model names
            model_map = {
                "flux-klein-4b": "schnell",
                "flux-schnell": "schnell",
                "flux-dev": "dev",
                "z-image-turbo": "schnell",  # fallback
            }
            mflux_model = model_map.get(self._model_id, "schnell")

            logger.info(f"Loading mflux model: {mflux_model} (quantize={self._quantize})")
            self._flux = Flux1(
                model_name=mflux_model,
                quantize=self._quantize,
            )
            logger.info("mflux model loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load mflux model: {e}")
            self._flux = None

    def is_ready(self) -> bool:
        return self._flux is not None

    def model_name(self) -> str:
        return self._model_id

    def generate(
        self,
        prompt: str,
        negative_prompt: Optional[str],
        width: int,
        height: int,
        steps: int,
        seed: Optional[int],
        n: int,
    ) -> list[bytes]:
        if self._flux is None:
            raise RuntimeError("mflux model not loaded")

        images = []
        for i in range(n):
            current_seed = seed + i if seed is not None else None
            image = self._flux.generate_image(
                prompt=prompt,
                width=width,
                height=height,
                num_inference_steps=steps,
                seed=current_seed,
            )
            # Convert PIL Image to PNG bytes
            buf = io.BytesIO()
            image.save(buf, format="PNG")
            images.append(buf.getvalue())

        return images


# ---------------------------------------------------------------------------
# Application state
# ---------------------------------------------------------------------------

_backend: Optional[ImageBackend] = None


def get_backend() -> Optional[ImageBackend]:
    return _backend


def set_backend(backend: ImageBackend):
    global _backend
    _backend = backend


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------


def create_app(backend: Optional[ImageBackend] = None) -> FastAPI:
    """Create the FastAPI application with the given backend."""
    if backend is not None:
        set_backend(backend)

    app = FastAPI(title="DGInf Image Bridge", version="0.1.0")

    @app.get("/health")
    async def health():
        b = get_backend()
        if b is None or not b.is_ready():
            return JSONResponse(
                status_code=503,
                content={"status": "not_ready", "model": None},
            )
        return {"status": "ok", "model": b.model_name()}

    @app.post("/v1/images/generations")
    async def generate_images(req: ImageGenerationRequest):
        b = get_backend()
        if b is None or not b.is_ready():
            raise HTTPException(status_code=503, detail="image generation backend not ready")

        # Parse size
        try:
            parts = req.size.split("x")
            width, height = int(parts[0]), int(parts[1])
        except (ValueError, IndexError):
            raise HTTPException(status_code=400, detail=f"invalid size format: {req.size}")

        # Default steps based on model
        steps = req.steps
        if steps is None:
            steps = 4  # FLUX schnell default

        start = time.time()
        try:
            png_images = b.generate(
                prompt=req.prompt,
                negative_prompt=req.negative_prompt,
                width=width,
                height=height,
                steps=steps,
                seed=req.seed,
                n=req.n,
            )
        except Exception as e:
            logger.error(f"Image generation failed: {e}")
            raise HTTPException(status_code=500, detail=str(e))

        duration = time.time() - start
        logger.info(
            f"Generated {len(png_images)} image(s) in {duration:.2f}s "
            f"({width}x{height}, {steps} steps)"
        )

        # Encode as base64
        data = [
            ImageDataResponse(b64_json=base64.b64encode(img).decode("ascii"))
            for img in png_images
        ]

        return ImageGenerationResponse(
            created=int(time.time()),
            data=data,
        )

    return app
