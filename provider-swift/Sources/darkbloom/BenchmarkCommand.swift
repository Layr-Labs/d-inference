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

    @Flag(name: .long, help: """
        Run the fail-closed signed-candidate cap-0/cap-1 scheduler-prefill \
        evaluation. This mode only runs from the packaged signed \
        Darkbloom.app main executable.
        """)
    var schedulerPrefillDecision = false

    @Option(name: .long, help: "Signed decision: expected registered model aggregate SHA-256.")
    var expectedModelAggregateSHA256: String?

    @Option(name: .long, help: "Signed decision: expected registered signed darkbloom binary SHA-256.")
    var expectedRegisteredBinarySHA256: String?

    @Option(name: .long, help: "Signed decision: exact expected ProviderCore version.")
    var expectedVersion: String?

    @Option(name: .long, help: "Signed decision: source commit SHA (40 or 64 lowercase hex).")
    var sourceSHA: String?

    @Option(name: .long, help: "Signed decision: measured iterations per cap/workload cell (minimum/default 10).")
    var decisionIterations = SchedulerPrefillDecisionReport.minimumLiveIterations

    @Option(name: .long, help: "Signed decision: write JSON atomically to this file; omit for stdout.")
    var output: String?

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
        KV-backend selection passed to every engine this command builds — \
        auto|contiguous|paged (default auto). Candidate auto selects paged only \
        for exact model IDs qwen3.5-35b-a3b, qwen3.6-35b-a3b-vl-mtp-mxfp8, \
        and EigenLabs/Qwen3.8-27B-4bit-mtp; all other models use contiguous. \
        Automatic paged failures and the version-bound crash-loop guard \
        still fall back to contiguous. Pass --kv-backend paged to require \
        the paged arm rather than automatic fallback. \
        Applies to --sweep, --scheduler-prefill, \
        --scheduler-prefill-decision, and --arrival-invariance alike. Each \
        engine receives the same requested selection; automatic fallback \
        can produce different resolved backends. An explicit paged selection FAILS the \
        run rather than degrading: if paged cannot be served, engine \
        construction throws, the cell records no samples, and the command \
        exits non-zero naming the reason. DARKBLOOM_CBV2_PAGED_KV=0 and \
        capability/span-mask vetoes can still force contiguous, even for an \
        explicit selection. The backend that actually served is recorded per \
        measured engine (decode[].resolvedKVBackend, \
        samples[].resolvedKVBackend) and de-duplicated in each report's \
        kvBackend block. Candidate rollout is not yet validated; see \
        docs/design/qwen-first-paged-ssd-rollout.md.
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

    @Option(name: .long, help: "Arrival benchmark: four comma-separated per-row prompt lengths, e.g. 8192,512,512,512.")
    var arrivalPromptLengths: String?

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

    @Option(name: .long, help: "Score bounded exact token contexts from JSON with an explicit --model and --kv-backend; ordinary target only, cache and MTP off.")
    var teacherForcedInput: String?

    mutating func run() async throws {
        if let conflict = benchmarkModeConflict() {
            printError(conflict)
            throw ExitCode(2)
        }
        if let error = teacherForcedOptionError() {
            printError(error)
            throw ExitCode(2)
        }
        if schedulerPrefillDecision {
            try await runSignedSchedulerPrefillDecision()
            return
        }

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

        if let teacherForcedInput {
            let result = try await TeacherForcedBenchmark.run(
                modelID: selectedModel.id, modelDirectory: modelPath,
                inputURL: URL(fileURLWithPath: teacherForcedInput), backend: kvBackend,
                gemmaOptimizations: gemmaSettings)
            // Preserve nonfinite/neutrality evidence even when inconclusive.
            print(result.json)
            if !result.controlsPassed { throw ExitCode(2) }
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

    func benchmarkModeConflict() -> String? {
        let selected = [
            (schedulerPrefillDecision, "--scheduler-prefill-decision"),
            (sweep, "--sweep"),
            (schedulerPrefill, "--scheduler-prefill"),
            (arrivalInvariance, "--arrival-invariance"),
            (parity, "--parity"),
            (teacherForcedInput != nil, "--teacher-forced-input"),
        ].compactMap { $0.0 ? $0.1 : nil }
        guard selected.count <= 1 else {
            return "benchmark modes are mutually exclusive: \(selected.joined(separator: ", "))"
        }
        return nil
    }

    func teacherForcedOptionError() -> String? {
        guard let teacherForcedInput else { return nil }
        guard !teacherForcedInput.isEmpty, let model, !model.isEmpty else {
            return "--teacher-forced-input requires a file and explicit --model"
        }
        guard assistantModel == nil, output == nil else {
            return "--teacher-forced-input uses ordinary target scoring and JSON stdout; assistant and signed-decision output options do not apply"
        }
        do { try TeacherForcedBenchmark.validateBackend(kvBackend) }
        catch { return "--teacher-forced-input requires --kv-backend contiguous or paged" }
        return nil
    }
}
