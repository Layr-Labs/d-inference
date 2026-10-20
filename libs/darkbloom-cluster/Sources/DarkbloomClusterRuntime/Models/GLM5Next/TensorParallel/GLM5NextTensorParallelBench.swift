import Cmlx
import Foundation
import MLX
import MLXLLM

/// Tensor-parallel measurement of the registered GLM model, one code path for
/// three modes so their times compare directly:
/// - `full`: the unsharded text model on one Mac (the reference);
/// - `shard`: one rank's half of every layer with no peer (each sum is the
///   local partial), which times the compute TP2 leaves each Mac;
/// - `tp`: one rank of a two-rank run over JACCL (`JACCL_RANK`,
///   `JACCL_IBV_DEVICES`, `JACCL_COORDINATOR`), summing each layer's attention
///   and feed-forward partials with the native all-sum.
/// The verified artifact loader reads every payload; standing residency is
/// applied as the product applies it. Greedy, no MTP, no prefix cache, no
/// sealing: a measurement and correctness tool, never a serving path.
public enum GLM5NextTensorParallelBench {
    public enum Mode: String, Sendable { case full, shard, tp }

    public struct Options: Sendable {
        public var modelDirectory: URL
        public var mode: Mode
        public var shardRank: Int
        public var promptTokenIDs: [Int]
        public var chunkSize: Int
        public var outputCount: Int
        public var repeats: Int
        /// Partials summed in float32 (one rounding, as the TP terms fix) or as stored.
        public var float32Partials: Bool
        /// Build each decode step from the previous step's still-lazy token and
        /// submit it before reading that token, so graph construction overlaps the GPU.
        public var pipelinedDecode = false
        /// Print one decode step's primitives by name (no peer only).
        public var census = false
        /// Seal every floating all-sum (AES-GCM, as the product's terms do) with
        /// bench keys from an ephemeral exchange: the sealed path's cost, never a trust.
        public var sealed = false
        /// MLX freed-buffer cache while measuring (nil: MLX's default).
        public var cacheLimitBytes: Int?
        public init(modelDirectory: URL, mode: Mode, shardRank: Int = 0, promptTokenIDs: [Int],
                    chunkSize: Int = 2048, outputCount: Int = 64, repeats: Int = 2, float32Partials: Bool = true) {
            self.modelDirectory = modelDirectory; self.mode = mode; self.shardRank = shardRank
            self.promptTokenIDs = promptTokenIDs; self.chunkSize = chunkSize; self.outputCount = outputCount
            self.repeats = repeats; self.float32Partials = float32Partials
        }
    }

    public struct Run: Codable, Sendable {
        public var prefillSeconds: Double
        public var prefillTokensPerSecond: Double
        public var decodeTokensPerSecond: Double
        public var stepP50Milliseconds: Double
        public var stepP90Milliseconds: Double
        public var tokenIDs: [Int]
        /// The first steps' five largest logits (token, value), for comparing modes.
        public var topLogits: [[[Double]]]
    }

    public struct Report: Codable, Sendable {
        public var mode: String
        public var rank: Int
        public var size: Int
        public var promptTokens: Int
        public var chunkSize: Int
        public var outputCount: Int
        public var loadSeconds: Double
        public var loadedActiveBytes: Int
        public var wiredLimitBytes: Int
        public var floatingReductions: Int
        public var runs: [Run]
        public var repeatsIdentical: Bool
    }

    public static func run(_ options: Options, log: (String) -> Void) throws -> Report {
        let spec = try GLM5NextRegisteredSpecification.specification(runtimeModelID: GLM5NextRegisteredModel.glm53Flash.rawValue)
        let directory = options.modelDirectory
        let config = try BoundedProbeInput.data(directory.appendingPathComponent("config.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumConfigurationBytes)
        let manifest = try BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumManifestBytes)
        let descriptor = try spec.descriptor(configuration: config, manifest: manifest,
            cut: spec.supportedCuts.first ?? 1)
        var group: QwenTensorParallelGroup?
        var shard: GLM5NextTensorShard?
        switch options.mode {
        case .full: break
        case .shard: shard = try GLM5NextTensorShard(rank: options.shardRank, size: 2)
        case .tp:
            let value = try QwenTensorParallelGroup(backend: .jaccl)
            if options.sealed {
                let codec = try QwenTensorParallelSealCodec.bench(group: value, scope: Data("glm-tp-bench".utf8))
                try codec.install(); value.sealed = codec
            }
            group = value
            shard = try GLM5NextTensorShard(rank: value.rank, size: value.size)
            log("tp rank=\(value.rank) size=\(value.size)")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let roots = GLM5NextArtifactLoadRoots()
        let loader = try GLM5NextArtifactLoader(directory: directory, expectedIdentity: descriptor.artifactIdentity,
            storage: descriptor.storage, constructionRoots: roots, executionPolicy: descriptor.executionPolicy)
        log("verified artifact in \(seconds(since: started)) s")
        let text = loader.configuration.textConfig
        let plan = try GLM5NextTextStagePlan(configuration: text, layers: 0 ..< text.hiddenLayers, shard: shard)
        let stage = try loader.loadTextStage(plan: plan)
        stage.freeze()
        try MLX.withError { error in
            try roots.evaluate(stage.parameters().flattened().map(\.1))
            Stream.gpu.synchronize(); try error.check()
        }
        roots.releaseAfterConfirmedFence()
        if let group {
            let float32 = options.float32Partials
            try stage.installTensorParallelReduction { partial in
                float32 ? group.allSum(partial.asType(.float32)).asType(partial.dtype) : group.allSum(partial)
            }
        } else if shard != nil {
            // Shard-local: a sum with no peer is the rank's own partial.
            try stage.installTensorParallelReduction { $0 }
        }
        Memory.clearCache()
        if let limit = options.cacheLimitBytes { Memory.cacheLimit = limit }
        let loaded = Memory.activeMemory
        let residency = try ClusterStageResidency(bytes: loaded + (24 << 30))
        let loadSeconds = seconds(since: started)
        log("loaded mode=\(options.mode.rawValue) active=\(loaded) wired=\(residency.receipt.appliedBytes) in \(loadSeconds) s")
        if options.census, group == nil {
            let counts = try decodeCensus(stage: stage, prompt: Array(options.promptTokenIDs.prefix(64)))
            log("census: \(counts.values.reduce(0, +)) primitives in one decode step; top: "
                + counts.sorted { $0.value > $1.value }.prefix(16).map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        if let group {
            // Both ranks start each measurement together.
            _ = try group.exchangeIntegers([1])
        }
        var runs: [Run] = []
        for repeatIndex in 0 ..< max(1, options.repeats) {
            if let group { _ = try group.exchangeIntegers([Int32(repeatIndex)]) }
            runs.append(try generate(stage: stage, options: options))
            let r = runs.last!
            log(String(format: "run %d prefill %.1f tok/s (%.2f s) decode %.2f tok/s p50 %.2f ms p90 %.2f ms first tokens %@",
                repeatIndex, r.prefillTokensPerSecond, r.prefillSeconds, r.decodeTokensPerSecond,
                r.stepP50Milliseconds, r.stepP90Milliseconds, r.tokenIDs.prefix(8).map(String.init).joined(separator: ",")))
        }
        try residency.end()
        return Report(mode: options.mode.rawValue, rank: group?.rank ?? options.shardRank, size: group?.size ?? 1,
            promptTokens: options.promptTokenIDs.count, chunkSize: options.chunkSize, outputCount: options.outputCount,
            loadSeconds: loadSeconds, loadedActiveBytes: loaded, wiredLimitBytes: residency.receipt.appliedBytes,
            floatingReductions: group?.floatingReductions ?? 0, runs: runs,
            repeatsIdentical: Set(runs.map(\.tokenIDs)).count == 1)
    }

    private static func generate(stage: GLM5NextTextStage, options: Options) throws -> Run {
        let prompt = options.promptTokenIDs, chunk = max(1, options.chunkSize)
        let cache = stage.newCache()
        var logits: MLXArray?
        let prefillStart = DispatchTime.now().uptimeNanoseconds
        var offset = 0
        while offset < prompt.count {
            let end = min(prompt.count, offset + chunk)
            let last = end == prompt.count
            let tokens = MLXArray(prompt[offset ..< end].map(Int32.init), [1, end - offset])
            let candidate = try stage.prepareForward(tokens: tokens, cache: cache, readout: last ? .lastToken : .none)
            try candidate.commit { roots in eval(roots) }
            if last, case .final(let output) = candidate.output { logits = output.logits[0..., -1, 0...] }
            offset = end
        }
        guard var row = logits else { throw ProbeError("GLM bench prefill produced no logits") }
        var top: [[[Double]]] = []
        func record(_ row: MLXArray) {
            guard top.count < 4 else { return }
            let values = row.asType(.float32).reshaped(-1).asArray(Float.self)
            let best = values.indices.sorted { values[$0] > values[$1] }.prefix(5)
            top.append(best.map { [Double($0), Double(values[$0])] })
        }
        record(row)
        var token = argMax(row.asType(.float32), axis: -1).item(Int32.self)
        let prefillSeconds = seconds(since: prefillStart)
        var tokens = [Int(token)]
        var steps: [Double] = []
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        if options.pipelinedDecode {
            // The token stays an MLXArray: step k+1 is built and submitted before
            // step k's token is read on the host.
            var lazyToken = MLXArray([token], [1, 1])
            var previous = DispatchTime.now().uptimeNanoseconds
            var pending: MLXArray?
            for _ in 1 ..< max(1, options.outputCount) {
                let candidate = try stage.prepareForward(tokens: lazyToken, cache: cache, readout: .lastToken)
                try candidate.commit { roots in asyncEval(roots) }
                guard case .final(let output) = candidate.output else { throw ProbeError("GLM bench decode produced no logits") }
                let next = argMax(output.logits[0..., -1, 0...].asType(.float32), axis: -1).asType(.int32).reshaped(1, 1)
                asyncEval(next)
                if let pending {
                    tokens.append(Int(pending.item(Int32.self)))
                    let now = DispatchTime.now().uptimeNanoseconds
                    steps.append(Double(now - previous) / 1e9); previous = now
                }
                pending = next; lazyToken = next
            }
            if let pending {
                tokens.append(Int(pending.item(Int32.self)))
                let now = DispatchTime.now().uptimeNanoseconds
                steps.append(Double(now - previous) / 1e9)
            }
        } else {
        for _ in 1 ..< max(1, options.outputCount) {
            let stepStart = DispatchTime.now().uptimeNanoseconds
            let candidate = try stage.prepareForward(tokens: MLXArray([token], [1, 1]), cache: cache, readout: .lastToken)
            try candidate.commit { roots in eval(roots) }
            guard case .final(let output) = candidate.output else { throw ProbeError("GLM bench decode produced no logits") }
            row = output.logits[0..., -1, 0...]
            record(row)
            token = argMax(row.asType(.float32), axis: -1).item(Int32.self)
            tokens.append(Int(token))
            steps.append(seconds(since: stepStart))
        }
        }
        let decodeSeconds = seconds(since: decodeStart)
        let sorted = steps.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
        return Run(prefillSeconds: prefillSeconds,
            prefillTokensPerSecond: Double(prompt.count) / prefillSeconds,
            decodeTokensPerSecond: steps.isEmpty ? 0 : Double(steps.count) / decodeSeconds,
            stepP50Milliseconds: percentile(0.5), stepP90Milliseconds: percentile(0.9), tokenIDs: tokens,
            topLogits: top)
    }

    /// One decode step's graph (logits and cache updates) by primitive name.
    static func decodeCensus(stage: GLM5NextTextStage, prompt: [Int]) throws -> [String: Int] {
        let cache = stage.newCache()
        let warm = try stage.prepareForward(tokens: MLXArray(prompt.map(Int32.init), [1, prompt.count]), cache: cache,
            readout: .lastToken)
        try warm.commit { roots in eval(roots) }
        let candidate = try stage.prepareForward(tokens: MLXArray([Int32(1)], [1, 1]), cache: cache, readout: .lastToken)
        guard case .final(let output) = candidate.output else { throw ProbeError("census: no logits") }
        guard let file = tmpfile() else { throw ProbeError("census: no temporary file") }
        defer { fclose(file) }
        let namer = mlx_node_namer_new()
        defer { mlx_node_namer_free(namer) }
        let outputs = mlx_vector_array_new()
        defer { mlx_vector_array_free(outputs) }
        mlx_vector_array_append_value(outputs, output.logits.ctx)
        for state in cache.layers.flatMap({ $0.innerState() }) { mlx_vector_array_append_value(outputs, state.ctx) }
        guard mlx_print_graph(file, namer, outputs) == 0 else { throw ProbeError("census: graph printout failed") }
        fflush(file); rewind(file)
        var counts: [String: Int] = [:]
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(line) }
        while getline(&line, &capacity, file) > 0, let line {
            let text = String(cString: line)
            guard let name = text.split(separator: " ", maxSplits: 1).first, !name.isEmpty, text.contains(" -> ") else { continue }
            counts[String(name), default: 0] += 1
        }
        candidate.discard()
        return counts
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }
}

extension GLM5NextTensorParallelBench {
    /// Raw cross-rank sum cost on this pair: each shape summed `count` times,
    /// evaluated one at a time (as a decode step meets them) and as one graph.
    public static func allSumProbe(shapes: [[Int]], count: Int, log: (String) -> Void) throws {
        let group = try QwenTensorParallelGroup(backend: .jaccl)
        func pass(dtype: DType, sealed: Bool) throws {
            for shape in shapes {
                let value = MLXArray.ones(shape, dtype: dtype) * Float(group.rank + 1)
                eval(value)
                _ = try group.exchangeIntegers([1])
                var start = DispatchTime.now().uptimeNanoseconds
                for _ in 0 ..< count { eval(group.allSum(value)) }
                let one = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(count)
                _ = try group.exchangeIntegers([2])
                start = DispatchTime.now().uptimeNanoseconds
                var chained = value
                for _ in 0 ..< count { chained = group.allSum(chained) * 0.5 }
                eval(chained)
                let graph = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(count)
                // (1 + 2) / 2 from the first sum on: any other value is a stale or torn read.
                let error = abs(chained.asType(.float32) - 1.5).max().item(Float.self)
                let bytes = shape.reduce(dtype == .float32 ? 4 : 2, *)
                log(String(format: "allsum sealed=%d dtype=%@ shape=%@ bytes=%d eval_each=%.3f ms graph=%.3f ms (%.2f GB/s) max_error=%g",
                    sealed ? 1 : 0, "\(dtype)", shape.map(String.init).joined(separator: "x"), bytes, one, graph,
                    Double(bytes) / (graph / 1000) / 1e9, error))
            }
        }
        try pass(dtype: .bfloat16, sealed: false)
        try pass(dtype: .float32, sealed: false)
        let codec = try QwenTensorParallelSealCodec.bench(group: group, scope: Data("glm-tp-bench".utf8))
        try codec.install(); group.sealed = codec
        try pass(dtype: .float32, sealed: true)
        try pass(dtype: .bfloat16, sealed: true)
    }
}

extension GLM5NextTensorParallelBench {
    /// Local cost of the sealed reduction's crypto alone (no link): one rank's
    /// seal of a partial and the other's open of it, with paired test keys.
    public static func sealProbe(bytes sizes: [Int], repeats: Int, log: (String) -> Void) {
        let (zero, one) = QwenTensorParallelSealCodec.pair(scope: Data("glm-tp-seal-probe".utf8))
        var next: UInt64 = 0
        for bytes in sizes {
            let plain = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
            let opened = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
            let frame = UnsafeMutableRawPointer.allocate(byteCount: bytes + QwenTensorParallelSealCodec.frameOverhead, alignment: 64)
            defer { plain.deallocate(); opened.deallocate(); frame.deallocate() }
            memset(plain, 0x5A, bytes)
            var sealNs: UInt64 = 0, openNs: UInt64 = 0
            for _ in 0 ..< repeats {
                let counter = next; next += 1
                var t = DispatchTime.now().uptimeNanoseconds
                guard zero.seal(plain, bytes, frame, counter) == 0 else { log("seal refused"); return }
                sealNs += DispatchTime.now().uptimeNanoseconds - t
                t = DispatchTime.now().uptimeNanoseconds
                guard one.open(frame, bytes, opened, counter, 0) == 0 else { log("open refused"); return }
                openNs += DispatchTime.now().uptimeNanoseconds - t
            }
            let seal = Double(sealNs) / 1e6 / Double(repeats), open = Double(openNs) / 1e6 / Double(repeats)
            log(String(format: "seal-probe bytes=%d seal=%.3f ms (%.2f GB/s) open=%.3f ms (%.2f GB/s)",
                bytes, seal, Double(bytes) / seal / 1e6, open, Double(bytes) / open / 1e6))
        }
    }
}
