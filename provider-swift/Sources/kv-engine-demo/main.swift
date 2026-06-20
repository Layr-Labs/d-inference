import ArgumentParser
import Foundation
import MLX
import MLXLMCommon
import ProviderCore

/// KV-cache capacity demo + long-context scaling microbenchmark.
/// Loads a model into the real continuous-batching engine (fp16 baseline +
/// quantized) and reports capacity, quality, and perf. With `--prompt-tokens`
/// it additionally runs a synthetic long-context decode scaling sweep and a
/// matching KV dequant microbenchmark for GPT-OSS.
@main
struct KVEngineDemo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kv-engine-demo",
        abstract: "Compare fp16 and quantized BatchedEngine capacity/quality/perf, plus long-context scaling."
    )

    @Option(help: "Model ID to load.")
    var modelID: String = "mlx-community/gpt-oss-20b-MXFP4-Q8"

    @Option(help: "Path to the model snapshot directory. Defaults to the HF cache.")
    var modelDir: String?

    @Option(help: "Max tokens to generate per prompt / decode tokens in long-context mode.")
    var maxTokens: Int = 48

    @Option(help: "Number of prompts to run in default (short-prompt) mode.")
    var promptCount: Int = 3

    @Option(help: "Seconds to wait for a single generation before aborting.")
    var generationTimeout: Int = 120

    @Option(help: "Comma-separated synthetic prompt token lengths for long-context scaling (e.g. 512,2048,4096,8192).")
    var promptTokens: String?

    @Option(help: "Iterations per context for the dequant microbenchmark.")
    var dequantIters: Int = 30

    @Flag(help: "Skip generation and only report capacity numbers.")
    var capacityOnly: Bool = false

    @Flag(help: "Run only the quantized engine smoke (skip fp16 baseline).")
    var quantOnly: Bool = false

    @Option(help: "Comma-separated concurrency levels (e.g. 1,8,16,32). Enables the decode-throughput regression gate; capacity remains the headline.")
    var concurrencySweep: String?

    @Option(help: "Prompt token length used for every stream in the concurrency sweep.")
    var concurrencyContext: Int = 4096

    var concurrencyLevels: [Int] {
        guard let spec = concurrencySweep else { return [] }
        return spec
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
    }

    /// Label for the quantized engine, reflecting the actual scheme the scheduler
    /// resolves. Gemma 4 uses the g128 kernel; GPT-OSS defaults to dequant
    /// (kernel only via env override); unsupported families resolve to no scheme
    /// (fp16), so the "quantized" run is really fp16 — label it honestly.
    var gptOSSAwareQuantLabel: String {
        switch KVQuantPolicy.classify(modelID: modelID) {
        case .gemma4:
            return "k8v8:g128 (kernel)"
        case .gptOSS:
            return ProcessInfo.processInfo.environment["DARKBLOOM_KV_GPTOSS_KERNEL"] == "1"
                ? "k8v8:g64 (kernel)"
                : "k8v8:g64 (dequant)"
        case .unknown:
            return "fp16 (KV quant unsupported for this model)"
        }
    }

    var contextLengths: [Int] {
        guard let spec = promptTokens else { return [] }
        return spec
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
    }

    mutating func run() async throws {
        let resolvedModelDir = try resolveModelDirectory()
        printHeader(modelDir: resolvedModelDir)

        let modelConfig = LocalMLXModelConfiguration(
            modelID: modelID,
            modelDirectory: resolvedModelDir
        )
        let readiness = LocalMLXModelReadiness.inspect(modelConfig)
        guard readiness.canAttemptLoad else {
            let issueStrings = readiness.issues.map { issue in
                if let detail = issue.detail {
                    return "\(issue.kind.rawValue): \(issue.path.path) — \(detail)"
                }
                return "\(issue.kind.rawValue): \(issue.path.path)"
            }
            print("ERROR: model not ready: \(issueStrings.joined(separator: "; "))")
            throw ExitCode.failure
        }

        // The demo's whole purpose is an fp16-vs-quantized comparison. For model
        // families with no KV-quant scheme the "quantized" run silently falls back
        // to fp16, so reject them up front instead of emitting a bogus comparison.
        guard KVQuantPolicy.classify(modelID: modelID) != .unknown else {
            throw KVEngineDemoError.unsupportedModel(modelID)
        }

        print("Loading model container...")
        let container = try await LocalMLXModelLoader.live().loadContainer(for: modelConfig)
        print("Container loaded.\n")

        if !concurrencyLevels.isEmpty {
            await runConcurrencySweep(container: container)
            return
        }

        var reports: [EngineReport] = []

        if !quantOnly {
            print("=== Building fp16 baseline engine ===")
            let fp16 = try await runEngine(
                label: "fp16",
                container: container,
                kvQuantEnabled: false
            )
            reports.append(fp16)
            await cleanup()
        }

        let quantLabel = gptOSSAwareQuantLabel
        print("\n=== Building \(quantLabel) quantized engine ===")
        let quant = try await runEngine(
            label: quantLabel,
            container: container,
            kvQuantEnabled: true
        )
        reports.append(quant)
        await cleanup()

        printReport(reports: reports)

        if !contextLengths.isEmpty {
            await runDequantMicrobenchmark(reports: reports)
        }
    }

    // MARK: - Engine run

    private func runEngine(
        label: String,
        container: ModelContainer,
        kvQuantEnabled: Bool
    ) async throws -> EngineReport {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 1,
            defaultMaxTokens: maxTokens,
            kvQuantEnabled: kvQuantEnabled
        )

        await scheduler.loadModel(container: container, modelId: modelID)

        let kvBytes = await scheduler.resolvedKVBytesPerToken()
        let tokenBudget = await scheduler.resolvedTokenBudgetMax()

        print("  kv_bytes_per_token: \(kvBytes)")
        print("  token_budget_max:   \(tokenBudget)")

        var generations: [GenerationResult] = []
        if !capacityOnly {
            if !contextLengths.isEmpty {
                let tokenizer = await container.tokenizer
                for (index, contextLength) in contextLengths.enumerated() {
                    print("  generating context \(contextLength) \(index + 1)/\(contextLengths.count)...", terminator: " ")
                    do {
                        let promptTokens = syntheticPromptTokens(
                            targetCount: contextLength,
                            tokenizer: tokenizer
                        )
                        let result = try await generateTokenized(
                            scheduler: scheduler,
                            promptTokens: promptTokens,
                            index: index,
                            decodeTokens: maxTokens
                        )
                        generations.append(result)
                        print("ok (\(result.tokens) decode tok, \(String(format: "%.2f", result.decodeTokensPerSecond)) decode tok/s, reported \(String(format: "%.2f", result.reportedTokensPerSecond)) tok/s)")
                    } catch {
                        print("FAILED: \(error.localizedDescription)")
                        generations.append(GenerationResult(
                            prompt: "",
                            promptTokenCount: contextLength,
                            text: "",
                            tokens: 0,
                            decodeTokensPerSecond: 0,
                            reportedTokensPerSecond: 0,
                            error: error.localizedDescription
                        ))
                    }
                }
            } else {
                let prompts = Array(KVQuantQualityRunner.genFidelityPrompts.prefix(promptCount))
                for (index, prompt) in prompts.enumerated() {
                    print("  generating prompt \(index + 1)/\(prompts.count)...", terminator: " ")
                    do {
                        let result = try await generate(
                            scheduler: scheduler,
                            prompt: prompt,
                            index: index
                        )
                        generations.append(result)
                        print("ok (\(result.tokens) tokens, \(String(format: "%.2f", result.decodeTokensPerSecond)) tok/s decode)")
                    } catch {
                        print("FAILED: \(error.localizedDescription)")
                        generations.append(GenerationResult(
                            prompt: prompt,
                            promptTokenCount: 0,
                            text: "",
                            tokens: 0,
                            decodeTokensPerSecond: 0,
                            reportedTokensPerSecond: 0,
                            error: error.localizedDescription
                        ))
                    }
                }
            }
        }

        await scheduler.unloadModel()

        return EngineReport(
            label: label,
            kvBytesPerToken: kvBytes,
            tokenBudgetMax: tokenBudget,
            kvQuantEnabled: kvQuantEnabled,
            generations: generations
        )
    }

    // MARK: - Concurrency throughput (performance regression gate)
    //
    // Batch-1 decode is NOT the serving objective: weights/MoE dominate and the
    // KV read is tiny, so decode TPS is a regression gate, not the success metric.
    // This sweep submits N concurrent streams and reports aggregate decode tok/s
    // over the decode window only. The capacity headline is kv_bytes_per_token and
    // token_budget_max above.

    private func runConcurrencySweep(container: ModelContainer) async {
        let maxN = concurrencyLevels.max() ?? 1
        let tokenizer = await container.tokenizer
        let promptTokens = syntheticPromptTokens(
            targetCount: concurrencyContext, tokenizer: tokenizer)

        print("=== Concurrency throughput sweep ===")
        print("Context per stream: \(concurrencyContext) tok | decode per stream: \(maxTokens) tok")
        print("Levels: \(concurrencyLevels)\n")

        func measure(kvQuantEnabled: Bool, label: String) async -> [Int: ConcurrencyThroughput] {
            print("--- \(label) ---")
            let scheduler = BatchScheduler(
                maxConcurrentRequests: maxN,
                defaultMaxTokens: maxTokens,
                kvQuantEnabled: kvQuantEnabled
            )
            await scheduler.loadModel(container: container, modelId: modelID)
            let kvBytes = await scheduler.resolvedKVBytesPerToken()
            let budget = await scheduler.resolvedTokenBudgetMax()
            print("  kv_bytes_per_token: \(kvBytes) | token_budget_max: \(budget)")
            // Warmup: the first inference compiles Metal kernels; discard it so
            // cold-start cost doesn't poison the first measured level.
            _ = await runConcurrentBatch(
                scheduler: scheduler, promptTokens: promptTokens,
                concurrency: max(concurrencyLevels.max() ?? 1, 2), decodeTokens: 8)
            await cleanup()
            var out: [Int: ConcurrencyThroughput] = [:]
            for n in concurrencyLevels {
                let agg = await runConcurrentBatch(
                    scheduler: scheduler,
                    promptTokens: promptTokens,
                    concurrency: n,
                    decodeTokens: maxTokens
                )
                out[n] = agg
                // Headline is the steady-state decode rate (sum of per-stream
                // rates); wall-clock completed-tokens/total-wall is shown for
                // contrast — it is lower when N exceeds the engine's effective
                // concurrency cap (later waves' queue-wait inflates the window).
                print(String(format:
                    "  N=%3d  decode tok/s = %8.2f | wall-clock = %8.2f | TTFT(min) = %8.1f ms | prefill tok/s = %8.1f",
                    n,
                    agg.steadyStateDecodeTps,
                    agg.wallClockDecodeTps,
                    agg.minTtftMs,
                    agg.prefillTps))
                await cleanup()
            }
            await scheduler.unloadModel()
            await cleanup()
            print("")
            return out
        }

        let fp16 = await measure(kvQuantEnabled: false, label: "fp16")
        let quant = await measure(kvQuantEnabled: true, label: gptOSSAwareQuantLabel)

        // Compare on the steady-state decode rate — the capacity-relevant metric.
        print("=== Aggregate steady-state decode throughput: fp16 vs \(gptOSSAwareQuantLabel) ===")
        print("   N | fp16 tok/s | quant tok/s | ratio quant/fp16 |")
        for n in concurrencyLevels {
            let f = fp16[n]?.steadyStateDecodeTps ?? 0
            let q = quant[n]?.steadyStateDecodeTps ?? 0
            let r = f > 0 ? q / f : 0
            print(String(format: "%4d | %10.2f | %11.2f | %16.3f |", n, f, q, r))
        }
        print("")
    }

    private struct StreamTiming {
        let tokens: Int
        let submit: ContinuousClock.Instant?
        let first: ContinuousClock.Instant?
        let last: ContinuousClock.Instant?
    }

    /// Two distinct concurrency throughput numbers (see `runConcurrentBatch`).
    private struct ConcurrencyThroughput {
        /// Aggregate STEADY-STATE decode throughput: Σ over streams of
        /// (decodeTokens / that stream's OWN first→last chunk window). Because
        /// each stream's window starts at its own first decoded token, a stream
        /// that had to wait for an earlier wave to finish (queue-wait + prefill)
        /// does NOT have that idle time counted — so this isolates true
        /// steady-state decode rate even when N exceeds the engine's concurrency
        /// cap and streams run in serialized waves. This is the capacity-relevant
        /// headline.
        let steadyStateDecodeTps: Double
        /// Wall-clock completed-tokens throughput: total decode tokens / the
        /// GLOBAL window (earliest first chunk → latest last chunk across all
        /// streams). This window includes later waves' queue-wait/prefill, so it
        /// UNDER-reports steady-state decode; it reflects end-to-end wall-clock
        /// completion throughput instead. Reported alongside for contrast.
        let wallClockDecodeTps: Double
        /// Min time-to-first-token (submit → first chunk) across streams, in ms.
        /// At N=1 this is the pure prefill + first-decode latency; the min picks
        /// the wave-1 stream (least queue wait) as the cleanest prefill proxy.
        let minTtftMs: Double
        /// Prefill throughput proxy: promptTokenCount / minTTFT. TTFT includes one
        /// decode step + scheduling, so this slightly under-reports pure prefill;
        /// the bias shrinks as prompt length grows.
        let prefillTps: Double
    }

    /// Fire `concurrency` identical streams at once and report two throughput
    /// numbers (see `ConcurrencyThroughput`):
    ///   (a) `steadyStateDecodeTps` — sum of per-stream decode rates, each over
    ///       that stream's own decode window, so per-stream queue-wait/prefill is
    ///       excluded (correct even when streams run in serialized waves).
    ///   (b) `wallClockDecodeTps` — total decode tokens / global wall window,
    ///       which includes later waves' queue-wait/prefill.
    /// Pre-fix this returned only (b) as the "aggregate decode tok/s" headline,
    /// which under-reported steady-state decode whenever concurrency exceeded the
    /// engine's effective cap (the second wave's queue-wait inflated the window).
    private func runConcurrentBatch(
        scheduler: BatchScheduler,
        promptTokens: [Int],
        concurrency: Int,
        decodeTokens: Int
    ) async -> ConcurrencyThroughput {
        // Capture the deadline as a local so the worker tasks below don't capture
        // `self`; mirrors how `consumeStream` snapshots `generationTimeout`.
        let timeoutSeconds = generationTimeout
        let timings = await withTaskGroup(of: StreamTiming.self, returning: [StreamTiming].self) {
            group in
            for i in 0..<concurrency {
                group.addTask {
                    let submit = ContinuousClock.now
                    let stream = await scheduler.submitTokenized(
                        promptTokens: promptTokens,
                        maxTokens: decodeTokens,
                        temperature: 0.0,
                        requestId: "conc-\(i)"
                    )
                    // Race stream consumption against the generation timeout, the
                    // same way `consumeStream` does. A bare `for await` only
                    // observes the deadline after an event is yielded, so a stalled
                    // stream would hang the whole sweep. On timeout, abort this
                    // stream and report empty timing so it drops out of the
                    // aggregate instead of blocking the task group forever.
                    do {
                        return try await withThrowingTaskGroup(of: StreamTiming.self) { inner in
                            inner.addTask {
                                var toks = 0
                                var first: ContinuousClock.Instant?
                                var last: ContinuousClock.Instant?
                                for await event in stream {
                                    switch event {
                                    case .chunk:
                                        let now = ContinuousClock.now
                                        if first == nil { first = now }
                                        last = now
                                    case .info(_, let completionTok, _):
                                        toks = completionTok
                                    case .error:
                                        break
                                    }
                                }
                                return StreamTiming(tokens: toks, submit: submit, first: first, last: last)
                            }
                            inner.addTask {
                                try await Task.sleep(for: .seconds(timeoutSeconds))
                                throw KVEngineDemoError.generationTimeout
                            }
                            do {
                                guard let result = try await inner.next() else {
                                    return StreamTiming(tokens: 0, submit: submit, first: nil, last: nil)
                                }
                                inner.cancelAll()
                                return result
                            } catch {
                                inner.cancelAll()
                                throw error
                            }
                        }
                    } catch {
                        return StreamTiming(tokens: 0, submit: submit, first: nil, last: nil)
                    }
                }
            }
            var out: [StreamTiming] = []
            for await t in group { out.append(t) }
            return out
        }

        // Convert a Duration to fractional seconds (matches the inline pattern
        // used elsewhere in this file).
        func secondsOf(_ duration: Duration) -> Double {
            Double(duration.components.seconds)
                + Double(duration.components.attoseconds) * 1e-18
        }

        // (a) Steady-state decode: sum each stream's own decode rate. A stream
        // with k completed tokens spans (k - 1) inter-token intervals between its
        // first and last chunk, so (k - 1) / window is its steady-state rate. The
        // window starts at that stream's FIRST decoded token, so any time it spent
        // queued/prefilling behind an earlier wave is excluded. Summing across
        // streams gives the aggregate steady-state decode throughput.
        let steadyStateDecodeTps = timings.reduce(0.0) { acc, t in
            guard t.tokens >= 2, let first = t.first, let last = t.last, first < last
            else { return acc }
            let secs = secondsOf(first.duration(to: last))
            return secs > 0 ? acc + Double(t.tokens - 1) / secs : acc
        }

        // (b) Wall-clock: total decode tokens / global window (earliest first
        // chunk → latest last chunk). Includes later waves' queue-wait/prefill.
        let intervalTokens = timings.reduce(0) { $0 + max($1.tokens - 1, 0) }
        var wallClockDecodeTps = 0.0
        if let firstStart = timings.compactMap({ $0.first }).min(),
            let lastEnd = timings.compactMap({ $0.last }).max(),
            firstStart < lastEnd {
            let secs = secondsOf(firstStart.duration(to: lastEnd))
            wallClockDecodeTps = secs > 0 ? Double(intervalTokens) / secs : 0
        }

        // (c) TTFT / prefill: submit → first chunk. Min across streams (the
        // wave-1 stream with the least queue wait) isolates prefill cost best.
        let ttftsSec: [Double] = timings.compactMap { t in
            guard let s = t.submit, let f = t.first, s < f else { return nil }
            return secondsOf(s.duration(to: f))
        }
        let minTtftSec = ttftsSec.min() ?? 0
        let prefillTps = minTtftSec > 0 ? Double(promptTokens.count) / minTtftSec : 0

        return ConcurrencyThroughput(
            steadyStateDecodeTps: steadyStateDecodeTps,
            wallClockDecodeTps: wallClockDecodeTps,
            minTtftMs: minTtftSec * 1000.0,
            prefillTps: prefillTps
        )
    }

    // MARK: - Generation

    private func generate(
        scheduler: BatchScheduler,
        prompt: String,
        index: Int
    ) async throws -> GenerationResult {
        let request = ChatCompletionRequest(
            model: modelID,
            messages: [ChatMessage(role: "user", content: prompt)],
            temperature: 0.0,
            max_tokens: maxTokens
        )

        let stream = await scheduler.submit(request: request, requestId: "demo-\(index)")
        return try await consumeStream(
            stream: stream,
            prompt: prompt,
            promptTokenCount: 0,
            scheduler: scheduler
        )
    }

    private func generateTokenized(
        scheduler: BatchScheduler,
        promptTokens: [Int],
        index: Int,
        decodeTokens: Int
    ) async throws -> GenerationResult {
        let stream = await scheduler.submitTokenized(
            promptTokens: promptTokens,
            maxTokens: decodeTokens,
            temperature: 0.0,
            requestId: "demo-\(index)"
        )
        return try await consumeStream(
            stream: stream,
            prompt: "",
            promptTokenCount: promptTokens.count,
            scheduler: scheduler
        )
    }

    private func consumeStream(
        stream: AsyncStream<GenerationEvent>,
        prompt: String,
        promptTokenCount: Int,
        scheduler: BatchScheduler
    ) async throws -> GenerationResult {
        let timeoutSeconds = generationTimeout

        // Race stream consumption against the generation timeout. A bare
        // `for await` only observes the deadline *after* an event is yielded, so
        // a scheduler/model stall before the first chunk (or between chunks)
        // would suspend here forever. The timeout task fires while we are
        // suspended awaiting the next event.
        return try await withThrowingTaskGroup(of: GenerationResult.self) { group in
            group.addTask {
                var text = ""
                var tokens = 0
                var reportedTokensPerSecond: Double = 0
                var firstChunkAt: ContinuousClock.Instant?
                var lastChunkAt: ContinuousClock.Instant?

                for await event in stream {
                    switch event {
                    case .chunk(let chunk):
                        text += chunk
                        let now = ContinuousClock.now
                        if firstChunkAt == nil { firstChunkAt = now }
                        lastChunkAt = now
                    case .info(_, let completionTok, let tps):
                        tokens = completionTok
                        reportedTokensPerSecond = tps
                    case .error(let message):
                        throw KVEngineDemoError.generationFailed(message)
                    }
                }

                var decodeTokensPerSecond = reportedTokensPerSecond
                if let first = firstChunkAt, let last = lastChunkAt, tokens > 1 {
                    let duration = first.duration(to: last)
                    let seconds = Double(duration.components.seconds)
                        + Double(duration.components.attoseconds) * 1e-18
                    decodeTokensPerSecond = Double(tokens - 1) / seconds
                }

                return GenerationResult(
                    prompt: prompt,
                    promptTokenCount: promptTokenCount,
                    text: text,
                    tokens: tokens,
                    decodeTokensPerSecond: decodeTokensPerSecond,
                    reportedTokensPerSecond: reportedTokensPerSecond,
                    error: nil
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw KVEngineDemoError.generationTimeout
            }

            do {
                guard let result = try await group.next() else {
                    throw KVEngineDemoError.generationFailed("stream produced no result")
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                await scheduler.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Synthetic prompt

    private func syntheticPromptTokens(targetCount: Int, tokenizer: any MLXLMCommon.Tokenizer) -> [Int] {
        let seed = "The quick brown fox jumps over the lazy dog. "
        let seedTokens = tokenizer.encode(text: seed, addSpecialTokens: false)
        guard !seedTokens.isEmpty else {
            return Array(repeating: 1, count: targetCount)
        }
        var tokens: [Int] = []
        tokens.reserveCapacity(targetCount)
        while tokens.count < targetCount {
            tokens.append(contentsOf: seedTokens)
        }
        return Array(tokens.prefix(targetCount))
    }

    // MARK: - Microbenchmark

    private func runDequantMicrobenchmark(reports: [EngineReport]) async {
        print("\n=== KV dequant microbenchmark (GPT-OSS dims: B=1, kvHeads=8, headDim=64, g=64, bits=8) ===")

        let kvHeads = 8
        let headDim = 64
        let groupSize = 64
        let bits = 8
        let layers = 36  // GPT-OSS 20B

        print("context | ms/layer (K+V) | ms/all-layers |")
        var rows: [(context: Int, msPerLayer: Double, msAllLayers: Double)] = []

        for contextLength in contextLengths {
            let msPerLayer = benchmarkDequant(
                contextLength: contextLength,
                kvHeads: kvHeads,
                headDim: headDim,
                groupSize: groupSize,
                bits: bits
            )
            let msAllLayers = msPerLayer * Double(layers)
            rows.append((contextLength, msPerLayer, msAllLayers))
            print(String(format: "%7d | %14.3f | %13.3f |", contextLength, msPerLayer, msAllLayers))
        }

        print("\nDequant cost as a fraction of measured per-step decode time:")
        print("context | fp16 step ms | quant step ms | dequant ms/step | dequant/quant |")
        // Pair generations by index across reports.
        let fp16Report = reports.first { !$0.kvQuantEnabled }
        let quantReport = reports.first { $0.kvQuantEnabled }
        for (offset, ctx) in contextLengths.enumerated() {
            let fp16StepMs = fp16Report.flatMap { $0.generations[safe: offset] }.flatMap { $0.error == nil && $0.decodeTokensPerSecond > 0 ? 1000.0 / $0.decodeTokensPerSecond : nil }
            let quantStepMs = quantReport.flatMap { $0.generations[safe: offset] }.flatMap { $0.error == nil && $0.decodeTokensPerSecond > 0 ? 1000.0 / $0.decodeTokensPerSecond : nil }
            let dequantMs = rows.first { $0.context == ctx }?.msAllLayers
            let ratio: Double? = {
                guard let q = quantStepMs, let d = dequantMs, q > 0 else { return nil }
                return d / q
            }()
            print(String(format: "%7d | %14.3f | %15.3f | %15.3f | %13.3f |",
                         ctx,
                         fp16StepMs ?? -1,
                         quantStepMs ?? -1,
                         dequantMs ?? -1,
                         ratio ?? -1))
        }
    }

    private func benchmarkDequant(
        contextLength: Int,
        kvHeads: Int,
        headDim: Int,
        groupSize: Int,
        bits: Int
    ) -> Double {
        let shape = [1, kvHeads, contextLength, headDim]
        let count = shape.reduce(1, *)
        let src = MLXArray(0 ..< Int32(count)).reshaped(shape).asType(.float16)
        let q = quantized(src, groupSize: groupSize, bits: bits, mode: .affine)
        if let biases = q.biases {
            eval(q.wq, q.scales, biases)
        } else {
            eval(q.wq, q.scales)
        }

        // Warmup.
        for _ in 0..<5 {
            let dq = dequantized(
                q.wq, scales: q.scales, biases: q.biases,
                groupSize: groupSize, bits: bits, mode: .affine
            )
            eval(dq)
        }

        let start = ContinuousClock.now
        for _ in 0..<dequantIters {
            let dq = dequantized(
                q.wq, scales: q.scales, biases: q.biases,
                groupSize: groupSize, bits: bits, mode: .affine
            )
            eval(dq)
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
        let msPerIter = seconds * 1000.0 / Double(dequantIters)

        // We benchmark one tensor (K). In the model both K and V are
        // dequantized, and their shapes are identical, so double it.
        return msPerIter * 2.0
    }

    // MARK: - Reporting

    private func printHeader(modelDir: URL) {
        print("Darkbloom KV Engine Demo")
        print("Model:      \(modelID)")
        print("Model dir:  \(modelDir.path)")
        print("Max tokens: \(maxTokens)")
        print("Prompts:    \(promptCount)")
        if !contextLengths.isEmpty {
            print("Contexts:   \(contextLengths)")
        }
        print("")
    }

    private func printReport(reports: [EngineReport]) {
        print("\n========== REPORT ==========")

        // 1. CAPACITY
        print("\n1. HEADLINE CAPACITY (max admitted tokens)")
        for r in reports {
            print("  \(r.label):")
            print("    kv_bytes_per_token: \(r.kvBytesPerToken)")
            print("    token_budget_max:   \(r.tokenBudgetMax)")
        }
        if reports.count == 2 {
            let fp16 = reports[0]
            let quant = reports[1]
            let bytesRatio = Double(quant.kvBytesPerToken) / Double(max(fp16.kvBytesPerToken, 1))
            let budgetRatio = Double(quant.tokenBudgetMax) / Double(max(fp16.tokenBudgetMax, 1))
            print("  -> kv_bytes_per_token ratio (quant/fp16):  \(String(format: "%.3f", bytesRatio))")
            print("  -> max admitted tokens ratio (quant/fp16): \(String(format: "%.3f", budgetRatio))")
        }

        // 2. OUTPUT SMOKE
        print("\n2. OUTPUT SMOKE (coarse only; logits gate is authoritative)")
        if reports.count == 2,
           let fp16 = reports.first(where: { !$0.kvQuantEnabled }),
           let quant = reports.first(where: { $0.kvQuantEnabled }) {
            compareOutputs(fp16: fp16, quant: quant)
        } else {
            print("  (need both fp16 and quant reports to compare quality)")
        }

        // 3. PERF
        print("\n3. PERF REGRESSION GATE")
        if !contextLengths.isEmpty {
            print("\n  Long-context decode scaling (manual decode tok/s, first-token to last-token):")
            print("  context | engine | decode tok/s | reported tok/s |")
            for r in reports {
                for (offset, ctx) in contextLengths.enumerated() {
                    guard let gen = r.generations[safe: offset], gen.error == nil, gen.tokens > 0 else {
                        print(String(format: "  %7d | %-6@ | FAILED", ctx, r.label))
                        continue
                    }
                    print(String(format: "  %7d | %-6@ | %12.2f | %14.2f |",
                                 ctx, r.label, gen.decodeTokensPerSecond, gen.reportedTokensPerSecond))
                }
            }

            if reports.count == 2 {
                print("\n  Ratio quant/fp16 by context:")
                print("  context | ratio (decode tok/s) |")
                let fp16 = reports[0]
                let quant = reports[1]
                for (offset, ctx) in contextLengths.enumerated() {
                    let f = fp16.generations[safe: offset]?.decodeTokensPerSecond ?? 0
                    let q = quant.generations[safe: offset]?.decodeTokensPerSecond ?? 0
                    if f > 0 && q > 0 {
                        print(String(format: "  %7d | %19.3f |", ctx, q / f))
                    } else {
                        print(String(format: "  %7d | FAILED", ctx))
                    }
                }
            }
        } else {
            for r in reports {
                let ok = r.generations.filter { $0.error == nil && $0.tokens > 0 }
                let avgTps = ok.map(\.decodeTokensPerSecond).reduce(0, +) / Double(max(ok.count, 1))
                print("  \(r.label): avg decode tok/s = \(String(format: "%.2f", avgTps)) (\(ok.count)/\(r.generations.count) prompts succeeded)")
            }
        }

        print("\n============================")
    }

    private func compareOutputs(fp16: EngineReport, quant: EngineReport) {
        let pairs = zip(fp16.generations, quant.generations)
        var totalMatches = 0
        var totalTokens = 0
        var divergences: [String] = []

        for (fp16Gen, quantGen) in pairs {
            guard fp16Gen.error == nil, quantGen.error == nil,
                  !fp16Gen.text.isEmpty, !quantGen.text.isEmpty else {
                continue
            }

            let refTokens = fp16Gen.text.split(separator: " ")
            let quantTokens = quantGen.text.split(separator: " ")
            let minLen = min(refTokens.count, quantTokens.count)
            var matches = 0
            var firstDivergence: Int? = nil
            for i in 0..<minLen {
                if refTokens[i] == quantTokens[i] {
                    matches += 1
                } else if firstDivergence == nil {
                    firstDivergence = i
                }
            }
            totalMatches += matches
            totalTokens += minLen

            if let first = firstDivergence {
                let preview = quantGen.text.prefix(120)
                divergences.append("prompt '\(fp16Gen.prompt.prefix(40))...' diverged at token \(first); quant output: \(preview)")
            }
        }

        let matchRate = totalTokens > 0 ? Double(totalMatches) / Double(totalTokens) : 0
        print("  exact-token match rate (whitespace tokens): \(String(format: "%.3f", matchRate)) (\(totalMatches)/\(totalTokens))")
        if !divergences.isEmpty {
            print("  divergence points:")
            for d in divergences.prefix(3) {
                print("    - \(d)")
            }
        }

        // Full side-by-side text so the actual generation difference is visible,
        // not just a match rate. Greedy decode => the only difference is the KV
        // representation (fp16 vs quantized).
        print("\n  ===== FULL GENERATIONS: fp16 vs \(quant.label) =====")
        for (fp16Gen, quantGen) in zip(fp16.generations, quant.generations) {
            print("\n  ┌── PROMPT: \(fp16Gen.prompt)")
            print("  │")
            print("  ├── [fp16]:")
            print(fp16Gen.text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "  │   \($0)" }.joined(separator: "\n"))
            print("  │")
            print("  ├── [\(quant.label)]:")
            print(quantGen.text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "  │   \($0)" }.joined(separator: "\n"))
            print("  └────────────────────────────────────────────────")
        }
    }

    // MARK: - Helpers

    private func resolveModelDirectory() throws -> URL {
        if let modelDir {
            let url = URL(fileURLWithPath: modelDir)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw KVEngineDemoError.modelDirectoryNotFound(url.path)
            }
            return url
        }

        guard let path = ModelScanner.resolveLocalPath(modelID: modelID) else {
            throw KVEngineDemoError.modelNotInCache(modelID)
        }
        return path
    }

    private func cleanup() async {
        MLX.Memory.clearCache()
        try? await Task.sleep(for: .milliseconds(200))
    }
}

// MARK: - Types

private struct EngineReport {
    let label: String
    let kvBytesPerToken: Int
    let tokenBudgetMax: Int
    let kvQuantEnabled: Bool
    let generations: [GenerationResult]
}

private struct GenerationResult {
    let prompt: String
    let promptTokenCount: Int
    let text: String
    let tokens: Int
    let decodeTokensPerSecond: Double
    let reportedTokensPerSecond: Double
    let error: String?
}

private enum KVEngineDemoError: Error, LocalizedError {
    case modelDirectoryNotFound(String)
    case modelNotInCache(String)
    case generationFailed(String)
    case generationTimeout
    case unsupportedModel(String)

    var errorDescription: String? {
        switch self {
        case .modelDirectoryNotFound(let path):
            return "model directory not found: \(path)"
        case .modelNotInCache(let id):
            return "model '\(id)'' not found in HF cache; pass --model-dir"
        case .generationFailed(let message):
            return "generation failed: \(message)"
        case .generationTimeout:
            return "generation timed out"
        case .unsupportedModel(let id):
            return "model '\(id)' has no KV-quant scheme (not Gemma 4 / GPT-OSS); "
                + "the fp16-vs-quant comparison would be fp16-vs-fp16. "
                + "Run the gate with a supported target model."
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
