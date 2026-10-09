import ArgumentParser
import ProviderAppAttest
import ProviderCore

/// Package-real release gate. Hidden because it is invoked by CI against the
/// staged/extracted app, not by operators.
struct RuntimeSmoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime-smoke",
        abstract: "Internal: validate packaged runtime resources and kernels.",
        shouldDisplay: false)

    @Argument(help: "Internal encoded kernel shapes.")
    var shapes: [String] = []

    @Option(help: "Internal resolved KV profile; packaged validation includes balanced by default.")
    var kvQuantization = "balanced"

    @Option(
        name: .customLong("packed-shape"),
        help: "Internal encoded packed-kernel specialization; repeat per selected shape.")
    var packedShapes: [String] = []

    mutating func run() async throws {
        let build = BuildEnvironment.current
        print("build-environment-runtime-smoke: \(build.rawValue) coordinator=\(build.coordinatorWebSocketURL) cdn=\(build.modelCDNURL)")
        try await AppAttestRuntimeSmoke.run()
        print(AppAttestRuntimeSmoke.successMarker)
        try PackagedRuntimeSmoke.verifyQwen4MetalResources()
        print(PackagedRuntimeSmoke.qwen4MetalSuccessMarker)
        try PackagedRuntimeSmoke.verifyGemmaOptimizations()
        print(PackagedRuntimeSmoke.gemmaOptimizationSuccessMarker)
        try PackagedRuntimeSmoke.runPagedKernel(
            arguments: shapes, precision: kvQuantization, packedArguments: packedShapes)
        print("paged-kernel-runtime-smoke: ok")
    }
}
