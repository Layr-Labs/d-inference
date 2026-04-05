"""Entry point: python -m eigeninference_image_bridge --port 8102 --model flux-klein-4b

Starts the image bridge server with Draw Things gRPCServerCLI as the backend.
gRPCServerCLI is spawned as a subprocess and managed for the lifetime of the bridge.
"""

import argparse
import atexit
import logging
import sys

import uvicorn


def main():
    parser = argparse.ArgumentParser(description="EigenInference Image Bridge Server")
    parser.add_argument("--port", type=int, default=8102, help="HTTP port (default: 8102)")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    parser.add_argument("--model", default="flux-klein-4b", help="Model ID (default: flux-klein-4b)")
    parser.add_argument("--grpc-port", type=int, default=7859,
                        help="gRPC port for Draw Things server (default: 7859)")
    parser.add_argument("--grpc-binary", default=None,
                        help="Path to gRPCServerCLI binary")
    parser.add_argument("--model-path", default=None,
                        help="Model directory for gRPCServerCLI (starts subprocess if set)")
    parser.add_argument("--system-memory-gb", type=float, default=0,
                        help="Total system RAM in GB (auto-detected if omitted)")
    parser.add_argument("--model-size-gb", type=float, default=0,
                        help="Model weight size in GB (estimated from model name if omitted)")
    parser.add_argument("--log-level", default="info", choices=["debug", "info", "warning", "error"])
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper()),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
        stream=sys.stderr,
    )

    from .drawthings_backend import DrawThingsBackend
    from .server import create_app

    backend = DrawThingsBackend(
        model=args.model,
        grpc_port=args.grpc_port,
        grpc_server_binary=args.grpc_binary,
        model_path=args.model_path,
        system_memory_gb=args.system_memory_gb,
        model_size_gb=args.model_size_gb,
    )

    # Start gRPCServerCLI as subprocess if model_path is provided
    if args.model_path:
        backend.start_server()
        atexit.register(backend.stop_server)

    if not backend.is_ready():
        logging.error("Draw Things gRPCServerCLI not reachable on port %d", args.grpc_port)
        sys.exit(1)

    app = create_app(backend=backend)

    uvicorn.run(app, host=args.host, port=args.port, log_level=args.log_level)


if __name__ == "__main__":
    main()
