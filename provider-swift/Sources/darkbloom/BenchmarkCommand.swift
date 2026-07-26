import ArgumentParser
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

    @Option(name: .long, help: """
        Sweep: explicit comma-separated decode batch sizes (e.g. 1,2,4,8). \
        When present this replaces the B=1...--max-batch ladder, so a release \
        gate measures only the cells it needs instead of the whole ramp.
        """)
    var batchSizes: String?

    @Option(name: .long, help: "Sweep: decode tokens generated per sequence (default 64).")
    var decodeTokens = ThroughputSweep.defaultDecodeTokens

    @Option(name: .long, help: "Sweep: decode prompt length in tokens per sequence (default 64).")
    var decodePromptTokens = ThroughputSweep.defaultDecodePromptTokens

    @Option(name: .long, help: """
        Sweep: measured repetitions of the whole decode batch curve (default 1). \
        Each repetition emits its own decode sample so callers can take a median.
        """)
    var decodeIterations = ThroughputSweep.defaultDecodeIterations

    @Option(name: .long, help: """
        KV backend EVERY engine this command builds is built with — \
        auto|contiguous|paged (default auto, which resolves to CONTIGUOUS — \
        v0.8.0 flipped it to paged and reverted before release: paged adoption \
        is not transparent). Applies to --sweep, --scheduler-prefill and \
        --arrival-invariance alike, so the three phases of a wrapper run can \
        never measure different arms. An explicit paged selection FAILS the \
        run rather than degrading: if paged cannot be served, engine \
        construction throws, the cell records no samples, and the command \
        exits non-zero naming the reason — so a paged benchmark can never \
        measure contiguous. Only DARKBLOOM_CBV2_PAGED_KV=0 still degrades an \
        explicit selection. The backend that actually served is recorded per \
        measured engine (decode[].resolvedKVBackend, \
        samples[].resolvedKVBackend) and de-duplicated in each report's \
        kvBackend block.
        """)
    var kvBackend = "auto"

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

    // MARK: - Gate G2 parity mode (paged vs contiguous, PASS/FAIL per criterion)

    @Flag(name: .long, help: """
        Run the Gate G2 parity check: load the model on BOTH KV backends and \
        report each G2 criterion (token exactness, MTP, packed prefill, vision \
        spans, prefix reuse) as PASS/FAIL/UNAVAILABLE with its measured \
        evidence. JSON to stdout, operator table to stderr. Exit 0 only when at \
        least one criterion was evaluated and none failed; 1 on any failure; \
        2 when nothing could be evaluated.
        """)
    var parity = false

    @Option(name: .long, help: """
        Parity: MTP assistant/drafter model id. Without it the MTP criterion \
        reports UNAVAILABLE rather than passing by default.
        """)
    var assistantModel: String?

    @Option(name: .long, help: "Parity: generated tokens per compared row (default 48).")
    var parityMaxTokens = 48

    @Option(name: .long, help: """
        Parity: prompt tokens for the prefix-reuse probe (default 28672). Must \
        exceed the backend's frozen-replay bound — 26624 on paged gemma-4 — or \
        no prefill saving is reachable and the criterion reports UNAVAILABLE.
        """)
    var parityPrefixTokens = 28672

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

        if parity {
            try await runBackendParity(
                modelID: selectedModel.id,
                modelDirectory: modelPath
            )
            return
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
