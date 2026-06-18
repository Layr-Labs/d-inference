import ArgumentParser
import ProviderCore

struct Benchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run standardized inference benchmarks.",
        discussion: "Loads an MLX model and measures prefill latency, decode throughput, and total generation time."
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(help: "Model ID to benchmark. Defaults to the largest model that fits.")
    var model: String?

    @Option(help: "Prompt for the benchmark generation.")
    var prompt = ModelBenchmark.defaultPrompt

    @Option(help: "Number of benchmark iterations.")
    var iterations = ModelBenchmark.defaultIterations

    @Option(name: .long, help: "Maximum tokens to generate per iteration.")
    var maxTokens = ModelBenchmark.defaultMaxTokens

    // MARK: - Throughput sweep mode (prefill tok/s × prompt length; decode tok/s × batch size)

    @Flag(name: .long, help: """
        Run the prefill+decode throughput sweep and print a JSON report \
        (instead of the standard latency benchmark). Measures prefill tok/s \
        across prompt lengths and decode tok/s at batch sizes 1...N, then \
        infers whether the model decodes dense-vs-sparse from the B=1 read.
        """)
    var sweep = false

    @Option(name: .long, help: "Sweep: comma-separated prefill prompt lengths in tokens (default 128,512,2048).")
    var prefillLengths = "128,512,2048"

    @Option(name: .long, help: "Sweep: maximum decode batch size; measures B=1...N (default 6).")
    var maxBatch = 6

    @Option(name: .long, help: "Sweep: decode tokens generated per sequence (default 64).")
    var decodeTokens = ThroughputSweep.defaultDecodeTokens

    @Option(name: .long, help: "Sweep: decode prompt length in tokens per sequence (default 64).")
    var decodePromptTokens = ThroughputSweep.defaultDecodePromptTokens

    mutating func run() async throws {
        do {
            _ = try GPUEnforcement.requireMetal()
        } catch {
            printError("\(error)")
            throw ExitCode.failure
        }

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)

        guard let hardware = snapshot.hardware else {
            printError("hardware detection failed: \(snapshot.hardwareError?.localizedDescription ?? "unknown")")
            throw ExitCode.failure
        }

        let models = advertisedModels(from: snapshot.models, config: snapshot.config)

        guard let selectedModel = ModelBenchmark.selectModel(
            models: models,
            preferredModel: model ?? snapshot.config.backend.model
        ) else {
            printError("no suitable model found for benchmarking. Download an MLX model first.")
            throw ExitCode.failure
        }

        guard let modelPath = ModelScanner.resolveLocalPath(modelID: selectedModel.id) else {
            printError("could not resolve local path for model '\(selectedModel.id)'")
            throw ExitCode.failure
        }

        if sweep {
            try await runThroughputSweep(
                modelID: selectedModel.id,
                modelDirectory: modelPath,
                hardware: hardware
            )
            return
        }

        print("darkbloom benchmark")
        print("")

        let report = try await ModelBenchmark.run(
            modelID: selectedModel.id,
            modelDirectory: modelPath,
            prompt: prompt,
            iterations: iterations,
            maxTokens: maxTokens,
            hardware: hardware
        )

        report.printTable()
    }
}
