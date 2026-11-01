import Cmlx
import DarkbloomClusterProtocol
import Foundation
import MLX
@testable import MLXLLM
@testable import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Opt-in local profile of a Qwen tensor-parallel decode step on ONE Mac with
/// one real rank shard and no peer: the outputs are not a tensor-parallel
/// result. Each step is timed three ways, so a rank's own compute can be told
/// apart from the bubbles its collectives cause on the pair:
/// - `local`: every all-sum is the rank's partial itself (pure GPU work, one
///   evaluation per token);
/// - `cpu-hop`: every all-sum crosses to the CPU stream and back unchanged, as
///   the sealed all-sum is scheduled (one GPU drain and refill per collective,
///   no network);
/// - `eval-each`: every partial is evaluated and the GPU synchronized before
///   its collective (the `explicit` timing).
/// A step is split into its graph build, its encoding (`asyncEval` returns once
/// every kernel is encoded) and the wait for the GPU, under each command-buffer
/// operation limit (the worker's guard is 16). `legacy` repeats `cpu-hop` with
/// the retired single-lane loop's pipelining (the next step built and submitted
/// before the token is read). Then, for a routed-expert row, one sparse block
/// alone and its parts (router, shared expert, routed experts), and the step
/// graph's primitive counts. Widths 1...4 then repeat `local` and `cpu-hop` on
/// the request-owned batch path at each layer-submission stride
/// (`QwenTensorParallelBatchSession.layerStride`; 0: one evaluation a step),
/// and the same rows decoded both ways must give the same logits bytes.
/// QWEN_TP_MOE_BENCH_MODEL=<model dir> [QWEN_TP_MOE_BENCH_RANK=0]
/// [QWEN_TP_MOE_BENCH_PROMPT=1024] [QWEN_TP_MOE_BENCH_STEPS=24]
/// [QWEN_TP_MOE_BENCH_OPS=16,100] [QWEN_TP_MOE_BENCH_STRIDES=0,1,2,4]
/// [QWEN_TP_MOE_BENCH_WIDTHS=1,2,4] [QWEN_TP_MOE_BENCH_MODES=local,cpu-hop] [QWEN_TP_MOE_BENCH_PARTS=1]
/// [QWEN_TP_MOE_BENCH_TRACE=1] [QWEN_TP_MOE_BENCH_LOG=<progress file>]
@Suite(.serialized)
struct QwenTensorParallelMoEDecodeBenchTests {
    enum Mode: String { case local, cpuHop = "cpu-hop", evalEach = "eval-each" }

    /// A rank with no peer whose collective is scheduled as `mode` says.
    final class Switchable: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2
        var mode = Mode.local
        /// Reports each evaluated collective (`QWEN_TP_MOE_BENCH_TRACE=1`): where a step stops.
        var trace = false
        var report: ((String) -> Void)?
        private(set) var collectives = 0
        init(rank: Int) { self.rank = rank }
        func allSum(_ value: MLXArray) -> MLXArray {
            collectives += 1
            switch mode {
            case .local: return value
            case .cpuHop: return MLX.multiply(value, MLXArray(1).asType(value.dtype), stream: .cpu)
            case .evalEach:
                eval(value); Stream.gpu.synchronize()
                if trace { report?("qwen-tp-moe-bench trace collective=\(collectives)") }
                return value
            }
        }
        func reset() { collectives = 0 }
    }

    private static func median(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.sorted()[values.count / 2] }
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to - from) / 1e6 }
    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }
    private static func list(_ environment: [String: String], _ name: String, _ fallback: [Int]) -> [Int] {
        let parsed = (environment[name] ?? "").split(separator: ",").compactMap { Int($0) }
        return parsed.isEmpty ? fallback : parsed
    }

    /// One decode step's graph after `prompt`, counted by primitive name (MLX's
    /// own printout, as `QwenTensorParallelModel.decodeStepCensus` counts it).
    private static func census(_ model: QwenTensorParallelModel, prompt: [Int]) throws -> [String: Int] {
        let cache = try model.newCache()
        let first = model.select(model.prefill(prompt, chunk: prompt.count, cache: cache))
        eval([first] + cache.flatMap { $0.innerState() })
        let next = model.select(model.step(first, cache: cache))
        guard let file = tmpfile() else { throw ProbeError("census: no temporary file") }
        defer { fclose(file) }
        let namer = mlx_node_namer_new()
        defer { mlx_node_namer_free(namer) }
        let outputs = mlx_vector_array_new()
        defer { mlx_vector_array_free(outputs) }
        mlx_vector_array_append_value(outputs, next.ctx)
        guard mlx_print_graph(file, namer, outputs) == 0 else { throw ProbeError("census: graph printout failed") }
        fflush(file); rewind(file)
        var counts: [String: Int] = [:]
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(line) }
        while getline(&line, &capacity, file) > 0, let line {
            let text = String(cString: line)
            guard let name = text.split(separator: " ", maxSplits: 1).first, !name.isEmpty,
                  text.contains(" -> ") else { continue }
            counts[String(name), default: 0] += 1
        }
        eval(next)
        return counts
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MOE_BENCH_MODEL"] != nil))
    func routedExpertDecodeStepProfile() throws {
        let environment = ProcessInfo.processInfo.environment
        // Each line also goes straight to `QWEN_TP_MOE_BENCH_LOG` (the test
        // runner holds a test's output until it ends): where a run stopped.
        let progress: FileHandle? = environment["QWEN_TP_MOE_BENCH_LOG"].flatMap { path in
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        func report(_ line: String) {
            print(line)
            if let progress { progress.write(Data((line + "\n").utf8)); try? progress.synchronize() }
        }
        let directory = URL(fileURLWithPath: environment["QWEN_TP_MOE_BENCH_MODEL"]!, isDirectory: true)
        let rank = Int(environment["QWEN_TP_MOE_BENCH_RANK"] ?? "0") ?? 0
        let promptCount = Int(environment["QWEN_TP_MOE_BENCH_PROMPT"] ?? "1024") ?? 1024
        let steps = Int(environment["QWEN_TP_MOE_BENCH_STEPS"] ?? "24") ?? 24
        let opsLimits = Self.list(environment, "QWEN_TP_MOE_BENCH_OPS", [16, 100])
        let strides = Self.list(environment, "QWEN_TP_MOE_BENCH_STRIDES", [0, 1, 2, 4])
        let widths = Self.list(environment, "QWEN_TP_MOE_BENCH_WIDTHS", [1, 2, 4])
        let parts = environment["QWEN_TP_MOE_BENCH_PARTS"] != "0"
        let modes = (environment["QWEN_TP_MOE_BENCH_MODES"] ?? "local,cpu-hop").split(separator: ",")
            .compactMap { Mode(rawValue: String($0)) }
        let label = "qwen-tp-moe-bench \(directory.lastPathComponent) rank=\(rank)"
        try Device.withDefaultDevice(.gpu) {
            let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            let reduction = Switchable(rank: rank)
            reduction.report = { report($0) }
            let model = try QwenTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank, size: 2),
                reduction: reduction)
            let prompt = (0..<promptCount).map { ($0 * 7919 + 13) % 150_000 }
            report("\(label) plan=\(model.plan.name) layers=\(model.plan.layerCount)"
                + " reductions_per_forward=\(model.plan.reductionsPerForward) prompt=\(promptCount)"
                + " fast_synch=\(environment["MLX_METAL_FAST_SYNCH"] ?? "unset")"
                + " env_ops=\(environment["MLX_MAX_OPS_PER_BUFFER"] ?? "unset")"
                + " active_bytes=\(Memory.activeMemory)")

            // 1. The single-request decode step (the request-local caches).
            for ops in opsLimits {
                try GPU.withCommandBufferLimits(.init(operations: ops, megabytes: 1 << 20)) {
                    for mode in [Mode.local, .cpuHop, .evalEach] {
                        reduction.mode = mode
                        let cache = try model.newCache()
                        var token = model.select(model.prefill(prompt, chunk: 512, cache: cache))
                        eval([token] + cache.flatMap { $0.innerState() })
                        var build: [Double] = [], encode: [Double] = [], wait: [Double] = [], step: [Double] = []
                        var collectives = 0
                        for index in 0..<steps {
                            reduction.reset()
                            let started = Self.now()
                            let next = model.select(model.step(token, cache: cache))
                            let built = Self.now()
                            asyncEval(next)
                            let encoded = Self.now()
                            eval(next)
                            let done = Self.now()
                            token = next
                            if index >= 4 {
                                build.append(Self.ms(started, built)); encode.append(Self.ms(built, encoded))
                                wait.append(Self.ms(encoded, done)); step.append(Self.ms(started, done))
                                collectives = reduction.collectives
                            }
                        }
                        report("\(label) path=request-cache ops=\(ops) mode=\(mode.rawValue)"
                            + " build_ms=\(Self.format(Self.median(build))) encode_ms=\(Self.format(Self.median(encode)))"
                            + " wait_ms=\(Self.format(Self.median(wait))) step_ms=\(Self.format(Self.median(step)))"
                            + " collectives=\(collectives)")
                    }
                    // The retired single-lane loop: greedy steps built one ahead.
                    reduction.mode = .cpuHop
                    let cache = try model.newCache()
                    var current = model.select(model.prefill(prompt, chunk: 512, cache: cache))
                    asyncEval(current)
                    var samples: [Double] = []
                    var last = Self.now()
                    for index in 0..<steps {
                        let next = model.select(model.step(current, cache: cache))
                        asyncEval(next)
                        _ = current.item(Int32.self)
                        let now = Self.now()
                        if index >= 4 { samples.append(Self.ms(last, now)) }
                        last = now
                        current = next
                    }
                    eval(current)
                    report("\(label) path=request-cache ops=\(ops) mode=legacy-pipelined token_ms=\(Self.format(Self.median(samples)))")
                }
            }
            reduction.mode = .local

            // 2. One sparse block alone, and its parts (a dense row skips them).
            let modules = Dictionary(uniqueKeysWithValues: model.model.namedModules())
            if parts, let block = modules["language_model.model.layers.0.mlp"] as? Qwen35SparseMoeBlock {
                let x = (MLXRandom.normal([1, 1, model.plan.hiddenSize]) * 0.5).asType(.bfloat16)
                eval(x)
                func time(_ name: String, repeats: Int = 64, _ body: () -> [MLXArray]) {
                    eval(body())
                    var samples: [Double] = []
                    for _ in 0..<5 {
                        let started = Self.now()
                        for _ in 0..<repeats { eval(body()) }
                        samples.append(Self.ms(started, Self.now()) * 1000 / Double(repeats))
                    }
                    report("\(label) part=\(name) us_per_call=\(Self.format(Self.median(samples)))")
                }
                func batched(_ name: String, repeats: Int = 16, _ body: () -> MLXArray) {
                    // Many independent calls in one evaluation: the GPU time alone.
                    eval(body())
                    var samples: [Double] = []
                    for _ in 0..<5 {
                        let outputs = (0..<repeats).map { _ in body() }
                        let started = Self.now()
                        eval(outputs)
                        samples.append(Self.ms(started, Self.now()) * 1000 / Double(repeats))
                    }
                    report("\(label) part=\(name)-in-one-eval us_per_call=\(Self.format(Self.median(samples)))")
                }
                time("sparse-block") { [block(x)] }
                batched("sparse-block") { block(x) }
                let gates = MLX.softmax(block.gate(x), axis: -1, precise: true)
                eval(gates)
                time("router-gate-softmax") { [MLX.softmax(block.gate(x), axis: -1, precise: true)] }
                let kth = gates.dim(-1) - model.plan.expertsPerToken
                let ids = argPartition(gates, kth: kth, axis: -1)[.ellipsis, kth...]
                eval(ids)
                time("router-top-k") {
                    let chosen = argPartition(gates, kth: kth, axis: -1)[.ellipsis, kth...]
                    let scores = takeAlong(gates, chosen, axis: -1)
                    return [chosen, scores / scores.sum(axis: -1, keepDims: true)]
                }
                let shared = block.sharedExpert
                time("shared-expert-gate-up") { [silu(shared.gateProj(x)) * shared.upProj(x)] }
                let hidden = silu(shared.gateProj(x)) * shared.upProj(x)
                eval(hidden)
                if let down = shared.downProj as? any Qwen35TensorParallelPackedPartial {
                    time("shared-expert-down-partial-f32") { [down.qwen35TensorParallelPartial(hidden)] }
                }
                let flatX = x.reshaped([-1, x.dim(-1)])
                let flatIDs = ids.reshaped([-1, ids.dim(-1)]).asType(.uint32)
                eval(flatX, flatIDs)
                time("routed-experts-switch-glu") { [block.switchMLP(flatX, flatIDs)] }
                batched("routed-experts-switch-glu") { block.switchMLP(flatX, flatIDs) }
                if let down = block.switchMLP.downProjection as? QuantizedSwitchLinear {
                    let width = down.shape.inputDims
                    let activated = (MLXRandom.normal([1, model.plan.expertsPerToken, 1, width]) * 0.1).asType(.bfloat16)
                    let routes = flatIDs.reshaped([1, model.plan.expertsPerToken])
                    let expanded = MLX.expandedDimensions(flatX, axes: [-2, -3])
                    // The FP32 call's affine constants, cast once as the layer's cast cache keeps them.
                    let scales32 = down.scales.asType(.float32), biases32 = down.biases?.asType(.float32)
                    eval([activated, routes, expanded, scales32] + (biases32.map { [$0] } ?? []))
                    time("routed-down-gather-qmm-f32-input") {
                        [gatherQuantizedMM(activated.asType(.float32), down.weight, scales: scales32, biases: biases32,
                            rhsIndices: routes, transpose: true, groupSize: down.groupSize, bits: down.bits, mode: down.mode)]
                    }
                    time("routed-down-gather-qmm-bf16-input") {
                        [gatherQuantizedMM(activated, down.weight, scales: down.scales, biases: down.biases,
                            rhsIndices: routes, transpose: true, groupSize: down.groupSize, bits: down.bits, mode: down.mode)]
                    }
                    if let gateUp = block.switchMLP.gateUpProj as? QuantizedSwitchLinear {
                        time("routed-gate-up-gather-qmm") {
                            [gatherQuantizedMM(expanded, gateUp.weight, scales: gateUp.scales, biases: gateUp.biases,
                                rhsIndices: routes, transpose: true, groupSize: gateUp.groupSize, bits: gateUp.bits,
                                mode: gateUp.mode)]
                        }
                    }
                }
            }

            // 3. The step graph's primitives (kernel launches, minus views).
            let census = try Self.census(model, prompt: Array(prompt.prefix(64)))
            let total = census.values.reduce(0, +)
            report("\(label) census total=\(total) "
                + census.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: " "))

            // 4. The request-owned batch path at each width, limit and stride.
            let perCombination = max(6, steps / 2)
            let budget = promptCount + opsLimits.count * strides.count * 2 * perCombination + 64
            let chunk = min(512, promptCount)
            let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: max(widths.max() ?? 1, 4),
                maximumTokensPerRequest: budget, maximumChunkTokens: chunk)
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-moe-bench",
                vocabularySize: model.plan.vocabularySize, hiddenSize: model.plan.hiddenSize, activationDType: "bfloat16",
                maximumPromptTokens: promptCount, maximumChunkTokens: chunk, maximumOutputTokens: budget - promptCount,
                maximumContextTokens: budget)
            let traced = environment["QWEN_TP_MOE_BENCH_TRACE"] == "1"
            for width in widths {
                var sessions: [QwenTensorParallelBatchSession] = []
                do {
                    for row in 0..<width {
                        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                            promptTokenIDs: prompt.map { ($0 + row * 17) % 150_000 },
                            chunkSize: chunk, outputCount: budget - promptCount, stopTokenIDs: [])
                        let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                            host: host, request: request)
                        sessions.append(session)
                        while session.schedule.committedPromptTokens < request.promptCount { _ = try session.prefill(check: {}) }
                    }
                } catch {
                    report("\(label) path=batch width=\(width) unavailable: \(error)")
                    for session in sessions { try? session.retire() }
                    break
                }
                var step = 0
                if traced {
                    // One step evaluated collective by collective, each printed.
                    reduction.mode = .evalEach; reduction.trace = true
                    report("\(label) path=batch width=\(width) trace-begin")
                    _ = try QwenTensorParallelBatchSession.$layerStride.withValue(0) {
                        eval(try QwenTensorParallelBatchSession.decode(sessions,
                            tokens: (0..<width).map { ($0 * 31 + 5) % 150_000 }, check: {}))
                    }
                    step += 1; reduction.trace = false
                    report("\(label) path=batch width=\(width) trace-end")
                }
                for ops in opsLimits {
                    for stride in strides {
                        for mode in modes {
                            reduction.mode = mode
                            report("\(label) path=batch width=\(width) ops=\(ops) stride=\(stride) mode=\(mode.rawValue) begin")
                            var samples: [Double] = [], collectives = 0
                            try GPU.withCommandBufferLimits(.init(operations: ops, megabytes: 1 << 20)) {
                                try QwenTensorParallelBatchSession.$layerStride.withValue(stride) {
                                    for index in 0..<perCombination {
                                        reduction.reset()
                                        let tokens = (0..<width).map { ($0 * 31 + step * 7 + 5) % 150_000 }
                                        step += 1
                                        let started = Self.now()
                                        let logits = try QwenTensorParallelBatchSession.decode(sessions, tokens: tokens, check: {})
                                        eval(logits)
                                        if index >= 2 { samples.append(Self.ms(started, Self.now())); collectives = reduction.collectives }
                                    }
                                }
                            }
                            report("\(label) path=batch width=\(width) ops=\(ops) stride=\(stride) mode=\(mode.rawValue)"
                                + " step_ms=\(Self.format(Self.median(samples))) collectives=\(collectives)")
                        }
                    }
                }
                reduction.mode = .local
                for session in sessions { try session.retire() }
            }

            // 5. Submission parity: the same rows decoded with each step evaluated
            // at once and submitted layer by layer, every collective on the CPU
            // stream (as the sealed all-sum runs), give the same logits bytes.
            reduction.mode = .cpuHop
            var pairs: [[QwenTensorParallelBatchSession]] = [[], []]
            defer { for session in pairs.flatMap({ $0 }) { try? session.retire() } }
            for row in 0..<2 {
                let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                    promptTokenIDs: Array(prompt.prefix(min(promptCount, 96 + 32 * row))), chunkSize: chunk, outputCount: 16, stopTokenIDs: [])
                for side in 0..<2 {
                    let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                        host: host, request: request)
                    pairs[side].append(session)
                    while session.schedule.committedPromptTokens < request.promptCount { _ = try session.prefill(check: {}) }
                }
            }
            var equal = true
            for step in 0..<6 {
                let rows = step % 2 == 0 ? [0, 1] : [1]
                let tokens = rows.map { ($0 * 31 + step * 7 + 5) % 150_000 }
                func decoded(_ side: Int, stride: Int) throws -> Data {
                    try QwenTensorParallelBatchSession.$layerStride.withValue(stride) {
                        let logits = try QwenTensorParallelBatchSession.decode(rows.map { pairs[side][$0] }, tokens: tokens, check: {})
                        eval(logits)
                        return logits.asType(.float32).asData(access: .copy).data
                    }
                }
                equal = try decoded(0, stride: 0) == decoded(1, stride: QwenTensorParallelBatchSession.decodeLayerStride) && equal
            }
            reduction.mode = .local
            report("\(label) submission-parity stride=\(QwenTensorParallelBatchSession.decodeLayerStride) equal=\(equal)")
            #expect(equal, "a decode submitted layer by layer keeps the whole step's logits")
        }
    }
}
