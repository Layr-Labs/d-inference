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


def build_config_bytes(
    width: int,
    height: int,
    steps: int,
    seed: int,
    model: str,
    guidance_scale: float = 3.5,
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
    config.batchSize = 1
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
    """

    def __init__(
        self,
        model: str,
        grpc_port: int = DEFAULT_GRPC_PORT,
        grpc_server_binary: Optional[str] = None,
        model_path: Optional[str] = None,
    ):
        self._model_id = model
        self._grpc_port = grpc_port
        self._grpc_server_binary = grpc_server_binary or self._find_binary()
        self._model_path = model_path
        self._process: Optional[subprocess.Popen] = None
        self._channel = None
        self._stub = None
        self._ready = False

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

        images = []
        for i in range(n):
            current_seed = (seed + i) if seed is not None else random.randint(0, 2**32 - 1)

            # Build FlatBuffers config
            config_bytes = build_config_bytes(
                width=width,
                height=height,
                steps=steps,
                seed=current_seed,
                model=self._model_id,
            )

            # Build gRPC request
            request = imageService_pb2.ImageGenerationRequest(
                prompt=prompt,
                negativePrompt=negative_prompt or "",
                configuration=config_bytes,
                scaleFactor=1,
                user="dginf-provider",
                device=imageService_pb2.LAPTOP,
            )

            # Stream responses, collect final image
            generated_image = None
            for response in self._stub.GenerateImage(request):
                if response.generatedImages:
                    for img_data in response.generatedImages:
                        generated_image = img_data

                # Log progress
                signpost = response.currentSignpost
                if signpost and signpost.HasField("sampling"):
                    logger.debug(f"Sampling step {signpost.sampling.step}")

            if generated_image is None:
                raise RuntimeError("gRPCServerCLI returned no images")

            # Convert raw tensor to PIL Image, then to PNG bytes
            pil_image = convert_response_image(generated_image)
            if pil_image is None:
                raise RuntimeError("Failed to decode image from gRPCServerCLI response")

            buf = io.BytesIO()
            pil_image.save(buf, format="PNG")
            images.append(buf.getvalue())

        return images
