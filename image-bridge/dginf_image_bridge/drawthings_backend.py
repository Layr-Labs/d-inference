"""Draw Things gRPC backend for image generation.

Connects to a running gRPCServerCLI instance via gRPC and translates
OpenAI-compatible requests into Draw Things' FlatBuffers + protobuf format.

The gRPCServerCLI binary must be running separately (managed by the Rust
provider or started manually for testing). This backend only handles the
gRPC client communication.
"""

import io
import logging
import os
import signal
import subprocess
import time
from typing import Optional

import flatbuffers
import grpc
import numpy as np
from PIL import Image

from .generated import imageService_pb2, imageService_pb2_grpc
from .generated.config_generated import GenerationConfigurationT, SamplerType
from .server import ImageBackend

logger = logging.getLogger("dginf_image_bridge.drawthings")

# Default gRPC port for Draw Things
DEFAULT_GRPC_PORT = 7859

# Memory reserved for macOS + other processes (GB)
_OS_RESERVE_GB = 4.0
_SAFETY_MARGIN_GB = 2.0

# Known model weight sizes in GB (used when --model-size-gb is not provided)
_MODEL_SIZES_GB: dict[str, float] = {
    "flux_2_klein_4b_q8p.ckpt": 8.1,
    "flux-klein-4b": 8.1,
    "flux_2_klein_9b_q8p.ckpt": 13.0,
    "flux-klein-9b": 13.0,
}

# Per-image batch overhead in GB at 1024x1024 resolution.
# Each additional image in a batch needs memory for intermediate activations
# (latent representations, attention K/V, UNet intermediates).
_BATCH_OVERHEAD_GB: dict[str, float] = {
    "flux_2_klein_4b_q8p.ckpt": 2.0,
    "flux-klein-4b": 2.0,
    "flux_2_klein_9b_q8p.ckpt": 3.5,
    "flux-klein-9b": 3.5,
}



def _detect_system_memory_gb() -> float:
    """Detect total system memory in GB using macOS sysctl."""
    try:
        output = subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip()
        return int(output) / (1024**3)
    except Exception:
        return 0.0


def compute_max_batch_size(
    system_memory_gb: float,
    model_size_gb: float,
    model_id: str,
    width: int = 1024,
    height: int = 1024,
) -> int:
    """Compute the maximum batch size that fits in available memory.

    Uses known per-image overhead for recognized models, or estimates
    at 25% of model weight size for unknown models. Overhead scales
    linearly with pixel count relative to 1024x1024.
    """
    if system_memory_gb <= 0:
        return 1

    per_image_base = _BATCH_OVERHEAD_GB.get(model_id, model_size_gb * 0.25)

    # Scale overhead by resolution relative to 1024x1024
    res_factor = (width * height) / (1024 * 1024)
    per_image = per_image_base * max(res_factor, 0.5)

    free = system_memory_gb - model_size_gb - _OS_RESERVE_GB - _SAFETY_MARGIN_GB
    if free <= 0 or per_image <= 0:
        return 1

    return max(1, int(free / per_image))


def build_config_bytes(
    width: int,
    height: int,
    steps: int,
    seed: int,
    model: str,
    guidance_scale: float = 3.5,
    batch_size: int = 1,
) -> bytes:
    """Build a FlatBuffers-serialized GenerationConfiguration for text-to-image."""
    config = GenerationConfigurationT()
    config.startWidth = width // 64
    config.startHeight = height // 64
    config.steps = steps
    config.seed = seed % 4294967295  # uint32 max
    config.guidanceScale = guidance_scale
    config.model = model
    config.sampler = SamplerType.EulerA
    config.seedMode = 0  # Legacy
    config.batchCount = 1
    config.batchSize = max(1, batch_size)
    config.resolutionDependentShift = True  # needed for FLUX models
    config.speedUpWithGuidanceEmbed = True

    builder = flatbuffers.Builder(0)
    builder.Finish(config.Pack(builder))
    return bytes(builder.Output())


def convert_response_image(response_image: bytes) -> Optional[Image.Image]:
    """Convert Draw Things raw tensor response to a PIL Image.

    Response format: 68-byte header followed by float16 pixel data.
    Header contains dimensions at uint32 offsets 6, 7, 8 (height, width, channels).
    Pixel values are in [-1, 1] range, converted to [0, 255] uint8.
    """
    if len(response_image) < 68:
        return None

    int_buffer = np.frombuffer(response_image, dtype=np.uint32, count=17)
    height, width, channels = int(int_buffer[6]), int(int_buffer[7]), int(int_buffer[8])

    if width <= 0 or height <= 0 or channels not in (3, 4):
        logger.error(f"Invalid image dimensions: {width}x{height}x{channels}")
        return None

    length = width * height * channels * 2  # float16 = 2 bytes
    pixel_data = response_image[68:]

    if len(pixel_data) < length:
        logger.error(f"Insufficient pixel data: got {len(pixel_data)}, expected {length}")
        return None

    data = np.frombuffer(pixel_data, dtype=np.float16, count=length // 2)
    # Convert from [-1, 1] to [0, 255]
    data = np.clip((data + 1) * 127, 0, 255).astype(np.uint8)

    mode = "RGBA" if channels == 4 else "RGB"
    return Image.frombytes(mode, (width, height), data.tobytes())


class DrawThingsBackend(ImageBackend):
    """Image generation backend using Draw Things gRPCServerCLI.

    Manages the gRPCServerCLI subprocess and communicates via gRPC.
    The model stays loaded in gRPCServerCLI between requests.

    Adaptive batching: when the system has enough free memory after loading
    the model, batch_size is increased (up to 4) so Draw Things generates
    multiple images in parallel on the GPU. The optimal batch size is
    computed from system_memory_gb, model_size_gb, and the request resolution.
    """

    def __init__(
        self,
        model: str,
        grpc_port: int = DEFAULT_GRPC_PORT,
        grpc_server_binary: Optional[str] = None,
        model_path: Optional[str] = None,
        system_memory_gb: float = 0,
        model_size_gb: float = 0,
    ):
        self._model_id = model
        self._grpc_port = grpc_port
        self._grpc_server_binary = grpc_server_binary or self._find_binary()
        self._model_path = model_path
        self._process: Optional[subprocess.Popen] = None
        self._channel = None
        self._stub = None
        self._ready = False

        self._system_memory_gb = system_memory_gb or _detect_system_memory_gb()
        self._model_size_gb = model_size_gb or _MODEL_SIZES_GB.get(model, 8.0)

        startup_batch = compute_max_batch_size(
            self._system_memory_gb, self._model_size_gb, model,
        )
        logger.info(
            "Adaptive batching: system=%.0f GB, model=%.1f GB, max_batch=%d",
            self._system_memory_gb, self._model_size_gb, startup_batch,
        )

    @staticmethod
    def _find_binary() -> str:
        """Find the gRPCServerCLI binary on the system."""
        candidates = [
            "/usr/local/bin/gRPCServerCLI-macOS",
            os.path.expanduser("~/.dginf/gRPCServerCLI-macOS"),
            "gRPCServerCLI-macOS",
        ]
        for path in candidates:
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path
        return "gRPCServerCLI-macOS"  # hope it's on PATH

    def start_server(self):
        """Start the gRPCServerCLI subprocess."""
        if self._process is not None:
            return

        if self._model_path is None:
            logger.warning("No model_path specified — assuming gRPCServerCLI is already running")
            return

        cmd = [
            self._grpc_server_binary,
            self._model_path,
            "--no-response-compression",
            "--port", str(self._grpc_port),
        ]
        logger.info(f"Starting gRPCServerCLI: {' '.join(cmd)}")

        self._process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        # Wait for gRPC port to become available
        for i in range(120):  # 2 minutes max
            try:
                channel = grpc.insecure_channel(
                    f"127.0.0.1:{self._grpc_port}",
                    options=[
                        ("grpc.max_send_message_length", -1),
                        ("grpc.max_receive_message_length", -1),
                    ],
                )
                stub = imageService_pb2_grpc.ImageGenerationServiceStub(channel)
                response = stub.Echo(imageService_pb2.EchoRequest(name="dginf"))
                logger.info(f"gRPCServerCLI ready: {response.message}")
                channel.close()
                return
            except grpc.RpcError:
                time.sleep(1)

        logger.error("gRPCServerCLI failed to start within 2 minutes")

    def stop_server(self):
        """Stop the gRPCServerCLI subprocess."""
        if self._process is not None:
            try:
                os.kill(self._process.pid, signal.SIGTERM)
                self._process.wait(timeout=10)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                self._process.kill()
            self._process = None

    def _connect(self):
        """Establish gRPC channel."""
        if self._channel is None:
            self._channel = grpc.insecure_channel(
                f"127.0.0.1:{self._grpc_port}",
                options=[
                    ("grpc.max_send_message_length", -1),
                    ("grpc.max_receive_message_length", -1),
                ],
            )
            self._stub = imageService_pb2_grpc.ImageGenerationServiceStub(self._channel)

    def _check_connection(self) -> bool:
        """Check if the gRPC server is reachable."""
        try:
            self._connect()
            self._stub.Echo(imageService_pb2.EchoRequest(name="dginf"))
            return True
        except grpc.RpcError:
            self._channel = None
            self._stub = None
            return False

    def is_ready(self) -> bool:
        return self._check_connection()

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
        import random

        self._connect()

        max_batch = compute_max_batch_size(
            self._system_memory_gb, self._model_size_gb,
            self._model_id, width, height,
        )

        images: list[bytes] = []
        offset = 0

        while len(images) < n:
            batch = min(n - len(images), max_batch)
            current_seed = (seed + offset) if seed is not None else random.randint(0, 2**32 - 1)

            config_bytes = build_config_bytes(
                width=width,
                height=height,
                steps=steps,
                seed=current_seed,
                model=self._model_id,
                batch_size=batch,
            )

            request = imageService_pb2.ImageGenerationRequest(
                prompt=prompt,
                negativePrompt=negative_prompt or "",
                configuration=config_bytes,
                scaleFactor=1,
                user="dginf-provider",
                device=imageService_pb2.LAPTOP,
            )

            if batch > 1:
                logger.info("Generating batch of %d images (max_batch=%d)", batch, max_batch)

            # Stream responses — collect all images from this batch
            batch_images: list[bytes] = []
            for response in self._stub.GenerateImage(request):
                if response.generatedImages:
                    for img_data in response.generatedImages:
                        pil_image = convert_response_image(img_data)
                        if pil_image is not None:
                            buf = io.BytesIO()
                            pil_image.save(buf, format="PNG")
                            batch_images.append(buf.getvalue())

                signpost = response.currentSignpost
                if signpost and signpost.HasField("sampling"):
                    logger.debug("Sampling step %d", signpost.sampling.step)

            if not batch_images:
                raise RuntimeError("gRPCServerCLI returned no images")

            images.extend(batch_images)
            offset += len(batch_images)

        return images[:n]
