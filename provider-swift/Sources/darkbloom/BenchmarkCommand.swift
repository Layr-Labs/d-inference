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
        auto|contiguous|paged (default auto, which resolves to CONTIGUOUS as \
        of v0.8.1 — pass --kv-backend paged to measure the paged arm). \
        Applies to --sweep, --scheduler-prefill and \
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

    @Option(name: .long, help: """
        Arrival benchmark: concurrent request rows (1, 2, or 4). Default 4. \
        JSON records batchSize and harness-computed aggregatePrefillTokensPerSecond.
        """)
    var arrivalBatchSize = 4

    // MARK: - Fixed-weight Qwen quality-corpus mode

    @Option(name: .long, help: """
        Run the benchmark-only Qwen quality harness over this JSON corpus. \
        Requires an explicit --model, loads it once, applies its normal chat \
        template, and emits one versioned JSON report to stdout.
        """)
    var qualityCorpus: String?

    @Option(name: .long, help: """
        Quality corpus: fixed greedy tokens generated per case (default 64; \
        required range 32...4096). Stop tokens are intentionally disabled so \
        every case has the same comparison window.
        """)
    var qualityMaxTokens = QwenQualityCorpusBenchmark.defaultMaximumTokens

    @Option(name: .long, help: """
        Quality corpus: label recorded in the report (for example baseline or \
        top4-layer39).
        """)
    var qualityRunLabel = QwenQualityCorpusBenchmark.defaultRunLabel

    @Option(name: .long, help: """
        Quality corpus: baseline report JSON to compare with this run. The \
        output includes per-case exact agreement and first mismatch positions; \
        token disagreement does not make the command fail.
        """)
    var qualityBaselineReport: String?

    @Option(name: .long, help: """
        Quality corpus: write the JSON report atomically to this path instead \
        of stdout. Recommended for real-model runs so third-party model-loader \
        diagnostics cannot contaminate the JSON artifact.
        """)
    var qualityOutput: String?

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

    mutating func validate() throws {
        guard ArrivalPrefillAccounting.allowedBatchSizes.contains(arrivalBatchSize) else {
            throw ValidationError("--arrival-batch-size must be 1, 2, or 4")
        }
        if qualityCorpus != nil {
            guard qualityCorpus?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            else {
                throw ValidationError("--quality-corpus path must not be empty")
            }
            guard !sweep, !schedulerPrefill, !arrivalInvariance, !parity else {
                throw ValidationError(
                    "--quality-corpus cannot be combined with --sweep, "
                        + "--scheduler-prefill, --arrival-invariance, or --parity")
            }
            guard model != nil else {
                throw ValidationError("--quality-corpus requires an explicit --model")
            }
            guard (QwenQualityCorpusExecutor.minimumGenerationTokens
                ... QwenQualityCorpusExecutor.maximumGenerationTokens)
                .contains(qualityMaxTokens)
            else {
                throw ValidationError(
                    "--quality-max-tokens must be in "
                        + "\(QwenQualityCorpusExecutor.minimumGenerationTokens)..."
                        + "\(QwenQualityCorpusExecutor.maximumGenerationTokens)")
            }
            let label = qualityRunLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.utf8.count <= 128 else {
                throw ValidationError(
                    "--quality-run-label must contain 1...128 UTF-8 bytes")
            }
            for (name, path) in [
                ("--quality-baseline-report", qualityBaselineReport),
                ("--quality-output", qualityOutput),
            ] {
                if let path,
                   path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    throw ValidationError("\(name) path must not be empty")
                }
            }
        } else if qualityBaselineReport != nil || qualityOutput != nil {
            throw ValidationError(
                "--quality-baseline-report and --quality-output require --quality-corpus")
        }
    }

    mutating func run() async throws {
        let snapshot = try loadRuntimeSnapshot(
            configPath: configOptions.config,
            migrateOnDisk: false)

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

        if let qualityCorpus {
            try await runQwenQualityCorpus(
                modelID: selectedModel.id,
                modelDirectory: modelPath,
                corpusPath: qualityCorpus,
                hardware: hardware)
            return
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
                hardware: hardware,
                gemmaOptimizations: gemmaSettings
            )
            return
        }

        if schedulerPrefill {
            try await runSchedulerPrefillBenchmark(
                modelID: selectedModel.id,
                modelDirectory: modelPath,
                gemmaOptimizations: gemmaSettings
            )
            return
        }

        if arrivalInvariance {
            try await runArrivalInvarianceBenchmark(
                modelID: selectedModel.id,
                modelDirectory: modelPath,
                gemmaOptimizations: gemmaSettings
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
