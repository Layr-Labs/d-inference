import Foundation
import ProviderCore
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Prefill-throughput + per-batch decode-throughput sweep for a loaded MLX
/// model. Produces a `ThroughputSweepReport` (JSON).
///
/// Reuses the provider's real inference stack — it loads the model with the
/// same `LLMModelFactory` + `LocalTokenizerLoader` the serve path uses, runs
/// prefill through `model.callAsFunction(_:cache:)`, and runs decode through
/// the PRODUCTION ContinuousBatchingV2 engine, constructed via
/// `EngineV2Factory.makeProductionBuild` — the one-engine entry point every
/// serving slot uses (`makeProductionEngine` is its thin wrapper, which
/// discards the resolved-backend metadata this report needs). It does **not**
/// reimplement any inference numerics; it only drives the engine and times it.
///
/// The decode-vs-batch curve is the point: a memory-bandwidth-bound dense model
/// amortizes one weight read across the batch and scales ~linearly, while a
/// genuinely sparse MoE reads extra experts as the batch grows and scales
/// sub-linearly. Combined with the B=1 implied-bytes-per-token inversion in
/// `DecodeBandwidthModel`, the report says whether an MoE is decoding sparsely
/// or "as if dense". See `docs/gemma-decode-bandwidth-analysis.md`.
public enum ThroughputSweep {

    public static let defaultPromptLengths = [128, 512, 2048]
    public static let defaultBatchSizes = [1, 2, 3, 4, 5, 6]
    public static let defaultDecodeTokens = 64
    public static let defaultDecodePromptTokens = 64
    public static let defaultDecodeIterations = 1

    /// Throughput cells must generate the requested budget for every row.
    /// Honoring model EOS would compare different token counts and lets one
    /// early-stopping row corrupt a batch aggregate; arrival invariance uses
    /// the same fixed-budget contract.
    static let fixedBudgetStopTokens: Set<Int> = []

    /// Snapshot of model facts read once, off-actor, inside `perform`.
    private struct ModelFacts: Sendable {
        let weightBytes: Int
        let totalParams: Int
        let baseTokens: [Int]
    }

    /// Run the full sweep. `hardware` supplies the peak memory bandwidth used to
    /// invert decode tok/s into implied bytes/token.
    ///
    /// `decodeIterations` repeats the whole decode batch curve that many times
    /// inside the one loaded process; every repetition is emitted as its own
    /// `DecodeSample`, so callers can take a median instead of trusting a single
    /// noisy GPU measurement. The `derived` block is always computed from the
    /// per-batch medians.
    ///
    /// `kvBackend` is the operator-facing selection handed to the production
    /// factory. `.auto` resolves CONTIGUOUS as of v0.8.1 (see
    /// `EngineV2Factory.prepareProductionBackend`), so measuring paged
    /// requires naming it; an explicit `.paged`
    /// REFUSES rather than degrading. Either way the selection is not the
    /// outcome, so the report carries the backend each cell ACTUALLY built
    /// with — per cell in `decode[].resolvedKVBackend`, and de-duplicated in
    /// the `kvBackend` block.
    public static func run(
        modelID: String,
        modelDirectory: URL,
        promptLengths: [Int] = defaultPromptLengths,
        batchSizes: [Int] = defaultBatchSizes,
        decodeTokens: Int = defaultDecodeTokens,
        decodePromptTokens: Int = defaultDecodePromptTokens,
        decodeIterations: Int = defaultDecodeIterations,
        kvBackend: EngineV2KVBackendSelection = .auto,
        gemmaOptimizations: GemmaOptimizationSettings,
        hardware: HardwareInfo,
        efficiency: Double = DecodeBandwidthModel.defaultBandwidthEfficiency
    ) async throws -> ThroughputSweepReport {
        Memory.peakMemory = 0
        log("loading model \(modelID)")
        log("  path: \(modelDirectory.path)")

        // VLM checkpoints load through the VLM factory and serve through the
        // exact text tower owned by that wrapper, matching production.
        let isVLM = readHasVisionConfig(modelDirectory: modelDirectory)
        let container: ModelContainer
        if isVLM {
            container = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader()
            )
        } else {
            container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader()
            )
        }

        let facts = try await container.perform { ctx -> ModelFacts in
            eval(ctx.model.parameters().flattened().map { $0.1 })
            let params = ctx.model.parameters().flattened()
            let bytes = params.reduce(0) { $0 + $1.1.nbytes }
            let count = params.reduce(0) { $0 + $1.1.size }
            let base = ctx.tokenizer.encode(text: Self.seedText, addSpecialTokens: false)
            return ModelFacts(weightBytes: bytes, totalParams: count, baseTokens: base)
        }
        log("load memory: active_bytes=\(Memory.activeMemory) peak_bytes=\(Memory.peakMemory)")
        let baseTokens = facts.baseTokens.isEmpty ? [0] : facts.baseTokens
        log("  weights: \(String(format: "%.2f", Double(facts.weightBytes) / 1e9)) GB across \(facts.totalParams) params")

        let quantBits = readQuantBits(modelDirectory: modelDirectory)

        let prefill = await measurePrefill(
            container: container, baseTokens: baseTokens, lengths: promptLengths)
        let decodeOutcome = try await measureDecode(
            container: container,
            modelID: modelID,
            baseTokens: baseTokens,
            batchSizes: batchSizes,
            decodeTokens: decodeTokens,
            decodePromptTokens: decodePromptTokens,
            iterations: decodeIterations,
            weightBytes: facts.weightBytes,
            isVLM: isVLM,
            modelDirectory: modelDirectory,
            kvBackend: kvBackend
        )
        let decode = decodeOutcome.samples

        // One median sample per batch size: the B=1 implied read and the
        // batch-scaling linearity must not hang off a single measurement.
        let derived = ThroughputSweepReport.makeDerived(
            decode: medianDecodeByBatch(decode),
            totalParams: facts.totalParams,
            weightBytes: facts.weightBytes,
            quantBits: quantBits,
            bandwidthGBps: Double(hardware.memoryBandwidthGbs),
            efficiency: efficiency
        )

        let coverage = ThroughputSweepReport.DecodeCoverage(
            requestedBatchSizes: decodeOutcome.requestedBatchSizes,
            unmeasured: decodeOutcome.unmeasuredCells)

        let notes = makeNotes(
            hardware: hardware, efficiency: efficiency, derived: derived,
            kvBackend: kvBackend, resolvedBackends: decodeOutcome.resolvedBackends,
            coverage: coverage)

        // Only when NOTHING ran. A failure alongside cells that did resolve is
        // a partial result, not the story of the run, and must not be
        // presented as one.
        let constructionFailure = decodeOutcome.resolvedBackends.isEmpty
            ? decodeOutcome.constructionFailure.map {
                ThroughputSweepReport.DecodeConstructionFailure(
                    kvBackendSelection: kvBackend.rawValue, reason: $0)
            }
            : nil

        return ThroughputSweepReport(
            modelID: modelID,
            modelPath: modelDirectory.path,
            hardware: ThroughputSweepReport.Hardware(
                chipName: hardware.chipName,
                memoryGb: hardware.memoryGb,
                gpuCores: hardware.gpuCores,
                memoryBandwidthGbs: hardware.memoryBandwidthGbs
            ),
            prefill: prefill,
            decode: decode,
            derived: derived,
            notes: notes,
            gemmaOptimizations: BenchmarkGemmaOptimizations(
                settings: gemmaOptimizations),
            kvBackend: ThroughputSweepReport.KVBackend(
                selection: kvBackend.rawValue,
                resolved: decodeOutcome.resolvedBackends),
            decodeConstructionFailure: constructionFailure,
            decodeCoverage: coverage
        )
    }

    // MARK: - Prefill

    /// For each requested length L, run a single forward pass over an L-token
    /// prompt and report `L / prefill_seconds`. The whole sweep runs inside one
    /// `perform` (serialized GPU access); a small warm-up pass first pays the
    /// kernel-compile / Metal-pipeline cost so it is not charged to L=first.
    private static func measurePrefill(
        container: ModelContainer,
        baseTokens: [Int],
        lengths: [Int]
    ) async -> [ThroughputSweepReport.PrefillSample] {
        let cleaned = lengths.filter { $0 > 0 }.sorted()
        guard !cleaned.isEmpty else { return [] }
        log("prefill sweep: lengths \(cleaned)")

        return await container.perform { ctx -> [ThroughputSweepReport.PrefillSample] in
            // Warm-up (compile kernels) — not timed.
            let warm = Self.tile(baseTokens, to: 8)
            let warmCache = ctx.model.newCache(parameters: nil)
            var warmLogits = ctx.model.callAsFunction(
                MLXArray(warm.map { UInt32($0) }).reshaped([1, warm.count]), cache: warmCache)
            warmLogits = warmLogits[.ellipsis, -1, 0...]
            eval(warmLogits)

            var samples: [ThroughputSweepReport.PrefillSample] = []
            for length in cleaned {
                let tokens = Self.tile(baseTokens, to: length)
                let arr = MLXArray(tokens.map { UInt32($0) }).reshaped([1, length])
                let cache = ctx.model.newCache(parameters: nil)
                let start = ContinuousClock.now
                var logits = ctx.model.callAsFunction(arr, cache: cache)
                logits = logits[.ellipsis, -1, 0...]
                eval(logits)
                let secs = Self.seconds(ContinuousClock.now - start)
                let tps = secs > 0 ? Double(length) / secs : 0
                Self.log("  L=\(length): \(String(format: "%.1f", tps)) tok/s (\(String(format: "%.1f", secs * 1000)) ms)")
                samples.append(ThroughputSweepReport.PrefillSample(
                    promptTokens: length,
                    prefillTokensPerSecond: tps,
                    elapsedMs: secs * 1000
                ))
            }
            return samples
        }
    }

    // MARK: - Decode

    struct RowMeasure: Sendable {
        let produced: Int
        let elapsed: Duration
        /// Non-nil when submission, terminal status, or exact output-count
        /// validation failed. The row is invalid, not a performance sample.
        var submitFailure: String? = nil
        var timing: ThroughputSweepReport.DecodeRowTiming? = nil
    }

    /// Aggregate a batch's row measurements into one cell. Any row whose
    /// submission failed poisons the WHOLE cell: the curve point would be
    /// computed over fewer live sequences than the batch size it is labelled
    /// with, so the caller must record it as unmeasured rather than let a
    /// zero-token row deflate a "measured" sample. Internal (not private)
    /// so the poisoning rule is pinned by unit tests without a GPU.
    static func aggregateRows(_ rows: [RowMeasure]) -> (
        totalTokens: Int, maxElapsed: Duration, submitFailure: String?
    ) {
        var total = 0
        var maxElapsed: Duration = .zero
        var submitFailure: String?
        for row in rows {
            total += row.produced
            if row.elapsed > maxElapsed { maxElapsed = row.elapsed }
            if submitFailure == nil, let failure = row.submitFailure {
                submitFailure = failure
            }
        }
        return (total, maxElapsed, submitFailure)
    }

    /// Decode samples plus the KV backend the engine ACTUALLY built for those
    /// cells. A selection is not an outcome: a non-`.paged` selection may
    /// DEGRADE to contiguous on kill switch, kernel preflight, or pool
    /// capacity, and a release gate that cannot see the degradation silently
    /// measures the wrong backend. Since OPEN-9 an EXPLICIT `.paged` no
    /// longer degrades at all: it refuses, and `constructionFailure` is the
    /// only record of why the curve is empty. With `.auto` back on
    /// contiguous, explicit `.paged` — the opt-in — is the selection this
    /// distinction is load-bearing for.
    ///
    /// Refusal is per CELL, not per run: every batch size builds its own
    /// engine with its own `maxConcurrentRequests`, which feeds paged
    /// physical-capacity planning, so B=1 can resolve paged while B=8
    /// refuses. `requestedBatchSizes` versus `unmeasuredCells` is that
    /// partial case — invisible in `resolvedBackends`, which stays non-empty
    /// as long as ANY cell built.
    private struct DecodeOutcome {
        var samples: [ThroughputSweepReport.DecodeSample] = []
        /// Distinct resolved-backend descriptors, in first-seen order. EMPTY
        /// means no cell ever built an engine.
        var resolvedBackends: [String] = []
        /// Last construction error seen, verbatim. Meaningful only when
        /// `resolvedBackends` is empty — otherwise some cells did run and a
        /// single failure is a partial result, not the story of the run.
        var constructionFailure: String?
        /// Every batch size the sweep set out to measure, ascending.
        var requestedBatchSizes: [Int] = []
        /// The requested cells that never built an engine. One entry per
        /// batch size: a cell that refused in ANY repetition is unmeasured,
        /// since the median it contributes to is then computed over a
        /// placeholder zero.
        var unmeasuredCells: [ThroughputSweepReport.UnmeasuredCell] = []

        /// Returns true when `descriptor` had not been seen before.
        @discardableResult
        mutating func record(_ descriptor: String?) -> Bool {
            guard let descriptor, !resolvedBackends.contains(descriptor) else { return false }
            resolvedBackends.append(descriptor)
            return true
        }

        /// Returns true when this batch size had not already been recorded
        /// as unmeasured.
        @discardableResult
        mutating func recordUnmeasured(batchSize: Int, reason: String) -> Bool {
            guard !unmeasuredCells.contains(where: { $0.batchSize == batchSize })
            else { return false }
            unmeasuredCells.append(
                ThroughputSweepReport.UnmeasuredCell(batchSize: batchSize, reason: reason))
            return true
        }
    }

    /// For each batch size B, build a fresh `BatchedEngine`, submit B greedy
    /// requests (each with a distinct rotated prompt so MoE routing differs
    /// per row), drop the first emitted token per row, and report legacy row
    /// throughput plus raw shared-clock timing for the all-row decode overlap.
    ///
    /// The whole curve is repeated `iterations` times, batch-size-inner /
    /// repetition-outer, so slow thermal drift is shared across batch sizes
    /// instead of being charged entirely to the last one. Every repetition is
    /// returned as its own sample; medians are the caller's job.
    ///
    /// Engines run one batch size at a time: two engines on the same
    /// `ModelContainer` race shared MLX/Metal state and produce noise (matches
    /// `PerformanceLiveTests`).
    private static func measureDecode(
        container: ModelContainer,
        modelID: String,
        baseTokens: [Int],
        batchSizes: [Int],
        decodeTokens: Int,
        decodePromptTokens: Int,
        iterations: Int,
        weightBytes: Int,
        isVLM: Bool,
        modelDirectory: URL,
        kvBackend: EngineV2KVBackendSelection
    ) async throws -> DecodeOutcome {
        let sizes = batchSizes.filter { $0 > 0 }.sorted()
        guard !sizes.isEmpty else { return DecodeOutcome() }
        let promptLen = max(1, decodePromptTokens)
        let genTokens = max(1, decodeTokens)
        let repetitions = max(1, iterations)
        log("decode sweep: batch sizes \(sizes), \(genTokens) tok/seq, prompt \(promptLen) tok/seq, \(repetitions) repetition(s), kv backend selection \(kvBackend.rawValue)")

        var outcome = DecodeOutcome()
        outcome.requestedBatchSizes = sizes

        // Warm every requested shape before recording samples. A B=1 warmup
        // alone does not compile the B=2/B=4/B=8 kernels being compared.
        // Use the measured generation length: with long prompts, eight
        // warmup tokens can finish early rows before the full batch exists.
        for batchSize in sizes {
            log("warming decode shape: B=\(batchSize), prompt=\(promptLen), decode=\(genTokens) (unmeasured)")
            let warmUp = await runDecodeBatch(
                container: container, modelID: modelID, baseTokens: baseTokens,
                batchSize: batchSize, decodeTokens: genTokens, promptLen: promptLen,
                weightBytes: weightBytes, isVLM: isVLM,
                modelDirectory: modelDirectory, kvBackend: kvBackend)
            if let failure = warmUp.constructionFailure {
                outcome.constructionFailure = failure
            }
        }

        for iteration in 1 ... repetitions {
            for batchSize in sizes {
                let (totalTokens, maxElapsed, resolved, failure, submitFailure, timing) = await runDecodeBatch(
                    container: container, modelID: modelID, baseTokens: baseTokens,
                    batchSize: batchSize, decodeTokens: genTokens, promptLen: promptLen,
                    weightBytes: weightBytes, isVLM: isVLM,
                    modelDirectory: modelDirectory, kvBackend: kvBackend)
                if outcome.record(resolved), let resolved {
                    log("  engine resolved kv backend: \(resolved)")
                }
                if let failure {
                    outcome.constructionFailure = failure
                    if outcome.recordUnmeasured(batchSize: batchSize, reason: failure) {
                        log("  B=\(batchSize): NO measurement — \(failure)")
                    }
                }
                if let submitFailure {
                    // The engine BUILT (resolved backend recorded above) but
                    // a row's submission, terminal, or emitted-token count failed. The cell
                    // decoded fewer live rows than its label claims, so it is
                    // UNMEASURED (which fails an explicit-backend sweep via
                    // decodeCoverage), never a zero-deflated sample.
                    if outcome.recordUnmeasured(
                        batchSize: batchSize, reason: "row failed: \(submitFailure)")
                    {
                        log("  B=\(batchSize): NO measurement — row failed: \(submitFailure)")
                    }
                    continue
                }
                let secs = seconds(maxElapsed)
                let aggregate = secs > 0 ? Double(totalTokens) / secs : 0
                let perSeq = aggregate / Double(batchSize)
                log("  [\(iteration)/\(repetitions)] B=\(batchSize): aggregate \(String(format: "%.1f", aggregate)) tok/s, per-seq \(String(format: "%.1f", perSeq)) tok/s")
                outcome.samples.append(ThroughputSweepReport.DecodeSample(
                    batchSize: batchSize,
                    decodeTokensPerSequence: genTokens,
                    aggregateTokensPerSecond: aggregate,
                    perSequenceTokensPerSecond: perSeq,
                    elapsedMs: secs * 1000,
                    resolvedKVBackend: resolved,
                    decodeTiming: timing
                ))
            }
        }
        return outcome
    }

    /// Build the production CBv2 engine (`EngineV2Factory.makeProductionBuild`
    /// — the same construction every serving slot uses), run `batchSize`
    /// greedy rows to completion, shut the engine down, and return
    /// `(totalDecodedTokens, maxRowElapsed, resolvedBackend,
    /// constructionFailure, submitFailure)` where the clock starts after
    /// each row's first token (prefill excluded), `resolvedBackend` names
    /// the KV backend the factory actually chose (nil when construction
    /// failed), and `submitFailure` is non-nil when the engine built but any
    /// row's `engine.submit` threw — the cell is then unmeasured, never a
    /// zero-token sample (see `aggregateRows`).
    @discardableResult
    private static func runDecodeBatch(
        container: ModelContainer,
        modelID: String,
        baseTokens: [Int],
        batchSize: Int,
        decodeTokens: Int,
        promptLen: Int,
        weightBytes: Int,
        isVLM: Bool,
        modelDirectory: URL,
        kvBackend: EngineV2KVBackendSelection
    ) async -> (
        totalTokens: Int, maxElapsed: Duration, resolvedBackend: String?,
        constructionFailure: String?, submitFailure: String?,
        timing: ThroughputSweepReport.DecodeTiming?
    ) {
        // The engine's KV admission ceiling: the same unified-memory budget a
        // single-model provider slot would be granted. Far above what these
        // short rows need — admission never binds in the sweep.
        let kvCapacity = Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, weightBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))
        struct EngineParts: @unchecked Sendable {
            let engine: any CBv2Engine
            /// The backend the factory resolved to, with any fallback reason.
            let resolvedBackend: String
        }
        let parts: EngineParts
        do {
            parts = try await container.perform { ctx -> EngineParts in
                // Serving-model resolution matches production: VLM checkpoints
                // use the exact text tower owned by the loaded wrapper.
                let servingModel = try EngineV2Factory.benchmarkServingModel(
                    model: ctx.model, isVLM: isVLM, modelDirectory: modelDirectory)
                // `makeProductionBuild` is the construction
                // `makeProductionEngine` wraps, and additionally hands back the
                // backend kind the engine actually resolved to — the fact a
                // paged gate run has to record.
                let build = try EngineV2Factory.makeProductionBuild(
                    model: servingModel,
                    tokenizer: ctx.tokenizer,
                    kvBytesCapacity: kvCapacity,
                    maxConcurrentRequests: max(batchSize, 1),
                    kvBackend: kvBackend)
                return EngineParts(
                    engine: build.engine,
                    resolvedBackend: build.resolvedKVBackendDescriptor)
            }
        } catch {
            // Since OPEN-9 this is the path an explicit `--kv-backend paged`
            // takes when paged cannot be served: a refusal, not a degrade.
            // Return the reason so the report and the process exit status can
            // both name it instead of showing a bare curve of zeros.
            log("  engine construction failed: \(error)")
            return (0, .zero, nil, "\(error)", nil, nil)
        }
        let engine = parts.engine

        // Each row timestamps against one epoch; independent row durations
        // cannot establish the interval when all B rows are decoding.
        Memory.peakMemory = 0
        let epoch = ContinuousClock.now
        let rows = await withTaskGroup(of: RowMeasure.self) { group -> [RowMeasure] in
            for i in 0 ..< batchSize {
                let prompt = Self.tile(baseTokens, to: promptLen, offset: i * 7 + 1)
                group.addTask { [engine] in
                    let submittedMs = Self.seconds(ContinuousClock.now - epoch) * 1000
                    let stream: AsyncStream<CBv2Event>
                    do {
                        stream = try engine.submit(CBv2Request(
                            id: CBv2RequestID(UInt64(i + 1)),
                            promptTokens: prompt,
                            sampling: CBv2SamplingParams(temperature: 0.0),
                            maxTokens: decodeTokens + 1,
                            stopTokens: Self.fixedBudgetStopTokens
                        ))
                    } catch {
                        return RowMeasure(
                            produced: 0, elapsed: .zero, submitFailure: "\(error)")
                    }
                    var tokenIDs: [Int] = []
                    var timestamps: [Double] = []
                    var finishReason: CBv2FinishReason?
                    var finishedMs = submittedMs
                    loop: for await event in stream {
                        let nowMs = Self.seconds(ContinuousClock.now - epoch) * 1000
                        switch event {
                        case .delta(_, let tokens, _):
                            tokenIDs.append(contentsOf: tokens)
                            timestamps.append(contentsOf: repeatElement(nowMs, count: tokens.count))
                        case .finished(let reason, _):
                            finishReason = reason
                            finishedMs = nowMs
                            break loop
                        }
                    }
                    let timing = ThroughputSweepReport.DecodeRowTiming(
                        row: i, submittedAtMs: submittedMs,
                        tokenIDs: tokenIDs, tokenArrivalMs: timestamps,
                        finishedAtMs: finishedMs,
                        finishReason: finishReason.map { String(describing: $0) } ?? "missing")
                    let failure = Self.decodeRowFailure(
                        expectedTokens: decodeTokens + 1,
                        tokenCount: tokenIDs.count, finishReason: finishReason)
                    let elapsedMs = max(0, finishedMs - (timestamps.first ?? finishedMs))
                    return RowMeasure(
                        produced: max(0, tokenIDs.count - 1),
                        elapsed: .seconds(elapsedMs / 1000),
                        submitFailure: failure, timing: timing)
                }
            }
            var rows: [RowMeasure] = []
            for await row in group { rows.append(row) }
            return rows
        }
        let peakMemoryBytes = Memory.peakMemory
        let cell = Self.aggregateRows(rows)
        let timing = ThroughputSweepReport.DecodeTiming.make(
            rows: rows.compactMap(\.timing).sorted { $0.row < $1.row },
            peakMemoryBytes: peakMemoryBytes, decodePromptTokens: promptLen)
        await engine.shutdown()
        return (
            totalTokens: cell.totalTokens, maxElapsed: cell.maxElapsed,
            resolvedBackend: parts.resolvedBackend, constructionFailure: nil,
            submitFailure: cell.submitFailure, timing: timing)
    }

    // MARK: - Helpers

    /// A neutral seed paragraph; we only need a valid in-vocabulary token
    /// stream to tile to arbitrary prompt lengths. Content is irrelevant to the
    /// bytes/token a forward pass reads.
    static let seedText = """
    The quick brown fox jumps over the lazy dog while the engineer measures \
    throughput across many prompt lengths and batch sizes. Memory bandwidth, \
    not raw compute, sets the pace of autoregressive decoding on unified \
    memory systems, so we stream weights and count tokens carefully.
    """

    /// Repeat/rotate `base` to produce exactly `length` valid token ids.
    static func tile(_ base: [Int], to length: Int, offset: Int = 0) -> [Int] {
        guard length > 0 else { return [] }
        guard !base.isEmpty else { return Array(repeating: 0, count: length) }
        var out = [Int]()
        out.reserveCapacity(length)
        var i = ((offset % base.count) + base.count) % base.count
        while out.count < length {
            out.append(base[i])
            i += 1
            if i == base.count { i = 0 }
        }
        return out
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    /// Collapse repeated decode measurements to one median sample per batch
    /// size, ascending. Feeding this (not the raw repetition list) to
    /// `makeDerived` keeps the B=1 implied read and the batch-scaling
    /// linearity off a single noisy measurement, and stops a repeated batch
    /// size from being counted N times in the linearity average.
    static func medianDecodeByBatch(
        _ samples: [ThroughputSweepReport.DecodeSample]
    ) -> [ThroughputSweepReport.DecodeSample] {
        var grouped: [Int: [ThroughputSweepReport.DecodeSample]] = [:]
        for sample in samples { grouped[sample.batchSize, default: []].append(sample) }
        return grouped.keys.sorted().compactMap { batchSize in
            guard let group = grouped[batchSize], let first = group.first else { return nil }
            return ThroughputSweepReport.DecodeSample(
                batchSize: batchSize,
                decodeTokensPerSequence: first.decodeTokensPerSequence,
                aggregateTokensPerSecond: median(group.map(\.aggregateTokensPerSecond)),
                perSequenceTokensPerSecond: median(group.map(\.perSequenceTokensPerSecond)),
                elapsedMs: median(group.map(\.elapsedMs))
            )
        }
    }

    /// Low median for even counts is avoided: use the two-sided average so the
    /// result matches Python's `statistics.median` (the runner recomputes it).
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Whether config.json declares `vision_config` (load through VLMModelFactory
    /// and serve through the wrapper-owned text tower).
    static func readHasVisionConfig(modelDirectory: URL) -> Bool {
        let url = modelDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return obj["vision_config"] != nil
    }

    /// Best-effort read of the quantization bit width from config.json.
    static func readQuantBits(modelDirectory: URL) -> Int? {
        let url = modelDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["quantization", "quantization_config"] {
            if let q = obj[key] as? [String: Any] {
                if let bits = q["bits"] as? Int { return bits }
                if let bits = (q["bits"] as? NSNumber)?.intValue { return bits }
            }
        }
        return nil
    }

    private static func makeNotes(
        hardware: HardwareInfo,
        efficiency: Double,
        derived: ThroughputSweepReport.Derived,
        kvBackend: EngineV2KVBackendSelection,
        resolvedBackends: [String],
        coverage: ThroughputSweepReport.DecodeCoverage
    ) -> [String] {
        var notes: [String] = []
        notes.append(
            "kv backend: selection=\(kvBackend.rawValue), resolved="
                + (resolvedBackends.isEmpty
                    ? "n/a (no decode cells ran)"
                    : resolvedBackends.joined(separator: " + "))
                + " — decode numbers describe the RESOLVED backend, not the selection.")
        if !coverage.unmeasured.isEmpty {
            notes.append(
                "UNMEASURED: \(coverage.unmeasured.count) of "
                    + "\(coverage.requestedBatchSizes.count) requested decode cells built no "
                    + "engine — "
                    + coverage.unmeasured
                        .map { "B=\($0.batchSize): \($0.reason)" }
                        .joined(separator: "; ")
                    + ". Their samples are placeholder zeros, not measurements.")
        }
        notes.append(
            "implied per-token read assumes \(Int(efficiency * 100))% of \(hardware.memoryBandwidthGbs) GB/s peak bandwidth.")
        notes.append(
            "regime=\(derived.regime.rawValue): B=1 reads ~\(String(format: "%.1f", derived.impliedReadFractionOfWeights * 100))% of total weights per token.")
        if derived.regime == .dense {
            notes.append(
                "DENSE-LIKE: per-token read ≈ full model — expert sparsity is NOT being exploited at decode.")
        } else if derived.regime == .sparse {
            notes.append(
                "SPARSE: per-token read ≪ full model — expert sparsity is being exploited.")
        }
        if let lin = derived.batchScalingLinearity {
            notes.append(
                "batch-scaling linearity=\(String(format: "%.2f", lin)) (≈1.0 dense-like, <1.0 sparse-like; only meaningful when B=1 is bandwidth-bound).")
        }
        notes.append(
            "decode tok/s and prefill tok/s are most meaningful in a release build (swift build -c release).")
        return notes
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[sweep] \(message)\n".utf8))
    }
}
