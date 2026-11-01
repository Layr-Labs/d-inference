import Cmlx
import DarkbloomClusterProtocol
import Foundation
import MLX
@testable import MLXLLM
@testable import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Opt-in per-rank decode compute profile on ONE Mac: a real Qwen tensor
/// parallel shard at the planner's shares with no peer (every all-sum is the
/// rank's own partial, `QwenTensorParallelLocalReduction`), timed the way the
/// load's share probe times it (`QwenTensorParallelShareProbe`: the
/// request-owned batch session, one lane, the decode command-buffer limits):
/// - `plain`: one row, one token (`QwenTensorParallelBatchSession.decode`);
/// - `window S`: one row, an S-token verify window, confirmed and settled.
/// Each is also split into graph construction and evaluation with the
/// forward built whole first (layer stride 0), and the step's graph is
/// counted by primitive (MLX's own printout; views launch no kernel).
/// Then serial-chain microbenchmarks give the GPU's cost per dependent small
/// kernel and its streaming bandwidth.
/// QWEN_TP_COMPUTE_BENCH_MODEL=<model dir> [QWEN_TP_COMPUTE_BENCH_RANK=1]
/// [QWEN_TP_COMPUTE_BENCH_SHARES=3,2] [QWEN_TP_COMPUTE_BENCH_COLUMNS=4,5]
/// [QWEN_TP_COMPUTE_BENCH_ROUNDS=20] [QWEN_TP_COMPUTE_BENCH_PROMPT=64]
/// [QWEN_TP_COMPUTE_BENCH_CENSUS=1] [QWEN_TP_COMPUTE_BENCH_MICRO=1]
/// [QWEN_TP_COMPUTE_BENCH_LOG=<progress file>]
@Suite(.serialized)
struct QwenTensorParallelComputeBenchTests {
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to - from) / 1e6 }
    private static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
    private static func f(_ value: Double) -> String { String(format: "%.3f", value) }
    private static func stats(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n=0" }
        let s = values.sorted()
        return "med=\(f(s[s.count / 2])) p10=\(f(s[s.count / 10])) p90=\(f(s[min(s.count - 1, s.count * 9 / 10)])) n=\(s.count)"
    }
    private static func list(_ environment: [String: String], _ name: String, _ fallback: [Int]) -> [Int] {
        let parsed = (environment[name] ?? "").split(separator: ",").compactMap { Int($0) }
        return parsed.isEmpty ? fallback : parsed
    }

    /// Runs `body` with one bench treatment's task-local choices (the same results either way except
    /// `exact`/`new`, which take the batch-invariant projections): `new` (exact vectors, every fusion, the
    /// process's kernel settings), `off` (c41's kernels, no fusion), `exact` (exact vectors, no fusion),
    /// `fused` (c41's kernels with the fusions), `noswiglu` (`new` without the fused gate/up kernel),
    /// `scaled` (`new` with the scaled-inputs arithmetic and its family's default layouts).
    static func withTreatment(_ name: String, _ body: () throws -> Void) throws {
        let exact = ["new", "exact", "noswiglu", "scaled"].contains(name)
        let fused = ["new", "fused", "noswiglu", "scaled"].contains(name)
        guard exact || fused || name == "off" else { throw ProbeError("unknown treatment \(name)") }
        try QwenTensorParallelBatchSession.$exactVectorsOverride.withValue(exact) {
        try ResidualRMSNorm.$enabledOverride.withValue(fused) {
        try GatedDeltaConvolution.$enabledOverride.withValue(fused) {
        try GatedDeltaQKNorm.$enabledOverride.withValue(fused) {
        try Qwen35DecodeFusions.$v2Override.withValue(fused) {
        try AffineQuantizedVectors.$swigluOverride.withValue(name == "noswiglu" ? false : AffineQuantizedVectors.swigluOverride) {
            if name == "scaled" {
                try AffineQuantizedVectors.$arithmeticOverride.withValue(.scaledInputs) {
                    try AffineQuantizedVectors.$layoutsOverride.withValue(nil) { try body() }
                }
            } else {
                try body()
            }
        } } } } } }
    }

    /// Where `census` also writes the whole printout (`QWEN_TP_COMPUTE_BENCH_GRAPH=<prefix>`), one file per graph.
    nonisolated(unsafe) static var graphDump: (String, Int)?

    /// Primitive counts of the graph that ends in `outputs` (MLX's own printout).
    static func census(_ outputs: [MLXArray]) throws -> [String: Int] {
        guard let file = tmpfile() else { throw ProbeError("census: no temporary file") }
        defer { fclose(file) }
        let namer = mlx_node_namer_new()
        defer { mlx_node_namer_free(namer) }
        let vector = mlx_vector_array_new()
        defer { mlx_vector_array_free(vector) }
        for output in outputs { mlx_vector_array_append_value(vector, output.ctx) }
        guard mlx_print_graph(file, namer, vector) == 0 else { throw ProbeError("census: graph printout failed") }
        fflush(file); rewind(file)
        var counts: [String: Int] = [:]
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(line) }
        var dump = ""
        while getline(&line, &capacity, file) > 0, let line {
            let text = String(cString: line)
            if graphDump != nil { dump += text }
            guard let name = text.split(separator: " ", maxSplits: 1).first, !name.isEmpty,
                  text.contains(" -> ") else { continue }
            counts[String(name), default: 0] += 1
        }
        if let (prefix, index) = graphDump {
            try? dump.write(toFile: "\(prefix)-\(index).txt", atomically: true, encoding: .utf8)
            graphDump = (prefix, index + 1)
        }
        return counts
    }

    /// Primitives that only re-describe memory (no kernel when their input is contiguous).
    static let views: Set<String> = ["Reshape", "Slice", "Split", "Squeeze", "ExpandDims", "Transpose", "Broadcast",
                                     "AsStrided", "Flatten", "Unflatten", "StopGradient", "Depends"]

    static func censusLine(_ counts: [String: Int]) -> String {
        let total = counts.values.reduce(0, +)
        let kernels = counts.filter { !views.contains($0.key) }.values.reduce(0, +)
        return "total=\(total) non_view=\(kernels) "
            + counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_COMPUTE_BENCH_MODEL"] != nil))
    func perRankDecodeCompute() throws {
        let environment = ProcessInfo.processInfo.environment
        let progress: FileHandle? = environment["QWEN_TP_COMPUTE_BENCH_LOG"].flatMap { path in
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        func report(_ line: String) {
            print(line)
            if let progress { progress.write(Data((line + "\n").utf8)); try? progress.synchronize() }
        }
        let directory = URL(fileURLWithPath: environment["QWEN_TP_COMPUTE_BENCH_MODEL"]!, isDirectory: true)
        let rank = Int(environment["QWEN_TP_COMPUTE_BENCH_RANK"] ?? "1") ?? 1
        let shares = Self.list(environment, "QWEN_TP_COMPUTE_BENCH_SHARES", [3, 2])
        let columnsList = Self.list(environment, "QWEN_TP_COMPUTE_BENCH_COLUMNS", [4, 5])
        let rounds = Int(environment["QWEN_TP_COMPUTE_BENCH_ROUNDS"] ?? "20") ?? 20
        let promptCount = Int(environment["QWEN_TP_COMPUTE_BENCH_PROMPT"] ?? "64") ?? 64
        let doCensus = environment["QWEN_TP_COMPUTE_BENCH_CENSUS"] != "0"
        let doMicro = environment["QWEN_TP_COMPUTE_BENCH_MICRO"] != "0"
        if let prefix = environment["QWEN_TP_COMPUTE_BENCH_GRAPH"] { Self.graphDump = (prefix, 0) }
        let label = "qwen-tp-compute \(directory.lastPathComponent) rank=\(rank) shares=\(shares.map(String.init).joined(separator: ":"))"
            + " arch=\(GPU.deviceInfo().architecture)"
        // Kernel tuning (test-only names; the product never reads them): words per lane and layouts by vector count.
        let words = environment["QWEN_TP_AQV_WORDS_PER_LANE"].flatMap { Int($0) }
        let layouts = environment["QWEN_TP_AQV_LAYOUTS"].flatMap { AffineQuantizedVectors.LayoutTable(parsing: $0) }
        let arithmetic = environment["QWEN_TP_AQV_ARITHMETIC"].flatMap { AffineQuantizedVectors.Arithmetic(rawValue: $0) }
        let swiglu = environment["QWEN_TP_AQV_SWIGLU"].map { $0 == "1" }
        try AffineQuantizedVectors.$swigluOverride.withValue(swiglu) {
        try AffineQuantizedVectors.$arithmeticOverride.withValue(arithmetic) {
        try AffineQuantizedVectors.$wordsPerLaneOverride.withValue(words) {
        try AffineQuantizedVectors.$layoutsOverride.withValue(layouts) {
        try Device.withDefaultDevice(.gpu) {
            let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            let model = try QwenTensorParallelModel.load(modelDirectory: directory, role: .shard(rank: rank, size: 2),
                reduction: QwenTensorParallelLocalReduction(rank: rank, size: 2), shares: shares)
            report("\(label) plan=\(model.plan.name) layers=\(model.plan.layerCount) params_bytes=\(model.loadedParameterBytes)"
                + " active_bytes=\(Memory.activeMemory) load_s=\(Self.f(model.loadSeconds))"
                + " fuse=\(environment["DARKBLOOM_QWEN35_FUSE_ELEMENTWISE"] ?? "default")"
                + " exact_vectors=\(QwenTensorParallelBatchSession.usesExactVectors)"
                + " aqv: \(AffineQuantizedVectors.resolvedDescription(bits: model.plan.bits, groupSize: model.plan.groupSize, inputs: model.plan.hiddenSize))"
                + " swiglu=\(AffineQuantizedVectors.fusesSwiGLU(vectors: 1)):\(AffineQuantizedVectors.fusesSwiGLU(vectors: 4))"
                + " fast_synch=\(environment["MLX_METAL_FAST_SYNCH"] ?? "unset")")
            let maxColumns = columnsList.max() ?? 4
            // The interleaved mode's one session takes every treatment's steps and windows.
            let treatmentCount = environment["QWEN_TP_COMPUTE_BENCH_AB"].map { $0.split(separator: ",").count } ?? 0
            let outputs = 64 + max(2 * rounds * (1 + maxColumns) * (columnsList.count + 1),
                                   (rounds + 2) * treatmentCount * (1 + columnsList.reduce(0, +)))
            let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
                maximumTokensPerRequest: promptCount + outputs, maximumChunkTokens: max(min(promptCount, 512), maxColumns))
            let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-compute-bench",
                vocabularySize: model.plan.vocabularySize, hiddenSize: model.plan.hiddenSize, activationDType: "bfloat16",
                maximumPromptTokens: promptCount, maximumChunkTokens: min(promptCount, 512), maximumOutputTokens: outputs,
                maximumContextTokens: promptCount + outputs)
            var token = 1
            func next() -> Int { token = (token * 37 + 11) % model.plan.vocabularySize; return token }
            func newSession() throws -> QwenTensorParallelBatchSession {
                let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                    promptTokenIDs: (0..<promptCount).map { ($0 * 131 + 17) % model.plan.vocabularySize },
                    chunkSize: min(promptCount, 512), outputCount: outputs, stopTokenIDs: [])
                let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                    host: host, request: request)
                while session.schedule.committedPromptTokens < request.promptCount { _ = try session.prefill(check: {}) }
                return session
            }

            // 0a. Cohorts (QWEN_TP_COMPUTE_BENCH_ROWS=1,2,4,8): B rows' plain step and S-column verify
            // window, interleaved per round over layout tables (QWEN_TP_COMPUTE_BENCH_COHORT=family,tiles4,...:
            // `family` this family's own, `tiles4` c44's tiles of four past five vectors, any other name the
            // table QWEN_TP_COMPUTE_BENCH_COHORT_TABLE_<name>). Layouts never change a result. Product path.
            if let rowsList = environment["QWEN_TP_COMPUTE_BENCH_ROWS"] {
                let widths = rowsList.split(separator: ",").compactMap { Int($0) }.filter { (1...8).contains($0) }
                let tables = (environment["QWEN_TP_COMPUTE_BENCH_COHORT"] ?? "family,tiles4").split(separator: ",")
                    .map(String.init)
                func table(_ name: String) throws -> AffineQuantizedVectors.LayoutTable? {
                    switch name {
                    case "family": return nil
                    case "tiles4": return AffineQuantizedVectors.LayoutTable(parsing: "1=a:4:4:1/4=a:2:4:4/5=a:2:4:5/6=a:2:4:4")
                    default:
                        guard let text = environment["QWEN_TP_COMPUTE_BENCH_COHORT_TABLE_\(name)"],
                              let parsed = AffineQuantizedVectors.LayoutTable(parsing: text)
                        else { throw ProbeError("unknown cohort table \(name)") }
                        return parsed
                    }
                }
                let resolved = try tables.map { ($0, try table($0)) }
                let perSession = 8 + (rounds + 2) * resolved.count * (1 + columnsList.reduce(0, +))
                let cohortHost = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: widths.max() ?? 1,
                    maximumTokensPerRequest: promptCount + perSession, maximumChunkTokens: max(min(promptCount, 512), maxColumns))
                let cohortProfile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-compute-cohort-bench",
                    vocabularySize: model.plan.vocabularySize, hiddenSize: model.plan.hiddenSize, activationDType: "bfloat16",
                    maximumPromptTokens: promptCount, maximumChunkTokens: min(promptCount, 512), maximumOutputTokens: perSession,
                    maximumContextTokens: promptCount + perSession)
                for (name, value) in resolved {
                    let described = AffineQuantizedVectors.$layoutsOverride.withValue(value) {
                        [1, 2, 4, 6, 8, 12, 16, 20, 24, 28, 32].map {
                            "\($0)=\(AffineQuantizedVectors.layout(vectors: $0, inputs: model.plan.hiddenSize, outputs: 1 << 20, bits: model.plan.bits))"
                        }.joined(separator: ",")
                    }
                    report("\(label) cohort_table=\(name) layouts=\(described)")
                }
                for width in widths {
                    var sessions: [QwenTensorParallelBatchSession] = []
                    for row in 0 ..< width {
                        let request = try QwenLayerStageGenerationRequest(profile: cohortProfile, requestID: UUID(),
                            promptTokenIDs: (0..<promptCount).map { ($0 * 131 + row * 29 + 17) % model.plan.vocabularySize },
                            chunkSize: min(promptCount, 512), outputCount: perSession, stopTokenIDs: [])
                        let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                            host: cohortHost, request: request)
                        while session.schedule.committedPromptTokens < request.promptCount { _ = try session.prefill(check: {}) }
                        sessions.append(session)
                    }
                    var samples: [String: [Double]] = [:]
                    func timed(_ key: String, record: Bool, _ body: () throws -> Void) throws {
                        let started = Self.now()
                        try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) { try body() }
                        if record { samples[key, default: []].append(Self.ms(started, Self.now())) }
                    }
                    for round in 0 ..< (rounds + 2) {
                        // ABBA order per round, so drift falls on every table alike.
                        let order = round % 2 == 0 ? resolved : Array(resolved.reversed())
                        for (name, value) in order {
                            try AffineQuantizedVectors.$layoutsOverride.withValue(value) {
                                try timed("\(name) plain", record: round >= 2) {
                                    _ = try QwenTensorParallelBatchSession.decode(sessions,
                                        tokens: sessions.map { _ in next() }, check: {})
                                }
                                for columns in columnsList {
                                    let tokens = MLXArray((0 ..< width * columns).map { _ in Int32(next()) })
                                        .reshaped([width, columns])
                                    try timed("\(name) window\(columns)", record: round >= 2) {
                                        let built = try QwenTensorParallelBatchSession.beginWindows(sessions, tokens: tokens)
                                        eval(built.outputs + built.roots)
                                        try QwenTensorParallelBatchSession.confirmWindows(sessions, check: {})
                                        eval(try QwenTensorParallelBatchSession.settleWindows(sessions,
                                            keeping: Array(repeating: columns, count: width)))
                                        try QwenTensorParallelBatchSession.confirmSettledWindows(sessions, check: {})
                                    }
                                }
                            }
                        }
                    }
                    for key in samples.keys.sorted() {
                        let parts = key.split(separator: " ")
                        report("\(label) cohort rows=\(width) table=\(parts[0]) step=\(parts[1]) wall_ms \(Self.stats(samples[key]!))")
                    }
                    for session in sessions { try session.retire() }
                }
                guard cohortHost.isDrained else { throw ProbeError("cohort bench kept its pages") }
                return
            }

            // 0. Interleaved treatments (QWEN_TP_COMPUTE_BENCH_AB=new,off,...): every round runs each
            // treatment's plain step (then each treatment's windows) on one session, so drift (heat, other
            // load) falls on every treatment alike; medians per treatment. Product path only.
            if let list = environment["QWEN_TP_COMPUTE_BENCH_AB"] {
                let treatments = list.split(separator: ",").map(String.init)
                let session = try newSession()
                var samples: [String: [Double]] = [:]
                func timedStep(_ key: String, _ body: () throws -> Void) rethrows {
                    let started = Self.now()
                    try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) { try body() }
                    samples[key, default: []].append(Self.ms(started, Self.now()))
                }
                for round in 0 ..< (rounds + 2) {
                    for treatment in treatments {
                        try Self.withTreatment(treatment) {
                            if round < 2 {
                                _ = try QwenTensorParallelBatchSession.decode([session], tokens: [next()], check: {})
                                return
                            }
                            try timedStep("\(treatment) plain") {
                                _ = try QwenTensorParallelBatchSession.decode([session], tokens: [next()], check: {})
                            }
                        }
                    }
                }
                for columns in columnsList {
                    for round in 0 ..< (rounds + 2) {
                        for treatment in treatments {
                            try Self.withTreatment(treatment) {
                                let tokens = MLXArray((0..<columns).map { _ in Int32(next()) }).reshaped([1, columns])
                                func window() throws {
                                    let built = try QwenTensorParallelBatchSession.beginWindows([session], tokens: tokens)
                                    eval(built.outputs + built.roots)
                                    try QwenTensorParallelBatchSession.confirmWindows([session], check: {})
                                    eval(try QwenTensorParallelBatchSession.settleWindows([session], keeping: [columns]))
                                    try QwenTensorParallelBatchSession.confirmSettledWindows([session], check: {})
                                }
                                if round < 2 {
                                    try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) { try window() }
                                    return
                                }
                                try timedStep("\(treatment) window\(columns)") { try window() }
                            }
                        }
                    }
                }
                for key in samples.keys.sorted() {
                    report("\(label) ab=\(key.replacingOccurrences(of: " ", with: " step=")) wall_ms \(Self.stats(samples[key]!))")
                }
                try session.retire()
                guard host.isDrained else { throw ProbeError("compute bench kept its pages") }
                return
            }

            // 1. As the share probe and the native executor run them.
            let session = try newSession()
            for stride in [nil, 0] as [Int?] {
                let tag = stride.map { "stride\($0)" } ?? "product"
                var wall: [Double] = [], cpu: [Double] = []
                for index in 0..<(rounds + 3) {
                    let started = Self.now(), cpuStarted = Self.cpu()
                    try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) {
                        try QwenTensorParallelBatchSession.$layerStride.withValue(stride) {
                            _ = try QwenTensorParallelBatchSession.decode([session], tokens: [next()], check: {})
                        }
                    }
                    if index >= 3 { wall.append(Self.ms(started, Self.now())); cpu.append(Self.cpu() - cpuStarted) }
                }
                report("\(label) step=plain path=\(tag) wall_ms \(Self.stats(wall)) thread_cpu_ms \(Self.stats(cpu))")
            }
            for columns in columnsList {
              for stride in [nil, 0] as [Int?] {
                let tag = stride.map { "stride\($0)" } ?? "product"
                var wall: [Double] = [], build: [Double] = [], evaluate: [Double] = [], settle: [Double] = [], cpu: [Double] = []
                for index in 0..<(rounds + 3) {
                    let tokens = MLXArray((0..<columns).map { _ in Int32(next()) }).reshaped([1, columns])
                    let started = Self.now(), cpuStarted = Self.cpu()
                    var built: UInt64 = 0, evaluated: UInt64 = 0
                    try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) {
                        let window = try QwenTensorParallelBatchSession.$layerStride.withValue(stride) {
                            try QwenTensorParallelBatchSession.beginWindows([session], tokens: tokens)
                        }
                        built = Self.now()
                        eval(window.outputs + window.roots)
                        try QwenTensorParallelBatchSession.confirmWindows([session], check: {})
                        evaluated = Self.now()
                        eval(try QwenTensorParallelBatchSession.settleWindows([session], keeping: [columns]))
                        try QwenTensorParallelBatchSession.confirmSettledWindows([session], check: {})
                    }
                    let done = Self.now()
                    if index >= 3 {
                        wall.append(Self.ms(started, done)); build.append(Self.ms(started, built))
                        evaluate.append(Self.ms(built, evaluated)); settle.append(Self.ms(evaluated, done))
                        cpu.append(Self.cpu() - cpuStarted)
                    }
                }
                report("\(label) step=window columns=\(columns) path=\(tag) wall_ms \(Self.stats(wall)) build_ms \(Self.stats(build))"
                    + " eval_ms \(Self.stats(evaluate)) settle_ms \(Self.stats(settle)) thread_cpu_ms \(Self.stats(cpu))")
              }
            }
            try session.retire()

            // 2. The graphs, by primitive.
            if doCensus {
                let plain = try newSession()
                let input = MLXArray([Int32(next())]).reshaped([1, 1])
                var plainCounts: [String: Int] = [:]
                _ = try plain.state.run(tokenCount: 1, check: {}, forward: { caches, evaluation in
                    let out = Qwen35BatchDecodeScope.$enabled.withValue(true) {
                        Qwen35BatchDecodeScope.$exactVectors.withValue(QwenTensorParallelBatchSession.usesExactVectors) {
                            model.model.cbv2Forward(input, caches: caches.map { $0 as! any KVCache },
                                recurrentState: [evaluation], positionIds: nil)[0..., -1, 0...]
                        }
                    }
                    plainCounts = try Self.census([out])
                    return out
                }, validateOutput: { _ in })
                report("\(label) census=plain \(Self.censusLine(plainCounts))")
                try plain.retire()
                for columns in columnsList {
                    let windowed = try newSession()
                    let tokens = MLXArray((0..<columns).map { _ in Int32(next()) }).reshaped([1, columns])
                    var counts: [String: Int] = [:]
                    let built = try windowed.state.beginWindow(tokenCount: columns) { caches, evaluation in
                        let result = Qwen35BatchDecodeScope.$enabled.withValue(true) {
                            Qwen35BatchDecodeScope.$exactVectors.withValue(QwenTensorParallelBatchSession.usesExactVectors) {
                                model.model.cbv2ForwardWithHiddenCaptured(tokens, caches: caches.map { $0 as! any KVCache },
                                    recurrentState: [evaluation], positionIds: nil)
                            }
                        }
                        return [result.logits, result.lastHidden]
                    }
                    counts = try Self.census(built.outputs + built.roots)
                    eval(built.outputs + built.roots)
                    report("\(label) census=window columns=\(columns) \(Self.censusLine(counts))")
                    try windowed.retire()
                }
            }
            guard host.isDrained else { throw ProbeError("compute bench kept its pages") }
        }
        }
        }
        }
        }
        if doMicro { try Self.micro(report: { report("qwen-tp-compute-micro arch=\(GPU.deviceInfo().architecture) " + $0) }) }
    }

    /// Serial chains: the GPU cost of one dependent small kernel, a dependent
    /// quantized matrix-vector product at a few shard shapes, and streaming bandwidth.
    static func micro(report: (String) -> Void) throws {
        try Device.withDefaultDevice(.gpu) {
            func timed(_ repeats: Int = 7, _ body: () -> MLXArray) -> Double {
                eval(body())
                var samples: [Double] = []
                for _ in 0..<repeats {
                    let built = body()
                    let started = now()
                    eval(built)
                    samples.append(ms(started, now()))
                }
                return samples.sorted()[samples.count / 2]
            }
            try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) {
                let x = (MLXRandom.normal([1, 1, 5120]) * 0.5).asType(.bfloat16)
                let w = MLXArray.ones([5120], dtype: .bfloat16)
                eval(x, w)
                for chain in [64, 512] {
                    let elementwise = timed { var y = x; for _ in 0..<chain { y = y * 1.0001 }; return y }
                    let norms = timed { var y = x; for _ in 0..<chain { y = MLXFast.rmsNorm(y, weight: w, eps: 1e-6) }; return y }
                    report("chain=\(chain) elementwise_us_per_kernel=\(f(elementwise * 1000 / Double(chain)))"
                        + " rmsnorm_us_per_kernel=\(f(norms * 1000 / Double(chain)))")
                }
                // Quantized products at shard shapes ([in -> out], 4-bit group 64), each call on its OWN
                // weights (about 1 GB in all, past the system cache): the streaming rate of MLX's calls.
                for (inputs, outputs) in [(5120, 6976), (6976, 5120), (5120, 16384)] {
                    var linears: [QuantizedLinear] = []
                    var bytes = 0.0
                    while bytes < 1.0e9 {
                        let linear = QuantizedLinear(weight: MLXRandom.normal([outputs, inputs]) * 0.02, bias: nil,
                            groupSize: 64, bits: 4)
                        eval(linear.weight, linear.scales, linear.biases!)
                        bytes += Double(linear.weight.nbytes + linear.scales.nbytes + linear.biases!.nbytes)
                        linears.append(linear)
                    }
                    for dtype in [DType.bfloat16, .float32] {
                        for vectors in [1, 4, 5] {
                            let x = (MLXRandom.normal([1, vectors, inputs]) * 0.5).asType(dtype)
                            eval(x)
                            let t = timed(5) { concatenated(linears.map { $0(x) }, axis: 0) }
                            report("qmv [\(inputs)->\(outputs)] \(dtype) vectors=\(vectors) calls=\(linears.count)"
                                + " us_per_call=\(f(t * 1000 / Double(linears.count)))"
                                + " GBps=\(Int(bytes / (t / 1000) / 1e9))")
                        }
                    }
                    linears.removeAll()
                    Memory.clearCache()
                }
                // Streaming: read 2 GiB once (a sum), and copy 1 GiB.
                let big = MLXArray.ones([1 << 30], dtype: .bfloat16)
                eval(big)
                let read = timed(5) { big.sum(axis: 0, keepDims: false) }
                let copy = timed(5) { big + 1 }
                report("stream read_GBps=\(Int(Double(big.nbytes) / (read / 1000) / 1e9))"
                    + " copy_GBps(r+w)=\(Int(2 * Double(big.nbytes) / (copy / 1000) / 1e9))")
            }
        }
    }
}
