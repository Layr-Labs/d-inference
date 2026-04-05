"""FastAPI server exposing OpenAI-compatible /v1/images/generations endpoint.

Uses Draw Things gRPCServerCLI as the image generation backend, managed
as a subprocess. The model stays loaded in gRPCServerCLI between requests.
Metal FlashAttention provides 43-120% faster generation than alternatives.
"""

import base64
import logging
import time
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

logger = logging.getLogger("eigeninference_image_bridge")

# ---------------------------------------------------------------------------
# Request / response models (OpenAI images API format)
# ---------------------------------------------------------------------------


class ImageGenerationRequest(BaseModel):
    model: str
    prompt: str
    negative_prompt: Optional[str] = None
    n: int = Field(default=1, ge=1)
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
# Backend interface
# ---------------------------------------------------------------------------


class ImageBackend:
    """Interface for image generation backends."""

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

    app = FastAPI(title="EigenInference Image Bridge", version="0.1.0")

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
