import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Opt-in local timing of ONE request's speculative rounds on owners of
/// different capacity, on ONE Mac with a real dense Qwen TP shard, its real
/// assistant and no peer (`QwenTensorParallelLocalReduction`: outputs are not
/// a tensor-parallel result). Everything but the host's lane count is the
/// same, encoded as the native executor encodes a decode round, so a phase
/// that grows with capacity is work sized by capacity rather than by rows.
/// QWEN_TP_CAPACITY_BENCH_MODEL=<model dir with mtp-*.safetensors>
/// [QWEN_TP_CAPACITY_BENCH_LANES=1,2,4] [QWEN_TP_CAPACITY_BENCH_CONTEXT=65536]
/// [QWEN_TP_CAPACITY_BENCH_PROMPT=1024] [QWEN_TP_CAPACITY_BENCH_ROUNDS=24]
/// [QWEN_TP_CAPACITY_BENCH_DEPTH=3] [QWEN_TP_CAPACITY_BENCH_RANK=1]
@Suite(.serialized)
struct QwenTensorParallelOwnerCapacityBenchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_CAPACITY_BENCH_MODEL"] != nil))
    func oneRowRoundPhasesByOwnerCapacity() throws {
        let environment = ProcessInfo.processInfo.environment
        func ints(_ name: String, _ fallback: [Int]) -> [Int] {
            let parsed = (environment[name] ?? "").split(separator: ",").compactMap { Int($0) }
            return parsed.isEmpty ? fallback : parsed
        }
        let directory = URL(fileURLWithPath: environment["QWEN_TP_CAPACITY_BENCH_MODEL"]!, isDirectory: true)
        let lanesList = ints("QWEN_TP_CAPACITY_BENCH_LANES", [1, 2, 4])
        let context = ints("QWEN_TP_CAPACITY_BENCH_CONTEXT", [65536])[0]
        let prompt = ints("QWEN_TP_CAPACITY_BENCH_PROMPT", [1024])[0]
        let rounds = ints("QWEN_TP_CAPACITY_BENCH_ROUNDS", [24])[0]
        let depth = ints("QWEN_TP_CAPACITY_BENCH_DEPTH", [3])[0], rank = ints("QWEN_TP_CAPACITY_BENCH_RANK", [1])[0]
        try Device.withDefaultDevice(.gpu) {
            let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            let reduction = QwenTensorParallelLocalReduction(rank: rank, size: 2)
            let model = try QwenTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank, size: 2),
                reduction: reduction, shares: [1, 1])
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
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-capacity-bench",
                vocabularySize: model.plan.vocabularySize, hiddenSize: model.plan.hiddenSize, activationDType: "bfloat16",
                maximumPromptTokens: min(context - 1, 32768), maximumChunkTokens: 512,
                maximumOutputTokens: context - min(context - 1, 32768), maximumContextTokens: context)
            print("qwen-tp-capacity-bench rank=\(rank) depth=\(depth) prompt=\(prompt) context=\(context)"
                + " fast_synch=\(environment["MLX_METAL_FAST_SYNCH"] ?? "unset") gpu=\(GPU.deviceInfo().architecture)")
            func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
            let names = ["draft", "build", "verify", "gather", "choose", "settle"]
            var pooled: [Int: [String: [Double]]] = [:]
            // Each capacity twice, in mirrored order (A B C C B A), so GPU drift
            // over the run cancels instead of reading as capacity.
            for pass in 0..<2 {
                for lanes in pass % 2 == 0 ? lanesList : Array(lanesList.reversed()) {
                    let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: lanes,
                        maximumTokensPerRequest: context, maximumChunkTokens: 512)
                    let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                        promptTokenIDs: (0..<prompt).map { ($0 * 131 + 11) % 150_000 },
                        chunkSize: 512, outputCount: 4096, stopTokenIDs: [])
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
                    let pagedCaches = host.caches.compactMap { $0 as? PagedLayerCache }
                    let multiQueryBefore = pagedCaches.reduce(0) { $0 + $1.mtpMultiQueryCalls }
                    let batchedBefore = pagedCaches.reduce(0) { $0 + $1.mtpBatchedAttentionCalls }
                    var phases: [String: [Double]] = [:], last = first, emitted = 0
                    for round in 0..<rounds {
                        let remaining = 4096 - decoder.statistics.emittedTokens - 1
                        let result = try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) {
                            try decoder.step(lastToken: last, remaining: remaining, check: {})
                        }
                        last = result.tokens.last!; emitted += result.tokens.count
                        guard round >= 2, let profile = decoder.lastProfile else { continue }
                        for (name, value) in [("draft", profile.draft), ("build", profile.build), ("verify", profile.verify),
                                              ("gather", profile.gather), ("choose", profile.choose), ("settle", profile.settle)] {
                            phases[name, default: []].append(Double(value) / 1e6)
                        }
                    }
                    for name in names { pooled[lanes, default: [:]][name, default: []] += phases[name] ?? [] }
                    let total = names.reduce(0) { $0 + median(phases[$1] ?? []) }
                    let multiQuery = pagedCaches.reduce(0) { $0 + $1.mtpMultiQueryCalls } - multiQueryBefore
                    let batched = pagedCaches.reduce(0) { $0 + $1.mtpBatchedAttentionCalls } - batchedBefore
                    print("qwen-tp-capacity-bench pass=\(pass) lanes=\(lanes) "
                        + names.map { "\($0)_ms=\(String(format: "%.2f", median(phases[$0] ?? [])))" }.joined(separator: " ")
                        + " round_ms=\(String(format: "%.2f", total)) emitted=\(emitted) rounds=\(rounds)"
                        + " multi_query_calls=\(multiQuery) batched_attention_calls=\(batched)"
                        + " host_capacity_bytes=\(host.capacityBytes)")
                    try decoder.retire()
                    #expect(host.isDrained)
                    Stream.gpu.synchronize(); Memory.clearCache()
                }
            }
            for lanes in lanesList {
                let phases = pooled[lanes] ?? [:]
                let total = names.reduce(0) { $0 + median(phases[$1] ?? []) }
                print("qwen-tp-capacity-bench pooled lanes=\(lanes) samples=\((phases["verify"] ?? []).count) "
                    + names.map { "\($0)_ms=\(String(format: "%.2f", median(phases[$0] ?? [])))" }.joined(separator: " ")
                    + " round_ms=\(String(format: "%.2f", total))")
            }
        }
    }
}
