// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ClusterInferenceProbe",
    platforms: [.macOS("26.2")],
    products: [.executable(name: "cluster-inference", targets: ["ClusterInference"])],
    dependencies: [
        // Same final native MLX source as the paired MTP worker.
        .package(path: "../../../libs/mlx-swift"),
        .package(path: "../../../libs/mlx-swift-lm"),
    ],
    targets: [
        .executableTarget(name: "ClusterInference", dependencies: [
            .product(name: "Cmlx", package: "mlx-swift"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
    ])
