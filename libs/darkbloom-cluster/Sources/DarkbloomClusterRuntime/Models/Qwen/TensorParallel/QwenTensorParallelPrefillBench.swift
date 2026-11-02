import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Opt-in measurement of one Qwen tensor-parallel rank's prompt prefill on
/// ONE Mac with no peer: one real rank shard (its weighted share), the
/// product's request-owned prefill (`QwenTensorParallelBatchSession` over a
/// paged `CBv2StageKVHost`, frames on the request's chunk grid), and every
/// all-sum scheduled as `Mode` says. Outputs are not a tensor-parallel result
/// (a shard's partials are never summed with a peer's); the bench times what
/// each rank's own GPU spends, so a pair's prefill can be split into the
/// slower rank's compute, the collectives and the rest. Never a serving path.
///
/// Per configuration (chunk size x command-buffer operation limit x prefill
/// layer-submission stride x mode) it prefills the same prompt and reports
/// the time to the last frame's logits, each frame's graph construction and
/// evaluation, and a digest of the final logits: configurations that only
/// change scheduling (operations, stride, mode) must give the same bytes.
/// `layers` then times every decoder layer of the first and the last frame
/// (`Qwen35LayerSubmission.observer`: each layer evaluated as it is built),
/// and `gemm` every projection of one linear-attention layer, one
/// full-attention layer and their MLPs at the given row counts, the
/// row-parallel ones both as the rank computes them (FP32 input and partial)
/// and with BF16 input (another arithmetic: a speed reference only).
public enum QwenTensorParallelPrefillBench {
    public enum Mode: String, Sendable, CaseIterable {
        /// Every all-sum returns the rank's partial (pure GPU work).
        case local
        /// Every all-sum crosses to the CPU stream and back unchanged, as the
        /// sealed all-sum is scheduled (a GPU drain and refill per collective,
        /// no network).
        case cpuHop = "cpu-hop"
    }

    public struct Options: Sendable {
        public var modelDirectory: URL
        public var rank = 0
        /// Each rank's share weight (nil: equal shards).
        public var shares: [Int]?
        public var promptTokens = 4096
        public var chunks = [512]
        /// Command-buffer operation limits (0: the process's own, a worker's
        /// `MLX_MAX_OPS_PER_BUFFER` guard or MLX's per-chip value).
        public var operations = [0]
        /// Prefill layer-submission strides (`QwenTensorParallelBatchSession.prefillStride`; 0: one evaluation a frame).
        public var strides = [0]
        /// Frames a prompt step merges at most (`QwenTensorParallelPromptWavefront`; 1: one frame a step).
        public var wavefronts = [1]
        public var modes: [Mode] = [.local]
        /// Prefills of each configuration (the first is reported apart when more than one).
        public var repeats = 1
        public var layers = false
        public var gemm = false
        public var gemmRows = [512]
        public init(modelDirectory: URL) { self.modelDirectory = modelDirectory }
    }

    /// A rank with no peer whose collective is scheduled as `mode` says.
    final class Reduction: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2
        var mode = Mode.local
        private(set) var collectives = 0
        private(set) var collectiveBytes = 0
        init(rank: Int) { self.rank = rank }
        func allSum(_ value: MLXArray) -> MLXArray {
            collectives += 1; collectiveBytes += value.nbytes
            switch mode {
            case .local: return value
            case .cpuHop: return MLX.multiply(value, MLXArray(1).asType(value.dtype), stream: .cpu)
            }
        }
        func reset() { collectives = 0; collectiveBytes = 0 }
    }

    /// Thread-confined recorder handed to the `@Sendable` observers below
    /// (they run synchronously on the thread that builds the forward).
    final class Recorder: @unchecked Sendable {
        var marks: [(String, UInt64)] = []
        var layerTimes: [(Int, Double)] = []
        var last: UInt64 = 0
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        func span(_ begin: String, _ end: String) -> Double {
            guard let b = marks.first(where: { $0.0 == begin })?.1, let e = marks.first(where: { $0.0 == end })?.1, e >= b
            else { return .nan }
            return Double(e - b) / 1e6
        }
    }

    static func ms(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1e6 }
    static func format(_ value: Double) -> String { String(format: "%.2f", value) }
    static func median(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.sorted()[values.count / 2] }

    /// A fixed pseudo-random prompt (the same on every Mac and run).
    static func prompt(_ count: Int, vocabulary: Int) -> [Int] {
        (0 ..< count).map { ($0 * 7919 + 13) % min(vocabulary, 150_000) }
    }

    struct FrameTiming {
        var wall: Double
        var build: Double
        var evaluation: Double
        var other: Double
    }

    public static func run(_ options: Options, log: @escaping (String) -> Void) throws {
        let configuration = try Data(contentsOf: options.modelDirectory.appendingPathComponent("config.json"))
        let reduction = Reduction(rank: options.rank)
        let model = try QwenTensorParallelModel.load(modelDirectory: options.modelDirectory,
            role: .shard(rank: options.rank, size: 2), reduction: reduction, shares: options.shares)
        let label = "qwen-tp-prefill-bench \(options.modelDirectory.lastPathComponent) rank=\(options.rank)"
            + " shares=\(model.plan.shares.map(String.init).joined(separator: ":"))"
        let environment = ProcessInfo.processInfo.environment
        log("\(label) plan=\(model.plan.name) layers=\(model.plan.layerCount) prompt=\(options.promptTokens)"
            + " gpu=\(GPU.deviceInfo().architecture) env_ops=\(environment["MLX_MAX_OPS_PER_BUFFER"] ?? "unset")"
            + " tf32=\(environment["MLX_ENABLE_TF32"] ?? "unset") fast_synch=\(environment["MLX_METAL_FAST_SYNCH"] ?? "unset")"
            + " load_s=\(format(model.loadSeconds)) active_gb=\(String(format: "%.2f", Double(Memory.activeMemory) / 1e9))")
        let tokens = prompt(options.promptTokens, vocabulary: model.plan.vocabularySize)

        /// One whole prompt prefilled on a fresh request: per step timings and the final logits' digest.
        func prefill(chunk: Int, wavefront: Int = 1, observeLayers: ((Int) -> Bool)? = nil)
            throws -> (frames: [FrameTiming], digest: String, layerRows: [(frame: Int, offset: Int, times: [(Int, Double)])]) {
            let budget = options.promptTokens + 8
            let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
                maximumTokensPerRequest: budget, maximumChunkTokens: chunk)
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-prefill-bench",
                vocabularySize: model.plan.vocabularySize, hiddenSize: model.plan.hiddenSize, activationDType: "bfloat16",
                maximumPromptTokens: options.promptTokens, maximumChunkTokens: chunk,
                maximumOutputTokens: budget - options.promptTokens, maximumContextTokens: budget)
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: tokens, chunkSize: chunk, outputCount: budget - options.promptTokens, stopTokenIDs: [])
            let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                host: host, request: request)
            defer { try? session.retire() }
            var frames: [FrameTiming] = []
            var digest = ""
            var layerRows: [(frame: Int, offset: Int, times: [(Int, Double)])] = []
            var index = 0
            while session.schedule.committedPromptTokens < request.promptCount {
                let offset = session.schedule.committedPromptTokens
                let phases = Recorder()
                let layerRecorder = Recorder()
                let observing = observeLayers?(index) ?? false
                let started = phases.now()
                let logits = try QwenTensorParallelBatchSession.$prefillPhases.withValue({ observation in
                    phases.marks.append((observation.phase.rawValue, phases.now()))
                }) { () throws -> MLXArray? in
                    if observing {
                        layerRecorder.last = layerRecorder.now()
                        return try Qwen35LayerSubmission.$observer.withValue({ layer, hidden in
                            eval(hidden)
                            let now = layerRecorder.now()
                            layerRecorder.layerTimes.append((layer, ms(now - layerRecorder.last)))
                            layerRecorder.last = now
                        }) { try session.prefill(check: {}) }
                    }
                    guard wavefront > 1,
                          let step = QwenTensorParallelPromptWavefront.step(session.promptFrames(limit: wavefront)) else {
                        return try session.prefill(check: {})
                    }
                    return try session.prefill(step: step, check: {})
                }
                let ended = phases.now()
                let build = phases.span("graphConstruction.begin", "graphConstruction.end")
                let evaluation = phases.span("evaluation.begin", "evaluation.end")
                let wall = ms(ended - started)
                frames.append(.init(wall: wall, build: build, evaluation: evaluation,
                    other: wall - (build.isNaN ? 0 : build) - (evaluation.isNaN ? 0 : evaluation)))
                if observing { layerRows.append((index, offset, layerRecorder.layerTimes)) }
                if let logits {
                    eval(logits)
                    let data = logits.asType(.float32).asData(access: .copy).data
                    digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
                }
                index += 1
            }
            return (frames, digest, layerRows)
        }

        // Warm-up: one short prompt through every chunk size (kernel and
        // pipeline creation), not reported.
        do {
            let saved = reduction.mode
            reduction.mode = .local
            for chunk in Set(options.chunks).sorted() {
                try prefillWarmup(model: model, configuration: configuration, chunk: min(chunk, options.promptTokens))
            }
            reduction.mode = saved
            Memory.clearCache()
        }

        // 1. The product prefill at every configuration.
        var digests: [Int: Set<String>] = [:]
        for chunk in options.chunks {
            for operations in options.operations {
                for (stride, wavefront) in options.strides.flatMap({ s in options.wavefronts.map { (s, $0) } }) {
                    for mode in options.modes {
                        reduction.mode = mode
                        for repeatIndex in 0 ..< max(1, options.repeats) {
                            reduction.reset()
                            let run = {
                                try QwenTensorParallelBatchSession.$prefillStride.withValue(stride) {
                                    try prefill(chunk: chunk, wavefront: wavefront)
                                }
                            }
                            let result = try (operations > 0
                                ? GPU.withCommandBufferLimits(.init(operations: operations, megabytes: 1 << 20), run)
                                : run())
                            let frames = result.frames
                            let total = frames.reduce(0) { $0 + $1.wall }
                            digests[chunk, default: []].insert(result.digest)
                            let middle = frames.count > 2 ? Array(frames.dropFirst().dropLast()) : frames
                            log("\(label) path=prefill chunk=\(chunk) ops=\(operations == 0 ? "process" : String(operations))"
                                + " stride=\(stride) wavefront=\(wavefront) mode=\(mode.rawValue) repeat=\(repeatIndex)"
                                + " total_ms=\(format(total)) tok_s=\(format(Double(options.promptTokens) / total * 1000))"
                                + " frames=\(frames.count)"
                                + " first_ms=\(format(frames.first?.wall ?? .nan)) last_ms=\(format(frames.last?.wall ?? .nan))"
                                + " mid_median_ms=\(format(median(middle.map(\.wall))))"
                                + " build_median_ms=\(format(median(frames.map(\.build))))"
                                + " eval_median_ms=\(format(median(frames.map(\.evaluation))))"
                                + " other_median_ms=\(format(median(frames.map(\.other))))"
                                + " collectives=\(reduction.collectives) collective_mb=\(format(Double(reduction.collectiveBytes) / 1e6))"
                                + " digest=\(result.digest)")
                            let curve = frames.enumerated().filter { $0.offset % max(1, frames.count / 8) == 0 || $0.offset == frames.count - 1 }
                                .map { "\($0.offset * chunk):\(format($0.element.wall))" }.joined(separator: ",")
                            log("\(label) path=prefill-curve chunk=\(chunk) ops=\(operations == 0 ? "process" : String(operations)) stride=\(stride) wavefront=\(wavefront) mode=\(mode.rawValue) offset_ms=\(curve)")
                        }
                        Memory.clearCache()
                    }
                }
            }
        }
        for (chunk, set) in digests.sorted(by: { $0.key < $1.key }) {
            log("\(label) digest-check chunk=\(chunk) distinct=\(set.count) \(set.count == 1 ? "same-bytes" : "DIFFERENT")")
        }

        // 2. Every layer of the first and the last frame, evaluated as built.
        if options.layers {
            reduction.mode = .local
            for chunk in options.chunks {
                let frameCount = (options.promptTokens + chunk - 1) / chunk
                let result = try QwenTensorParallelBatchSession.$prefillStride.withValue(0) {
                    try prefill(chunk: chunk, observeLayers: { $0 == 0 || $0 == frameCount - 1 })
                }
                for row in result.layerRows {
                    let linear = row.times.filter { !isFullAttention(model: model, layer: $0.0) }.map(\.1)
                    let full = row.times.filter { isFullAttention(model: model, layer: $0.0) }.map(\.1)
                    log("\(label) path=layers chunk=\(chunk) frame=\(row.frame) offset=\(row.offset)"
                        + " linear_n=\(linear.count) linear_sum_ms=\(format(linear.reduce(0, +))) linear_median_ms=\(format(median(linear)))"
                        + " full_n=\(full.count) full_sum_ms=\(format(full.reduce(0, +))) full_median_ms=\(format(median(full)))"
                        + " all_sum_ms=\(format(row.times.map(\.1).reduce(0, +)))")
                }
                Memory.clearCache()
            }
        }

        // 3. The projections at the given row counts.
        if options.gemm {
            reduction.mode = .local
            let modules = Dictionary(uniqueKeysWithValues: model.model.namedModules())
            let linearLayer = (0 ..< model.plan.layerCount).first { !isFullAttention(model: model, layer: $0) } ?? 0
            let fullLayer = (0 ..< model.plan.layerCount).first { isFullAttention(model: model, layer: $0) } ?? 3
            let prefix = "language_model.model.layers."
            let names = [
                "\(linearLayer).linear_attn.in_proj_qkv", "\(linearLayer).linear_attn.in_proj_z",
                "\(linearLayer).linear_attn.in_proj_b", "\(linearLayer).linear_attn.in_proj_a",
                "\(linearLayer).linear_attn.out_proj",
                "\(fullLayer).self_attn.q_proj", "\(fullLayer).self_attn.k_proj", "\(fullLayer).self_attn.v_proj",
                "\(fullLayer).self_attn.o_proj",
                "\(linearLayer).mlp.gate_proj", "\(linearLayer).mlp.up_proj", "\(linearLayer).mlp.down_proj",
            ]
            for rows in options.gemmRows {
                for name in names {
                    guard let linear = modules[prefix + name] as? QuantizedLinear else {
                        log("\(label) path=gemm rows=\(rows) \(name) unavailable"); continue
                    }
                    let (outputs, inputs) = linear.shape
                    let flops = 2.0 * Double(rows) * Double(outputs) * Double(inputs)
                    let x = (MLXRandom.normal([1, rows, inputs], key: MLXRandom.key(UInt64(rows * 131 + inputs))) * 0.5)
                        .asType(.bfloat16)
                    eval(x)
                    func time(_ body: () -> MLXArray) -> Double {
                        // Eight independent calls in one evaluation: the GPU's own time per call.
                        eval(body())
                        var samples: [Double] = []
                        for _ in 0 ..< 3 {
                            let outputs = (0 ..< 8).map { _ in body() }
                            let started = DispatchTime.now().uptimeNanoseconds
                            eval(outputs)
                            samples.append(ms(DispatchTime.now().uptimeNanoseconds - started) / 8)
                        }
                        return median(samples)
                    }
                    /// The output's bytes, digested: two processes (another MLX kernel tile,
                    /// `MLX_QMM_STEEL_TILE`) must print the same digest.
                    func digest(_ value: MLXArray) -> String {
                        eval(value)
                        return SHA256.hash(data: value.asData(access: .copy).data).prefix(8)
                            .map { String(format: "%02x", $0) }.joined()
                    }
                    /// The same product at each steel tile (`GPU.withQuantizedMatmulSteelTile`;
                    /// a NAX GPU takes its own kernel at every tile): the time per call at
                    /// each, and whether every tile gives the same bytes.
                    func tiles(_ body: () -> MLXArray) -> TileTimes {
                        var perCall: [Int: Double] = [:], digests = Set<String>(), first = ""
                        for code in TileTimes.codes {
                            perCall[code] = GPU.withQuantizedMatmulSteelTile(code) { time(body) }
                            let d = GPU.withQuantizedMatmulSteelTile(code) { digest(body()) }
                            if code == 32 { first = d }
                            digests.insert(d)
                        }
                        return TileTimes(ms: perCall, same: digests.count == 1, digest: first)
                    }
                    if let row = linear as? QwenTensorParallelRowLinear {
                        let asRank = tiles { row.qwen35TensorParallelPartial(x) }
                        let bf16 = tiles {
                            quantizedMM(x, row.weight, scales: row.scales, biases: row.biases, transpose: true,
                                groupSize: row.groupSize, bits: row.bits, mode: row.mode)
                        }
                        log("\(label) path=gemm rows=\(rows) \(name) kind=row-parallel n=\(outputs) k=\(inputs)"
                            + " f32_tiles_same=\(asRank.same) bf16_tiles_same=\(bf16.same) f32_digest=\(asRank.digest)"
                            + " f32_partial_ms \(asRank.text) f32_tflops=\(format(flops / asRank.best / 1e9))"
                            + " | bf16_input_ms \(bf16.text) bf16_tflops=\(format(flops / bf16.best / 1e9))")
                    } else {
                        let value = tiles { linear(x) }
                        log("\(label) path=gemm rows=\(rows) \(name) kind=column-parallel n=\(outputs) k=\(inputs)"
                            + " tiles_same=\(value.same) digest=\(value.digest)"
                            + " ms \(value.text) tflops=\(format(flops / value.best / 1e9))")
                    }
                }
                Memory.clearCache()
            }
        }
    }

    /// One product's time per call at each steel tile code (0: the process default, `MLX_QMM_STEEL_TILE`
    /// or MLX's own choice by input width), and whether every tile gave the same bytes.
    struct TileTimes {
        static let codes = [32, 0, 64, 6432, 3264, 6464]
        var ms: [Int: Double]
        var same: Bool
        var digest: String
        var text: String {
            Self.codes.map { "t\($0 == 0 ? "default" : String($0))=\(QwenTensorParallelPrefillBench.format(ms[$0] ?? .nan))" }
                .joined(separator: " ")
        }
        var best: Double { ms.values.min() ?? .nan }
    }

    /// A real pair's rank (`model`'s reduction is its group, for example the
    /// loopback ring with sealed sums): the same prompt prefilled one frame a
    /// step and in merged steps of up to each of `wavefronts` frames
    /// (`QwenTensorParallelPromptWavefront`). Logs each run's step times and
    /// the digests of its final logits, attention rows and recurrent states;
    /// returns whether every run left this rank the same digests.
    public static func pair(model: QwenTensorParallelModel, configuration: Data, promptTokens: Int, chunk: Int,
                            wavefronts: [Int], repeats: Int, log: (String) -> Void) throws -> Bool {
        guard case .shard(let rank, _) = model.role else { throw ProbeError("The wavefront pair runs a rank shard") }
        let tokens = prompt(promptTokens, vocabulary: model.plan.vocabularySize)
        let budget = promptTokens + 8
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-wavefront-pair",
            vocabularySize: model.plan.vocabularySize, hiddenSize: model.plan.hiddenSize, activationDType: "bfloat16",
            maximumPromptTokens: promptTokens, maximumChunkTokens: chunk, maximumOutputTokens: budget - promptTokens,
            maximumContextTokens: budget)
        func digest(_ arrays: [MLXArray]) -> String {
            var hash = SHA256()
            for array in arrays { eval(array); hash.update(data: array.asData(access: .copy).data) }
            return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        }
        var seen: (logits: String, rows: String, recurrent: String)?
        var same = true
        try prefillWarmup(model: model, configuration: configuration, chunk: min(chunk, promptTokens))
        for limit in wavefronts {
            for repeatIndex in 0 ..< max(1, repeats) {
                Memory.clearCache()
                let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
                    maximumTokensPerRequest: budget, maximumChunkTokens: chunk)
                let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                    promptTokenIDs: tokens, chunkSize: chunk, outputCount: budget - promptTokens, stopTokenIDs: [])
                let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                    host: host, request: request)
                defer { try? session.retire() }
                var steps: [(tokens: Int, ms: Double)] = []
                var logits: MLXArray?
                while session.schedule.committedPromptTokens < promptTokens {
                    let frames = session.promptFrames(limit: limit)
                    guard let step = QwenTensorParallelPromptWavefront.step(frames) else { throw ProbeError("No prompt step") }
                    let started = DispatchTime.now().uptimeNanoseconds
                    logits = try session.prefill(step: step, check: {}) ?? logits
                    if let logits { eval(logits) }
                    steps.append((step.tokenCount, ms(DispatchTime.now().uptimeNanoseconds - started)))
                }
                let total = steps.reduce(0) { $0 + $1.ms }
                let rows = session.state.rows.compactMap { $0?.snapshot() }.flatMap { [$0.keys, $0.values] }
                let committed = session.state.recurrent.confirmedStateSnapshot() ?? [:]
                let recurrent = committed.keys.sorted().flatMap { [committed[$0]!.conv!, committed[$0]!.ssm!] }
                let value = (digest([logits ?? MLXArray(0)]), digest(rows), digest(recurrent))
                if let seen { same = same && seen == value } else { seen = value }
                let perFrame = steps.map { $0.ms * Double(chunk) / Double($0.tokens) }
                log("qwen-tp-wavefront-v1 rank=\(rank) limit=\(limit) repeat=\(repeatIndex) tokens=\(promptTokens)"
                    + " steps=\(steps.count) total_ms=\(format(total)) tok_s=\(format(Double(promptTokens) / total * 1000))"
                    + " per_\(chunk)_median_ms=\(format(median(perFrame))) first_step_ms=\(format(steps.first?.ms ?? .nan))"
                    + " logits=\(value.0) rows=\(value.1) recurrent=\(value.2)")
            }
        }
        log("qwen-tp-wavefront-v1 rank=\(rank) digest-check \(same ? "same-bytes" : "DIFFERENT")")
        return same
    }

    static func isFullAttention(model: QwenTensorParallelModel, layer: Int) -> Bool {
        (layer + 1) % model.plan.fullAttentionInterval == 0
    }

    /// One short request through the product prefill, discarded.
    static func prefillWarmup(model: QwenTensorParallelModel, configuration: Data, chunk: Int) throws {
        let count = chunk + 1
        let budget = count + 8
        let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
            maximumTokensPerRequest: budget, maximumChunkTokens: chunk)
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-prefill-bench-warmup",
            vocabularySize: model.plan.vocabularySize, hiddenSize: model.plan.hiddenSize, activationDType: "bfloat16",
            maximumPromptTokens: count, maximumChunkTokens: chunk, maximumOutputTokens: budget - count,
            maximumContextTokens: budget)
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: prompt(count, vocabulary: model.plan.vocabularySize), chunkSize: chunk,
            outputCount: budget - count, stopTokenIDs: [])
        let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
            host: host, request: request)
        defer { try? session.retire() }
        while session.schedule.committedPromptTokens < request.promptCount {
            if let logits = try session.prefill(check: {}) { eval(logits) }
        }
    }
}
