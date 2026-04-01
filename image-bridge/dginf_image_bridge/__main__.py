"""Entry point: python -m dginf_image_bridge --port 8102 --model flux-klein-4b

Supports two backends:
  --backend drawthings  (default) — Draw Things gRPCServerCLI with Metal FlashAttention
  --backend mflux       — mflux MLX-native FLUX (fallback, no gRPC dependency)
"""

import argparse
import logging
import sys

import uvicorn


def main():
    parser = argparse.ArgumentParser(description="DGInf Image Bridge Server")
    parser.add_argument("--port", type=int, default=8102, help="HTTP port (default: 8102)")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    parser.add_argument("--model", default="flux-schnell", help="Model ID (default: flux-schnell)")
    parser.add_argument("--backend", default="drawthings", choices=["drawthings", "mflux"],
                        help="Image generation backend (default: drawthings)")
    parser.add_argument("--quantize", type=int, default=8, choices=[4, 8],
                        help="Quantization bits for mflux backend (default: 8)")
    parser.add_argument("--grpc-port", type=int, default=7859,
                        help="gRPC port for Draw Things server (default: 7859)")
    parser.add_argument("--grpc-binary", default=None,
                        help="Path to gRPCServerCLI binary")
    parser.add_argument("--model-path", default=None,
                        help="Model directory for gRPCServerCLI")
    parser.add_argument("--log-level", default="info", choices=["debug", "info", "warning", "error"])
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper()),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
        stream=sys.stderr,
    )

    from .server import create_app

    if args.backend == "drawthings":
        from .drawthings_backend import DrawThingsBackend
        backend = DrawThingsBackend(
            model=args.model,
            grpc_port=args.grpc_port,
            grpc_server_binary=args.grpc_binary,
            model_path=args.model_path,
        )
        if args.model_path:
            backend.start_server()
    else:
        from .server import MfluxBackend
        backend = MfluxBackend(model=args.model, quantize=args.quantize)

    if not backend.is_ready():
        logging.error("Failed to initialize image generation backend")
        sys.exit(1)

    app = create_app(backend=backend)

    uvicorn.run(app, host=args.host, port=args.port, log_level=args.log_level)


if __name__ == "__main__":
    main()
