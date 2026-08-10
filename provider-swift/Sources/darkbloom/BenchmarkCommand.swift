import ArgumentParser
import Foundation
import ProviderCore
import ProviderBenchmark

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

    @Option(name: .long, help: """
        Sweep: measured repetitions of the whole decode batch curve (default 1). \
        Each repetition emits its own decode sample so callers can take a median.
        """)
    var decodeIterations = ThroughputSweep.defaultDecodeIterations

    @Flag(name: .long, help: """
        Run the cold-prefill TTFT benchmark through the production \
        ContinuousBatchingV2 engine and print a JSON report (engine-internal \
        chunked prefill, prefix cache off).
        """)
    var schedulerPrefill = false

    @Option(name: .long, help: "Scheduler prefill: measured iterations per length.")
    var prefillIterations = 2

    @Flag(name: .long, help: "Measure production CBv2 burst-versus-staggered request arrivals and output invariance.")
    var arrivalInvariance = false

    @Option(name: .long, help: "Arrival benchmark: prompt tokens per request.")
    var arrivalPromptTokens = 512

    @Option(name: .long, help: "Arrival benchmark: generated tokens per request.")
    var arrivalDecodeTokens = 64

    @Option(name: .long, help: "Arrival benchmark: measured iterations per arrival pattern.")
    var arrivalIterations = 3

    mutating func run() async throws {
        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)

        // The low-level Gemma controls are process-start latches, so
        // `provider.toml` must be projected BEFORE the first MLX device
        // access — exactly like the serve path (the shared seam is
        // `ServeRuntimePreparer.prepareRuntime`; `Start` forwards to it).
        // Otherwise a rollback A/B benchmark silently measures the
        // default-enabled stack instead of the configured serving stack. A
        // rejected projection aborts before engine construction.
        //
        // A/B integrity: benchmark artifacts record the process environment
        // (scripts/gemma_contbatch/runner.py logs os.environ). A shell-preset
        // low-level key that CONFLICTS with the config projection would be
        // silently overwritten by apply(), so the artifact metadata would
        // then disagree with what was actually measured — refuse to run.
        let gemmaSettings = snapshot.config.gemmaOptimizations
        if let conflict = ServeRuntimePreparer.conflictingEnvironmentOverride(
            settings: gemmaSettings
        ) {
            printError("""
                benchmark is config-driven: refusing to run with \
                \(conflict.key)=\(conflict.shellValue) set in this shell while \
                provider.toml projects \(conflict.configValue). Toggle with \
                `darkbloom beta` or edit [gemma_optimizations] in provider.toml, \
                then re-run benchmark without the low-level override.
                """)
            throw ExitCode.failure
        }
        do {
            try ServeRuntimePreparer.prepareRuntime(settings: gemmaSettings)
        } catch {
            printError("\(error)")
            throw ExitCode.failure
        }
        // stderr, not stdout — benchmark subcommands emit machine-parsed JSON
        // on stdout (any stray line breaks `darkbloom benchmark`'s consumers).
        FileHandle.standardError.write(Data(
            "gemma optimizations: prefill_layer18=\(gemmaSettings.prefillLayer18 ? "on" : "off") weighted_r1=\(gemmaSettings.weightedR1 ? "on" : "off")\n"
            .utf8))

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

        if schedulerPrefill {
            try await runSchedulerPrefillBenchmark(
                modelID: selectedModel.id,
                modelDirectory: modelPath
            )
            return
        }

        if arrivalInvariance {
            try await runArrivalInvarianceBenchmark(
                modelID: selectedModel.id,
                modelDirectory: modelPath
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
