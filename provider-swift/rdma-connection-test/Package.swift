// swift-tools-version: 6.1

import PackageDescription

// Standalone RDMA connectivity smoke test.
// Requires the mlx-swift submodule at ../../libs/mlx-swift.
//
// Build:   swift build -c release
// Binary:  .build/release/rdma-ping
//
// Run on rank 0 (Mac A):
//   ./rdma-ping --rank 0 --coordinator <mac-a-bridge-ip>:9999 --rdma-device rdma_en2
//
// Run on rank 1 (Mac B) simultaneously:
//   ./rdma-ping --rank 1 --coordinator <mac-a-bridge-ip>:9999 --rdma-device rdma_en1
//
// Prerequisites:
//   - macOS 26.2+ with RDMA enabled (run `rdma enable` in macOS Recovery)
//   - Thunderbolt cable between the two Macs
//   - mlx.metallib in the same directory as the binary (symlink from ~/darkbloom/mlx.metallib)

let package = Package(
    name: "RDMAConnectionTest",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../libs/mlx-swift"),
    ],
    targets: [
        .executableTarget(
            name: "rdma-ping",
            dependencies: [
                .product(name: "Cmlx", package: "mlx-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/rdma-ping"
        ),
    ]
)
