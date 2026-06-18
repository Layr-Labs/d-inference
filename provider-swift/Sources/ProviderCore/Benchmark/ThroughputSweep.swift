import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Prefill-throughput + per-batch decode-throughput sweep for a loaded MLX
/// model. Produces a `ThroughputSweepReport` (JSON).
///
/// Reuses the provider's real inference stack — it loads the model with the
/// same `LLMModelFactory` + `LocalTokenizerLoader` the serve path uses, runs
/// prefill through `model.callAsFunction(_:cache:)`, and runs decode through
/// `MLXLMCommon.BatchedEngine` (the exact continuous-batching engine
/// `BatchScheduler` wraps in production). It does **not** reimplement any
/// inference numerics; it only drives the engine and times it.
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

    /// Snapshot of model facts read once, off-actor, inside `perform`.
    private struct ModelFacts: Sendable {
        let weightBytes: Int
        let totalParams: Int
        let baseTokens: [Int]
    }

    /// Run the full sweep. `hardware` supplies the peak memory bandwidth used to
    /// invert decode tok/s into implied bytes/token.
    public static func run(
        modelID: String,
        modelDirectory: URL,
        promptLengths: [Int] = defaultPromptLengths,
        batchSizes: [Int] = defaultBatchSizes,
        decodeTokens: Int = defaultDecodeTokens,
        decodePromptTokens: Int = defaultDecodePromptTokens,
        hardware: HardwareInfo,
        efficiency: Double = DecodeBandwidthModel.defaultBandwidthEfficiency
    ) async throws -> ThroughputSweepReport {
        log("loading model \(modelID)")
        log("  path: \(modelDirectory.path)")

        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: LocalTokenizerLoader()
        )

        let facts = try await container.perform { ctx -> ModelFacts in
            let params = ctx.model.parameters().flattened()
            let bytes = params.reduce(0) { $0 + $1.1.nbytes }
            let count = params.reduce(0) { $0 + $1.1.size }
            let base = ctx.tokenizer.encode(text: Self.seedText, addSpecialTokens: false)
            return ModelFacts(weightBytes: bytes, totalParams: count, baseTokens: base)
        }
        let baseTokens = facts.baseTokens.isEmpty ? [0] : facts.baseTokens
        log("  weights: \(String(format: "%.2f", Double(facts.weightBytes) / 1e9)) GB across \(facts.totalParams) params")

        let quantBits = readQuantBits(modelDirectory: modelDirectory)

        let prefill = await measurePrefill(
            container: container, baseTokens: baseTokens, lengths: promptLengths)
        let decode = await measureDecode(
            container: container,
            modelID: modelID,
            baseTokens: baseTokens,
            batchSizes: batchSizes,
            decodeTokens: decodeTokens,
            decodePromptTokens: decodePromptTokens
        )

        let derived = ThroughputSweepReport.makeDerived(
            decode: decode,
            totalParams: facts.totalParams,
            weightBytes: facts.weightBytes,
            quantBits: quantBits,
            bandwidthGBps: Double(hardware.memoryBandwidthGbs),
            efficiency: efficiency
        )

        let notes = makeNotes(hardware: hardware, efficiency: efficiency, derived: derived)

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
            notes: notes
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

    private struct RowMeasure: Sendable {
        let produced: Int
        let elapsed: Duration
    }

    /// For each batch size B, build a fresh `BatchedEngine`, submit B greedy
    /// requests (each with a distinct rotated prompt so MoE routing differs
    /// per row), drop the first emitted token per row to exclude prefill, and
    /// report the aggregate + per-sequence steady-state decode tok/s.
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
        decodePromptTokens: Int
    ) async -> [ThroughputSweepReport.DecodeSample] {
        let sizes = batchSizes.filter { $0 > 0 }.sorted()
        guard !sizes.isEmpty else { return [] }
        let promptLen = max(1, decodePromptTokens)
        let genTokens = max(1, decodeTokens)
        log("decode sweep: batch sizes \(sizes), \(genTokens) tok/seq, prompt \(promptLen) tok/seq")

        // Warm-up at B=1 with a short generation to compile decode kernels.
        await runDecodeBatch(
            container: container, modelID: modelID, baseTokens: baseTokens,
            batchSize: 1, decodeTokens: 4, promptLen: promptLen)

        var samples: [ThroughputSweepReport.DecodeSample] = []
        for batchSize in sizes {
            let (totalTokens, maxElapsed) = await runDecodeBatch(
                container: container, modelID: modelID, baseTokens: baseTokens,
                batchSize: batchSize, decodeTokens: genTokens, promptLen: promptLen)
            let secs = seconds(maxElapsed)
            let aggregate = secs > 0 ? Double(totalTokens) / secs : 0
            let perSeq = aggregate / Double(batchSize)
            log("  B=\(batchSize): aggregate \(String(format: "%.1f", aggregate)) tok/s, per-seq \(String(format: "%.1f", perSeq)) tok/s")
            samples.append(ThroughputSweepReport.DecodeSample(
                batchSize: batchSize,
                decodeTokensPerSequence: genTokens,
                aggregateTokensPerSecond: aggregate,
                perSequenceTokensPerSecond: perSeq,
                elapsedMs: secs * 1000
            ))
        }
        return samples
    }

    /// Build + start a `BatchedEngine`, run `batchSize` rows to completion, stop
    /// the engine, and return `(totalDecodedTokens, maxRowElapsed)` where the
    /// clock starts after each row's first token (prefill excluded).
    @discardableResult
    private static func runDecodeBatch(
        container: ModelContainer,
        modelID: String,
        baseTokens: [Int],
        batchSize: Int,
        decodeTokens: Int,
        promptLen: Int
    ) async -> (totalTokens: Int, maxElapsed: Duration) {
        let engine = await container.perform { ctx -> BatchedEngine in
            let scheduler = Scheduler(
                model: ctx.model,
                tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: max(batchSize, 1),
                    maxNumBatchedTokens: 8192,
                    prefillStepSize: 2048,
                    streamInterval: 1
                ),
                eosTokenIds: ctx.configuration.eosTokenIds,
                prefixCache: nil
            )
            return BatchedEngine(
                scheduler: scheduler,
                tokenizer: ctx.tokenizer,
                modelName: modelID,
                config: ContinuousBatchingConfig(
                    schedulerConfig: scheduler.config,
                    stepInterval: 0.001,
                    prefixCacheConfig: nil,
                    mtpEnabled: false
                ),
                externalChatTemplate: nil
            )
        }
        await engine.start()

        let result = await withTaskGroup(of: RowMeasure.self) { group -> (Int, Duration) in
            for i in 0 ..< batchSize {
                // Distinct rotated prompt per row so each sequence routes to a
                // different mix of experts (otherwise identical prompts would
                // all hit the same top-K experts and understate expert traffic).
                let prompt = Self.tile(baseTokens, to: promptLen, offset: i * 7 + 1)
                let id = "sweep-\(batchSize)-\(i)-\(UUID().uuidString.prefix(6))"
                group.addTask { [engine] in
                    _ = await engine.core.addRequest(Request(
                        requestId: id,
                        prompt: prompt as AnyHashable,
                        samplingParams: SamplingParams(maxTokens: decodeTokens + 1, temperature: 0.0)
                    ))
                    var sawFirst = false
                    var start = ContinuousClock.now
                    var produced = 0
                    for await output in engine.core.streamOutputs(requestId: id) {
                        if !sawFirst {
                            sawFirst = true
                            start = ContinuousClock.now
                        } else {
                            produced += output.newTokenIds.count
                        }
                        if output.finished || output.error != nil { break }
                    }
                    return RowMeasure(produced: produced, elapsed: ContinuousClock.now - start)
                }
            }
            var total = 0
            var maxElapsed: Duration = .zero
            for await row in group {
                total += row.produced
                if row.elapsed > maxElapsed { maxElapsed = row.elapsed }
            }
            return (total, maxElapsed)
        }

        await engine.stop()
        return result
    }

    // MARK: - Helpers

    /// A neutral seed paragraph; we only need a valid in-vocabulary token
    /// stream to tile to arbitrary prompt lengths. Content is irrelevant to the
    /// bytes/token a forward pass reads.
    private static let seedText = """
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
        derived: ThroughputSweepReport.Derived
    ) -> [String] {
        var notes: [String] = []
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
