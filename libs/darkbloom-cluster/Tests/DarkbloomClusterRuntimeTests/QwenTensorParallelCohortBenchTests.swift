import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Opt-in local timing of whole speculative cohort rounds on ONE Mac with a
/// real dense Qwen TP shard, its real assistant and no peer
/// (`QwenTensorParallelLocalReduction`: outputs and acceptance are not a
/// tensor-parallel result, so every row is simply driven through rounds).
/// Each width runs the cohort's drafts row by row and through one head call per
/// draft step, reporting the round profile's phases (median ms) and the
/// evaluations a draft needs. A pair adds two collectives per evaluation.
/// Treatments are interleaved A/B then B/A per width and repetition (ABBA), so
/// GPU drift over the run cancels instead of reading as a gain; each run's
/// medians are reported and then pooled per treatment.
/// QWEN_TP_COHORT_BENCH_MODEL=<model dir with mtp-*.safetensors>
/// [QWEN_TP_COHORT_BENCH_RANK=1] [QWEN_TP_COHORT_BENCH_SHARES=1,1] [QWEN_TP_COHORT_BENCH_WIDTHS=1,2,4,8]
/// [QWEN_TP_COHORT_BENCH_DEPTH=3] [QWEN_TP_COHORT_BENCH_ROUNDS=10] [QWEN_TP_COHORT_BENCH_PROMPT=256]
/// [QWEN_TP_COHORT_BENCH_REPEATS=2] [QWEN_TP_COHORT_BENCH_LOG=<file>]
@Suite(.serialized)
struct QwenTensorParallelCohortBenchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_COHORT_BENCH_MODEL"] != nil))
    func cohortRoundPhasesByWidthAndDraftBatching() throws {
        let environment = ProcessInfo.processInfo.environment
        func ints(_ name: String, _ fallback: [Int]) -> [Int] {
            let parsed = (environment[name] ?? "").split(separator: ",").compactMap { Int($0) }
            return parsed.isEmpty ? fallback : parsed
        }
        let directory = URL(fileURLWithPath: environment["QWEN_TP_COHORT_BENCH_MODEL"]!, isDirectory: true)
        let rank = ints("QWEN_TP_COHORT_BENCH_RANK", [1])[0], shares = ints("QWEN_TP_COHORT_BENCH_SHARES", [1, 1])
        let widths = ints("QWEN_TP_COHORT_BENCH_WIDTHS", [1, 2, 4, 8]), depth = ints("QWEN_TP_COHORT_BENCH_DEPTH", [3])[0]
        let rounds = ints("QWEN_TP_COHORT_BENCH_ROUNDS", [10])[0], prompt = ints("QWEN_TP_COHORT_BENCH_PROMPT", [256])[0]
        let repeats = ints("QWEN_TP_COHORT_BENCH_REPEATS", [2])[0]
        let log: FileHandle? = environment["QWEN_TP_COHORT_BENCH_LOG"].flatMap { path in
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        func report(_ line: String) {
            print(line)
            log?.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8))
        }
        try Device.withDefaultDevice(.gpu) {
            let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            let reduction = QwenTensorParallelLocalReduction(rank: rank, size: 2)
            let model = try QwenTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank, size: 2),
                reduction: reduction, shares: shares)
            var assistantWeights: [String: MLXArray] = [:]
            for file in try FileManager.default.contentsOfDirectory(atPath: directory.path)
            where file.hasPrefix("mtp-") && file.hasSuffix(".safetensors") {
                // The owner indexes the assistant without its checkpoint prefix
                // (`QwenTensorParallelMTPInventory`: "mtp.fc.weight" -> "fc.weight").
                for (name, value) in try loadArrays(url: directory.appendingPathComponent(file)) {
                    assistantWeights[name.hasPrefix("mtp.") ? String(name.dropFirst("mtp.".count)) : name] = value
                }
            }
            eval(Array(assistantWeights.values))
            let head = try QwenTensorParallelMTPHead(model: model, configuration: configuration,
                indexedWeights: assistantWeights, reduction: reduction)
            let maximum = widths.max() ?? 1
            let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: maximum,
                maximumTokensPerRequest: 4096, maximumChunkTokens: 512)
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-cohort-bench",
                vocabularySize: model.plan.vocabularySize, hiddenSize: model.plan.hiddenSize, activationDType: "bfloat16",
                maximumPromptTokens: 2048, maximumChunkTokens: 512, maximumOutputTokens: 1024, maximumContextTokens: 4096)
            report("qwen-tp-cohort-bench rank=\(rank) shares=\(shares) depth=\(depth) prompt=\(prompt)"
                + " fast_synch=\(environment["MLX_METAL_FAST_SYNCH"] ?? "unset") gpu=\(GPU.deviceInfo().architecture)")
            func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
            let names = ["draft", "build", "verify", "gather", "choose", "settle"]
            var pooled: [String: [String: [Double]]] = [:]
            // Treatments: row-by-row drafts on MLX's kernels, one head call on
            // MLX's kernels, and exact drafts (`draftsOnExactVectors`: the head
            // and the round's later steps on `AffineQuantizedVectors`, all rows
            // in one forward). One row compares MLX's and the exact kernels.
            struct Treatment { let batched: Bool; let exact: Bool
                var name: String { exact ? "exact" : (batched ? "one-head-call" : "row-by-row") } }
            func treatments(_ width: Int) -> [Treatment] {
                width > 1 ? [.init(batched: false, exact: false), .init(batched: true, exact: false), .init(batched: true, exact: true)]
                    : [.init(batched: true, exact: false), .init(batched: true, exact: true)]
            }
            for (repeatIndex, width) in (0..<repeats).flatMap({ index in widths.map { (index, $0) } }) {
                // ABBA: the treatments in order on even repetitions, reversed on odd ones.
                let order = repeatIndex % 2 == 0 ? treatments(width) : Array(treatments(width).reversed())
                for treatment in order {
                  try QwenTensorParallelMTPDecoder.$draftsOnExactVectorsOverride.withValue(treatment.exact) {
                    let batched = treatment.batched
                    var decoders: [QwenTensorParallelMTPDecoder] = [], last: [Int] = []
                    for row in 0..<width {
                        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                            promptTokenIDs: (0..<prompt).map { ($0 * 131 + row * 17 + 11) % 150_000 },
                            chunkSize: 512, outputCount: 1024, stopTokenIDs: [])
                        let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                            host: host, request: request)
                        let decoder = try QwenTensorParallelMTPDecoder(target: session, head: head, group: reduction, depth: depth)
                        var logits: MLXArray?
                        while session.schedule.committedPromptTokens < request.promptCount {
                            logits = try decoder.prefill(check: {}) ?? logits
                        }
                        let first = Int(argMax(try #require(logits).asType(.float32).reshaped([-1]), axis: -1).item(Int32.self))
                            % model.plan.vocabularySize
                        try decoder.begin(firstToken: first)
                        decoders.append(decoder); last.append(first)
                    }
                    var phases: [String: [Double]] = [:], emitted = 0
                    for round in 0..<rounds {
                        let remaining = decoders.map { 1024 - $0.statistics.emittedTokens - 1 }
                        let results: [QwenTensorParallelMTPDecoder.Emitted]
                        if width == 1 {
                            results = [try decoders[0].step(lastToken: last[0], remaining: remaining[0], check: {})]
                        } else {
                            results = try QwenTensorParallelMTPDecoder.stepBatch(decoders, lastTokens: last,
                                remaining: remaining, batchesDrafts: batched, check: {})
                        }
                        last = results.map { $0.tokens.last! }
                        emitted += results.reduce(0) { $0 + $1.tokens.count }
                        guard round >= 2, let profile = decoders[0].lastProfile else { continue }
                        for (name, value) in [("draft", profile.draft), ("build", profile.build), ("verify", profile.verify),
                                              ("gather", profile.gather), ("choose", profile.choose), ("settle", profile.settle)] {
                            phases[name, default: []].append(Double(value) / 1e6)
                        }
                    }
                    let parts = names.map { "\($0)_ms=\(String(format: "%.2f", median(phases[$0] ?? [])))" }.joined(separator: " ")
                    let total = names.reduce(0) { $0 + median(phases[$1] ?? []) }
                    let key = "rows=\(width) drafts=\(treatment.name)"
                    for name in names { pooled[key, default: [:]][name, default: []] += phases[name] ?? [] }
                    report("qwen-tp-cohort-bench repeat=\(repeatIndex) \(key)"
                        + " draft_evaluations_per_round=\(batched || width == 1 ? depth : depth * width) \(parts)"
                        + " round_ms=\(String(format: "%.2f", total)) emitted=\(emitted)")
                    for decoder in decoders { try decoder.retire() }
                  }
                }
            }
            for width in widths {
                for treatment in treatments(width) {
                    let key = "rows=\(width) drafts=\(treatment.name)"
                    let phases = pooled[key] ?? [:]
                    let parts = names.map { "\($0)_ms=\(String(format: "%.2f", median(phases[$0] ?? [])))" }.joined(separator: " ")
                    let total = names.reduce(0) { $0 + median(phases[$1] ?? []) }
                    report("qwen-tp-cohort-bench pooled \(key) samples=\((phases["verify"] ?? []).count) \(parts)"
                        + " round_ms=\(String(format: "%.2f", total))")
                }
            }
            #expect(host.isDrained)
        }
    }

    /// Opt-in: the complete native LOAD quote this build prices for a real
    /// artifact, by width (QWEN_TP_QUOTE_MODEL=<model dir>, optional
    /// QWEN_TP_QUOTE_DEPTH=3, QWEN_TP_QUOTE_PROMPT=32768, QWEN_TP_QUOTE_OUTPUT=32768,
    /// QWEN_TP_QUOTE_LANES=1,2,4,8, QWEN_TP_QUOTE_CHUNK=512),
    /// the same derivation as `darkbloom-cluster-plan tensor-batch-scope`; the
    /// `-bytes` line gives each split's LOAD reservation per rank in bytes
    /// (`rankReservedBytes`: collective scratch included), as the planner reads it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_QUOTE_MODEL"] != nil))
    func completeLoadQuoteByWidth() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["QWEN_TP_QUOTE_MODEL"]!, isDirectory: true)
        let depth = Int(environment["QWEN_TP_QUOTE_DEPTH"] ?? "3") ?? 3
        let prompt = Int(environment["QWEN_TP_QUOTE_PROMPT"] ?? "32768") ?? 32768
        let output = Int(environment["QWEN_TP_QUOTE_OUTPUT"] ?? "32768") ?? 32768
        let chunk = Int(environment["QWEN_TP_QUOTE_CHUNK"] ?? "512") ?? 512
        let gib = Double(1 << 30)
        let widths = (environment["QWEN_TP_QUOTE_LANES"] ?? "").split(separator: ",").compactMap { Int($0) }
        for lanes in widths.isEmpty ? [1, 2, 4, 8] : widths {
            // Depth 0: the plain target quote (rows without a tensor-parallel assistant).
            let quote = try ClusterPlacementArtifact.requestedTensorBatchQuote(directory: directory,
                promptTokens: prompt, outputTokens: output, chunkTokens: chunk, lanes: lanes,
                assistantDepth: depth > 0 ? depth : nil,
                assistantVerification: depth > 0 && lanes > 1 ? .admittedCohort : .singleton,
                allocationBound: { try Memory.allocationFootprintUpperBound(byteCount: $0) })
            let ranks = (quote.rankQuotes ?? []).map { entry in
                "\(entry.shares.map(String.init).joined(separator: ":"))=" + entry.requestBytesExcludingCollectives
                    .map { String(format: "%.2f", Double($0) / gib) }.joined(separator: "/")
            }.joined(separator: " ")
            print("qwen-tp-load-quote lanes=\(lanes) depth=\(depth) per_lane_gib=\(String(format: "%.2f", Double(quote.perLaneStateBytes) / gib))"
                + " shared_gib=\(String(format: "%.2f", Double(quote.sharedBytesExcludingCollectives) / gib))"
                + " whole_gib=\(String(format: "%.2f", Double(quote.allowance.requestBytesExcludingCollectives) / gib)) ranks \(ranks)")
            let reserved = (quote.rankQuotes ?? []).map { entry in
                "\(entry.shares.map(String.init).joined(separator: ":"))="
                    + (0..<2).map { String(quote.rankReservedBytes(rank: $0, shares: entry.shares) ?? -1) }.joined(separator: "/")
            }.joined(separator: " ")
            print("qwen-tp-load-quote-bytes lanes=\(lanes) depth=\(depth) prompt=\(prompt) output=\(output) chunk=\(chunk)"
                + " per_lane=\(quote.perLaneStateBytes) shared=\(quote.sharedBytesExcludingCollectives)"
                + " collective_scratch=\(quote.allowance.collectiveScratchBytes) whole_reserved=\(quote.allowance.reservedBytes)"
                + " assistant_resident=\(quote.assistant?.residentBytes ?? 0) assistant_load=\(quote.assistant?.loadBytes ?? 0)"
                + " rank_reserved \(reserved)")
        }
    }
}
