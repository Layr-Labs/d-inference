import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Qwen3.8-27B rows at the registered per-rank widths, for the row-count
/// gate before wider Qwen TP lanes: one rank's half of a check that a row's
/// logits and history are the same bytes alone (P1), beside rows of other
/// context lengths that join and leave (PB), while an assistant observes the
/// cohort, and at every position of a four-column verify window alone or in
/// a cohort (W). Both ranks run `run` in lock step (their reductions pair
/// them); each compares only its own digests. Random weights with the
/// registered artifact's statistics (`tensors`), or a registered checkpoint's
/// files through the tool, never a model pass: the test suite runs it in one
/// process, `darkbloom-cluster-tp-check qwen-rows` over the loopback ring.
public enum QwenTensorParallelRowsCheck {
    public struct Report: Codable, Sendable {
        public var rank: Int
        public var compared: Int
        public var differing: [String]
        public var reservedBytesAcrossSegments: Int
        public var census: String
        public var kernel: String
        public var passed: Bool { differing.isEmpty && compared > 0 }
    }

    /// The registered 27B text geometry at `layers` layers (three Gated
    /// DeltaNet layers to one attention layer, as registered).
    static func configuration(layers: Int) throws -> Data {
        let text: [String: Any] = [
            "model_type": "qwen3_5_text", "hidden_size": 5120, "num_hidden_layers": layers,
            "full_attention_interval": 4, "num_attention_heads": 24, "num_key_value_heads": 4, "head_dim": 256,
            "linear_num_key_heads": 16, "linear_num_value_heads": 48, "linear_key_head_dim": 128,
            "linear_value_head_dim": 128, "linear_conv_kernel_dim": 4, "intermediate_size": 17408,
            "vocab_size": 248_320, "tie_word_embeddings": false, "attn_output_gate": true, "attention_bias": false,
            "rms_norm_eps": 1e-6, "max_position_embeddings": 262_144, "partial_rotary_factor": 0.25,
            "rope_parameters": ["mrope_interleaved": true, "mrope_section": [11, 11, 10], "partial_rotary_factor": 0.25,
                                "rope_theta": 10_000_000, "rope_type": "default"],
            "layer_types": (0..<layers).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" },
        ]
        let root: [String: Any] = ["model_type": "qwen3_5", "text_config": text,
                                   "quantization": ["group_size": 64, "bits": 4, "mode": "affine"]]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Every checkpoint tensor of `layers` layers, each drawn from its own
    /// name's seed, so both ranks cut the same values without holding the
    /// whole checkpoint at once. The values follow the registered artifact's
    /// statistics: MLX's affine quantization of near-normal weights (signed
    /// scales of 0.001-0.005, biases -8 x scale, codes about 8), its norm,
    /// convolution, `A_log` and `dt_bias` ranges, and gate rows whose SwiGLU
    /// inputs reach its range (its gates reach |33| in later layers).
    static func tensors(layers: Int, _ keep: (String, MLXArray) throws -> Void) throws {
        let h = 5120, inter = 17408, vocabulary = 248_320, hq = 24, hkv = 4, hd = 256, nk = 16, nv = 48
        let lk = nk * 128, lv = nv * 128
        func key(_ name: String) -> MLXArray {
            MLXRandom.key(name.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 })
        }
        // `rowGains`: each row's scales times 1 to 8 (log-uniform), as the gate's.
        func q(_ name: String, _ out: Int, _ input: Int, rowGains: Bool = false) throws {
            let keys = MLXRandom.split(key: key(name), into: 5)
            let groups = [out, input / 64]
            var scales = MLXRandom.uniform(low: Float(0.001), high: Float(0.005), groups, key: keys[0])
                * which(MLXRandom.bernoulli(groups, key: keys[1]), Float(1), Float(-1))
            if rowGains {
                scales = scales * MLX.pow(Float(2), MLXRandom.uniform(low: Float(0), high: Float(3), [out, 1], key: keys[2]))
            }
            let rounded = scales.asType(.bfloat16)
            // Codes 1-15 about 8: two 3-bit draws a code, eight codes a word.
            func draws(_ key: MLXArray) -> MLXArray {
                MLXRandom.randInt(low: 0, high: Int32.max, [out, input / 8], key: key).asType(.uint32)
                    & MLXArray(UInt32(0x7777_7777))
            }
            try keep(name + ".weight", draws(keys[3]) + draws(keys[4]) + MLXArray(UInt32(0x1111_1111)))
            try keep(name + ".scales", rounded)
            try keep(name + ".biases", (rounded * -8).asType(.bfloat16))
        }
        func uniform(_ name: String, _ n: Int, _ low: Float, _ high: Float) throws {
            try keep(name, MLXRandom.uniform(low: low, high: high, [n], key: key(name)).asType(.bfloat16))
        }
        try q("language_model.model.embed_tokens", vocabulary, h)
        try q("language_model.lm_head", vocabulary, h)
        try uniform("language_model.model.norm.weight", h, 0.7, 2.7)
        for layer in 0..<layers {
            let p = "language_model.model.layers.\(layer)."
            try uniform(p + "input_layernorm.weight", h, 0.5, 2)
            try uniform(p + "post_attention_layernorm.weight", h, 0.5, 1.5)
            try q(p + "mlp.gate_proj", inter, h, rowGains: true); try q(p + "mlp.up_proj", inter, h)
            try q(p + "mlp.down_proj", h, inter)
            if (layer + 1) % 4 != 0 {
                try q(p + "linear_attn.in_proj_qkv", 2 * lk + lv, h); try q(p + "linear_attn.in_proj_z", lv, h)
                try q(p + "linear_attn.in_proj_b", nv, h); try q(p + "linear_attn.in_proj_a", nv, h)
                try q(p + "linear_attn.out_proj", h, lv)
                try keep(p + "linear_attn.conv1d.weight",
                         (MLXRandom.normal([2 * lk + lv, 4, 1], key: key(p + "conv")) * 0.045).asType(.bfloat16))
                try uniform(p + "linear_attn.A_log", nv, -5.5, 2.5)
                try uniform(p + "linear_attn.dt_bias", nv, -7.5, 19)
                try uniform(p + "linear_attn.norm.weight", 128, 0.7, 1.15)
            } else {
                try q(p + "self_attn.q_proj", 2 * hq * hd, h); try q(p + "self_attn.k_proj", hkv * hd, h)
                try q(p + "self_attn.v_proj", hkv * hd, h); try q(p + "self_attn.o_proj", h, hq * hd)
                try uniform(p + "self_attn.q_norm.weight", hd, 0.4, 2.2)
                try uniform(p + "self_attn.k_norm.weight", hd, 0.4, 2.2)
            }
        }
    }

    /// The checkpoint as files (`config.json`, one safetensors file per
    /// part and the index), for two processes to load.
    public static func writeCheckpoint(directory: URL, layers: Int = 4) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try configuration(layers: layers).write(to: directory.appendingPathComponent("config.json"))
        var parts: [String: [String: MLXArray]] = [:]
        try tensors(layers: layers) { name, value in
            eval(value)
            let part = name.contains(".layers.") ? "model-layers.safetensors"
                : name.contains("lm_head") ? "model-head.safetensors" : "model-embed.safetensors"
            parts[part, default: [:]][name] = value
        }
        var map: [String: String] = [:]
        for (file, arrays) in parts {
            try save(arrays: arrays, url: directory.appendingPathComponent(file))
            for name in arrays.keys { map[name] = file }
        }
        try JSONSerialization.data(withJSONObject: ["metadata": [:] as [String: Any], "weight_map": map],
                                   options: [.sortedKeys]).write(to: directory.appendingPathComponent("model.safetensors.index.json"))
    }

    static let profile = try! QwenLayerStageGenerationProfile(identifier: "qwen27-tp-rows-check",
        vocabularySize: 248_320, hiddenSize: 5120, activationDType: "bfloat16", maximumPromptTokens: 8192,
        maximumChunkTokens: 512, maximumOutputTokens: 64, maximumContextTokens: 8192)

    /// A row's prompt and its `step`-th decode input depend only on the row.
    static func prompt(_ row: Int, length: Int) -> [Int] { (0..<length).map { ($0 * 7919 + row * 104_729 + 13) % 248_320 } }
    static func token(_ row: Int, _ step: Int) -> Int { (step * 15_485_863 + row * 32_452_843 + 7) % 248_320 }

    /// Context lengths across the decode kernels' partition and buffer
    /// thresholds (256-token partitions; 1,024, 2,048 and 4,096 keys).
    static let lengths: [Int: Int] = [0: 100, 1: 250, 2: 509, 3: 760, 4: 1020, 5: 1100, 6: 2045, 7: 4090]
    /// Rows whose eight histories need more than one 64 MB segment of the
    /// paged pool (2 KB a token a rank at four layers), so rows span segments.
    static let longLengths: [Int: Int] = [10: 4100, 11: 4350, 12: 4600, 13: 4000, 14: 4500, 15: 4250, 16: 4096, 17: 4400]

    /// This rank's digests: logits by row and step (step -1: the prompt's
    /// last logits) and history by row and decode count.
    struct Trace {
        var logits: [String: String] = [:]
        var history: [String: String] = [:]
        static func key(_ row: Int, _ step: Int) -> String { "\(row)/\(step)" }

        /// Every digest of this trace that differs from the reference's, or
        /// that the reference lacks (so a mislabeled trace is never skipped).
        func mismatches(_ reference: Trace, label: String) -> [String] {
            logits.keys.sorted().filter { reference.logits[$0] != logits[$0] }.map { "\(label) logits \($0)" }
                + history.keys.sorted().filter { reference.history[$0] != history[$0] }.map { "\(label) history \($0)" }
        }
    }

    /// One rank's host and the sessions of the rows it holds.
    final class Rows {
        let model: QwenTensorParallelModel, configuration: Data, host: CBv2StageKVHost
        var sessions: [Int: QwenTensorParallelBatchSession] = [:]
        var trace = Trace()
        init(_ model: QwenTensorParallelModel, configuration: Data, lanes: Int) throws {
            self.model = model; self.configuration = configuration
            host = try .init(model: model.model, kind: .paged, lanes: lanes, maximumTokensPerRequest: 8192,
                maximumChunkTokens: 512)
        }

        /// A logits row's digest, marked when a value is not finite (serving
        /// refuses such a row in selection, which this check never runs).
        /// `run` refuses a marked reference after both ranks' last collective.
        static func digest(_ value: MLXArray) -> String {
            (all(isFinite(value)).item(Bool.self) ? "" : nonfinite) + sha256(value.asData(access: .copy).data)
        }
        static let nonfinite = "nonfinite:"

        func historyDigest(_ row: Int) throws -> String {
            let session = sessions[row]!
            var roots: [MLXArray] = []
            for row in session.state.rows.compactMap({ $0 }) {
                let view = row.snapshot(); roots += [view.keys, view.values]
            }
            guard let recurrent = session.state.recurrent.confirmedStateSnapshot() else {
                throw ProbeError("Qwen TP rows check: no confirmed recurrent state")
            }
            for index in recurrent.keys.sorted() {
                guard let conv = recurrent[index]?.conv, let ssm = recurrent[index]?.ssm else {
                    throw ProbeError("Qwen TP rows check: a recurrent layer has no state")
                }
                roots += [conv, ssm]
            }
            eval(roots)
            return sha256(Data(roots.map { sha256($0.asData(access: .copy).data) }.joined(separator: ",").utf8))
        }

        /// Opens `row` and prefills its prompt whole.
        func open(_ row: Int, length: Int) throws {
            let request = try QwenLayerStageGenerationRequest(profile: QwenTensorParallelRowsCheck.profile, requestID: UUID(),
                promptTokenIDs: QwenTensorParallelRowsCheck.prompt(row, length: length), chunkSize: 512, outputCount: 48,
                stopTokenIDs: [])
            let session = try QwenTensorParallelBatchSession(model: model, configuration: configuration, host: host,
                request: request)
            sessions[row] = session
            var last: MLXArray?
            while session.schedule.committedPromptTokens < request.promptCount { last = try session.prefill(check: {}) }
            guard let last else { throw ProbeError("Qwen TP rows check: the prompt returned no logits") }
            trace.logits[Trace.key(row, -1)] = Self.digest(last)
        }

        /// Plain steps: `schedule(step)` names the rows that decode (in that
        /// order), a row's k-th decode feeding `token(row, k)`; `joins` open
        /// rows before a step and `leaves` retire them after one. History is
        /// taken after a row's last step, or after every step.
        func plainSteps(lengths: [Int: Int], steps: Int, schedule: (Int) -> [Int], joins: [Int: [Int]] = [:],
                        leaves: [Int: [Int]] = [:], everyStep: Bool = false, observing: Bool = false) throws {
            var taken: [Int: Int] = [:]
            func history(_ row: Int) throws { trace.history[Trace.key(row, taken[row, default: 0])] = try historyDigest(row) }
            for step in 0..<steps {
                for row in joins[step] ?? [] { try open(row, length: lengths[row]!) }
                let active = schedule(step)
                guard !active.isEmpty else { continue }
                let rows = active.map { sessions[$0]! }
                let inputs = active.map { QwenTensorParallelRowsCheck.token($0, taken[$0, default: 0]) }
                // The native executor's command-buffer limits for decode steps and windows.
                let logits = try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) {
                    observing
                        ? try QwenTensorParallelBatchSession.decodeWithHidden(rows, tokens: inputs, check: {}).logits
                        : try QwenTensorParallelBatchSession.decode(rows, tokens: inputs, check: {})
                }
                for (position, row) in active.enumerated() {
                    trace.logits[Trace.key(row, taken[row, default: 0])] = Self.digest(logits[position ..< position + 1])
                    taken[row, default: 0] += 1
                }
                if everyStep { for row in active { try history(row) } }
                for row in leaves[step] ?? [] { try history(row); try sessions.removeValue(forKey: row)?.retire() }
            }
            for row in sessions.keys.sorted() { try history(row) }
        }

        /// Four-column windows settled whole: one session's own window, or a
        /// cohort's batched window.
        func windows(_ members: [Int], rounds: Int, columns: Int) throws {
            for round in 0..<rounds {
                let base = round * columns
                let tokens = members.flatMap { row in (0..<columns).map { Int32(QwenTensorParallelRowsCheck.token(row, base + $0)) } }
                let flat = MLXArray(tokens).reshaped([members.count, columns])
                let rows = members.map { sessions[$0]! }
                let built = try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) {
                    () throws -> (outputs: [MLXArray], roots: [MLXArray]) in
                    if rows.count == 1 {
                        let built = try rows[0].beginWindow(tokens: flat, offset: rows[0].committedTokens)
                        eval(built.outputs + built.roots)
                        try rows[0].confirmWindow(check: {})
                        eval(try rows[0].settleWindow(keeping: columns))
                        try rows[0].confirmSettled(check: {})
                        return built
                    }
                    let built = try QwenTensorParallelBatchSession.beginWindows(rows, tokens: flat)
                    eval(built.outputs + built.roots)
                    try QwenTensorParallelBatchSession.confirmWindows(rows, check: {})
                    eval(try QwenTensorParallelBatchSession.settleWindows(rows, keeping: Array(repeating: columns, count: rows.count)))
                    try QwenTensorParallelBatchSession.confirmSettledWindows(rows, check: {})
                    return built
                }
                for (position, row) in members.enumerated() {
                    for column in 0..<columns {
                        trace.logits[Trace.key(row, base + column)] = Self.digest(built.outputs[0][position, column])
                    }
                }
            }
            for row in members { trace.history[Trace.key(row, rounds * columns)] = try historyDigest(row) }
        }

        func retireAll() throws {
            for row in sessions.keys.sorted() { try sessions.removeValue(forKey: row)?.retire() }
            guard host.isDrained else { throw ProbeError("Qwen TP rows check: a host kept pages after retirement") }
        }
    }

    /// The first decoder layer whose output for `target` differs between its
    /// step alone (P1) and beside `other` (PB2), at each of `steps` decode
    /// steps: a diagnostic for a row that leaves its solo bits, evaluating
    /// each layer as it is built (`Qwen35LayerSubmission.observer`). Both
    /// ranks call it in lock step; each reports its own rows.
    public static func firstDifferingLayers(model: QwenTensorParallelModel, configuration: Data, target: Int = 7,
                                            other: Int = 6, steps: Int = 3) throws -> [String] {
        guard let targetLength = lengths[target], let otherLength = lengths[other], target != other, steps > 0 else {
            throw ProbeError("Qwen TP rows check: layers needs two different rows of 0 to 7")
        }
        final class Outputs: @unchecked Sendable { var layers: [MLXArray] = [] }
        func observed(_ rows: Rows, members: [Int], position: Int) throws -> [(layers: [MLXArray], logits: MLXArray)] {
            try (0..<steps).map { step in
                let outputs = Outputs()
                let logits = try Qwen35LayerSubmission.$observer.withValue({ _, hidden in
                    let row = hidden[position ..< position + 1]
                    eval(row)
                    outputs.layers.append(row)
                }) {
                    try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) {
                        try QwenTensorParallelBatchSession.decode(members.map { rows.sessions[$0]! },
                            tokens: members.map { token($0, step) }, check: {})
                    }
                }
                return (outputs.layers, logits[position ..< position + 1])
            }
        }
        let alone = try Rows(model, configuration: configuration, lanes: 1)
        try alone.open(target, length: targetLength)
        let solo = try observed(alone, members: [target], position: 0)
        try alone.retireAll()
        let pair = try Rows(model, configuration: configuration, lanes: 2)
        try pair.open(other, length: otherLength)
        try pair.open(target, length: targetLength)
        let beside = try observed(pair, members: [other, target], position: 1)
        try pair.retireAll()
        // After both ranks' last collective: an observer that never ran would report every layer equal.
        guard zip(solo, beside).allSatisfy({ !$0.0.layers.isEmpty && $0.0.layers.count == $0.1.layers.count }) else {
            throw ProbeError("Qwen TP rows check: the layer observer saw no layers, or other counts beside a row")
        }
        return zip(solo, beside).enumerated().map { step, compared in
            let logits = Rows.digest(compared.0.logits) == Rows.digest(compared.1.logits) ? "equal" : "differ"
            guard let layer = compared.0.layers.indices.first(where: {
                compared.0.layers[$0].asData(access: .copy).data != compared.1.layers[$0].asData(access: .copy).data
            }) else { return "step \(step): all \(compared.0.layers.count) layer outputs equal, logits \(logits)" }
            let a = compared.0.layers[layer].asType(.float32), b = compared.1.layers[layer].asType(.float32)
            let count = (a .!= b).sum().item(Int.self), gap = abs(a - b).max().item(Float.self)
            return "step \(step): first differing layer \(layer): \(count)/\(a.size) values, max |d| \(gap); logits \(logits)"
        }
    }

    /// The check's two halves. Each compares only against the solo runs it
    /// makes itself, so each also runs alone: the test suite runs them in
    /// separate processes, and `run` with both is the whole check.
    public enum Part: CaseIterable, Sendable {
        /// The rows of `lengths`: alone on a one- and an eight-lane host
        /// (P1), beside rows that join and leave (PB8, PB2, PB4), while an
        /// assistant observes the cohort, and at every verify-window
        /// position alone and in a cohort (W).
        case rows
        /// The rows of `longLengths`, alone and together across KV segments.
        case segments
    }

    /// This rank's comparisons; both ranks call it with the same arguments.
    /// `parts` selects the halves of the check; the default runs all of it.
    public static func run(model: QwenTensorParallelModel, configuration: Data, rank: Int, steps: Int = 12,
                           parts: Set<Part> = Set(Part.allCases)) throws -> Report {
        func rows(_ lanes: Int) throws -> Rows { try Rows(model, configuration: configuration, lanes: lanes) }
        func solo(lanes: Int, members: [Int], lengths: [Int: Int], steps: Int) throws -> Trace {
            var trace = Trace()
            for row in members {
                let alone = try rows(lanes)
                try alone.open(row, length: lengths[row]!)
                try alone.plainSteps(lengths: lengths, steps: steps, schedule: { _ in [row] }, everyStep: true)
                try alone.retireAll()
                trace.logits.merge(alone.trace.logits) { $1 }; trace.history.merge(alone.trace.history) { $1 }
            }
            return trace
        }
        var differing: [String] = []
        let members = lengths.keys.sorted()
        var soloOne = Trace(), longSolo = Trace(), reserved = 0
        if parts.contains(.rows) {
            soloOne = try solo(lanes: 1, members: members, lengths: lengths, steps: steps)
            differing += try solo(lanes: 8, members: members, lengths: lengths, steps: steps)
                .mismatches(soloOne, label: "P1 eight-lane vs one-lane host")

            // Rows 6 and 7 join before steps 3 and 5; row 1 leaves after step 6.
            let wide = try rows(8)
            for row in [0, 1, 2, 3, 4, 5] { try wide.open(row, length: lengths[row]!) }
            try wide.plainSteps(lengths: lengths, steps: steps + 5, schedule: { step in
                members.filter { row in
                    let first = row == 6 ? 3 : row == 7 ? 5 : 0
                    return step >= first && step - first < (row == 1 ? 7 : steps)
                }
            }, joins: [3: [6], 5: [7]], leaves: [6: [1]])
            try wide.retireAll()
            differing += wide.trace.mismatches(soloOne, label: "PB8 vs P1")
            for width in [2, 4] {
                let narrow = try rows(width)
                let cohort = Array(members.suffix(width))
                for row in cohort { try narrow.open(row, length: lengths[row]!) }
                try narrow.plainSteps(lengths: lengths, steps: steps, schedule: { _ in cohort })
                try narrow.retireAll()
                differing += narrow.trace.mismatches(soloOne, label: "PB\(width) vs P1")
            }
        }

        if parts.contains(.segments) {
            let long = longLengths.keys.sorted(), longSteps = 8
            longSolo = try solo(lanes: 1, members: long, lengths: longLengths, steps: longSteps)
            let spanning = try rows(8)
            for row in long { try spanning.open(row, length: longLengths[row]!) }
            reserved = spanning.host.backend.bytesReserved
            try spanning.plainSteps(lengths: longLengths, steps: longSteps, schedule: { _ in long })
            try spanning.retireAll()
            differing += spanning.trace.mismatches(longSolo, label: "PB8 across segments vs P1")
        }

        if parts.contains(.rows) {
            let windowed = [0, 2, 4, 7], columns = 4, rounds = 3
            let observer = try rows(windowed.count)
            for row in windowed { try observer.open(row, length: lengths[row]!) }
            try observer.plainSteps(lengths: lengths, steps: columns * rounds, schedule: { _ in windowed }, observing: true)
            try observer.retireAll()
            differing += observer.trace.mismatches(soloOne, label: "PB4 observed vs P1")
            for row in windowed {
                let single = try rows(1)
                try single.open(row, length: lengths[row]!)
                try single.windows([row], rounds: rounds, columns: columns)
                try single.retireAll()
                differing += single.trace.mismatches(soloOne, label: "W singleton vs P1")
                differing += single.trace.mismatches(observer.trace, label: "W singleton vs PB4 observed")
            }
            let cohort = try rows(windowed.count)
            for row in windowed { try cohort.open(row, length: lengths[row]!) }
            try cohort.windows(windowed, rounds: rounds, columns: columns)
            try cohort.retireAll()
            differing += cohort.trace.mismatches(soloOne, label: "W cohort vs P1")
            differing += cohort.trace.mismatches(observer.trace, label: "W cohort vs PB4 observed")
        }

        let compared = soloOne.logits.count + soloOne.history.count + longSolo.logits.count + longSolo.history.count
        var tampered = soloOne
        tampered.logits[Trace.key(0, 0)] = ""
        // A candidate's non-finite row differs from a finite reference or matches a marked one.
        let finite = !(soloOne.logits.values.contains { $0.hasPrefix(Rows.nonfinite) }
            || longSolo.logits.values.contains { $0.hasPrefix(Rows.nonfinite) })
        let rowsSound = !parts.contains(.rows) || (Set(soloOne.logits.values).count == soloOne.logits.count
            && soloOne.mismatches(soloOne, label: "").isEmpty && tampered.mismatches(soloOne, label: "").count == 1)
        let segmentsSound = !parts.contains(.segments) || reserved > CBv2StageKVHost.segmentBytes
        guard finite, rowsSound, segmentsSound else {
            throw ProbeError("Qwen TP rows check: non-finite or degenerate logits, rows within one KV segment or a blind comparison")
        }
        return Report(rank: rank, compared: compared, differing: differing, reservedBytesAcrossSegments: reserved,
            census: QwenTensorParallelBatchSession.censusLine(rank: rank, model: model),
            kernel: QwenTensorParallelBatchSession.kernelLine(rank: rank, plan: model.plan))
    }
}
