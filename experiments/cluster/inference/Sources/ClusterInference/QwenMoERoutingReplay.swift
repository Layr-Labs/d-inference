import Foundation
import MLX
import MLXNN

private struct QwenReplayReceipt: Decodable {
    let formatVersion: Int, kind: String, identity: [String: String]
    let hiddenSize: Int, numExperts: Int, topK: Int
    let normalizeTopKProbabilities: Bool, correctnessOnly: Bool
    let tokensPerLayer: Int, callsPerLayer: Int
    let events: [QwenReplayRecord]
}

private struct QwenReplayRecord: Decodable {
    let sequence: Int, path: String, layer: Int, call: Int, processedTokenStart: Int, rows: Int
    let inputShape: [Int], logitShape: [Int]
    let inputDType: String, logitDType: String, probabilityDType: String, routingWeightDType: String
    let inputSHA256: String, logitSHA256: String
    let inputs: [[Float]], logits: [[Float]]
}

/// Rebuild the original storage without GPU arithmetic. JSON's Float32 values
/// must round-trip to the recorded hash, and BF16 must require no rounding.
private func qwenReplayBytes(_ rows: [[Float]], width: Int, count: Int,
                             dtype: String, digest: String) throws -> Data {
    guard rows.count == count, rows.allSatisfy({ $0.count == width }),
        ["float32", "bfloat16"].contains(dtype) else { throw ProbeError("Invalid replay value geometry/dtype") }
    var data = Data()
    data.reserveCapacity(count * width * (dtype == "float32" ? 4 : 2))
    for value in rows.joined() {
        guard value.isFinite else { throw ProbeError("Replay contains nonfinite values") }
        let bits = value.bitPattern
        if dtype == "bfloat16" {
            guard bits & 0xffff == 0 else { throw ProbeError("Replay BF16 values require rounding") }
            data.append(UInt8(truncatingIfNeeded: bits >> 16))
            data.append(UInt8(truncatingIfNeeded: bits >> 24))
        } else {
            for shift in [0, 8, 16, 24] { data.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        }
    }
    guard sha256(data) == digest else { throw ProbeError("Replay values do not match their original-dtype SHA256") }
    return data
}

/// Diagnostic intervention: only router logits are replaced. Actual hidden
/// inputs still reach the routed/shared experts. No resulting timing, memory or
/// numerical result qualifies the ordinary inference path.
final class QwenMoERoutingReplay {
    let referenceSHA256: String
    private struct Event { let sequence: Int, rows: Int, dtype: DType, logits: MLXArray }
    private var events = [[Event]](repeating: [], count: 4)
    private var calls = [Int](repeating: 0, count: 4)
    private var completed = 0
    private var failure: String?

    fileprivate init(referenceURL: URL, expectedIdentity: [String: String]) throws {
        let file = try FileHandle(forReadingFrom: referenceURL)
        defer { try? file.close() }
        let limit = 32 * 1024 * 1024
        guard let data = try file.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else {
            throw ProbeError("Replay trace is empty or exceeds its 32MiB limit")
        }
        referenceSHA256 = sha256(data)
        let receipt = try JSONDecoder().decode(QwenReplayReceipt.self, from: data)
        let keys = Set(["syntheticProfile", "syntheticDType", "configurationSHA256", "promptSHA256",
                        "promptTokens", "teacherSHA256", "decodeInputsSHA256", "decodeTokens", "chunkSize", "seed"])
        let precisionKey = "attentionOutputPrecision"
        let precision = receipt.formatVersion == 1 ? "native" : receipt.identity[precisionKey]
        guard Set(expectedIdentity.keys) == keys.union([precisionKey]),
            keys.allSatisfy({ receipt.identity[$0] == expectedIdentity[$0] }),
            ["native", "float32"].contains(precision ?? ""), precision == expectedIdentity[precisionKey],
            receipt.formatVersion != 1 || receipt.identity[precisionKey] == nil,
            receipt.identity["syntheticProfile"] == "qwen-moe",
            ["float32", "bfloat16"].contains(receipt.identity["syntheticDType"] ?? ""),
            receipt.identity["rank"] == "0", receipt.identity["worldSize"] == "1",
            receipt.identity["partition"] == "none", receipt.identity["partitionPlanSHA256"] == "none",
            [1, 2].contains(receipt.formatVersion), receipt.kind == "qwen_moe_router_trace",
            receipt.hiddenSize == 128, receipt.numExperts == 16, receipt.topK == 4,
            receipt.normalizeTopKProbabilities, receipt.correctnessOnly else {
            throw ProbeError("Replay requires a matching bounded synthetic solo baseline identity")
        }
        for key in ["configurationSHA256", "promptSHA256", "teacherSHA256", "decodeInputsSHA256", "generatedTokensSHA256"] {
            guard let hash = receipt.identity[key], hash.count == 64,
                hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ProbeError("Replay identity omits a valid SHA256: \(key)")
            }
        }
        func integer(_ key: String, range: ClosedRange<Int>) throws -> Int {
            guard let raw = receipt.identity[key], let value = Int(raw), String(value) == raw,
                range.contains(value) else { throw ProbeError("Invalid replay workload integer: \(key)") }
            return value
        }
        let prompt = try integer("promptTokens", range: 1...512)
        let outputs = try integer("decodeTokens", range: 1...32)
        let chunk = try integer("chunkSize", range: 1...Int.max)
        guard let rawSeed = receipt.identity["seed"], let seed = UInt64(rawSeed), String(seed) == rawSeed else {
            throw ProbeError("Invalid replay seed")
        }
        let schedule = stride(from: 0, to: prompt, by: chunk).map { min(chunk, prompt - $0) }
            + Array(repeating: 1, count: outputs - 1)
        guard receipt.identity["teacherSHA256"] == receipt.identity["decodeInputsSHA256"],
            receipt.tokensPerLayer == prompt + outputs - 1, receipt.callsPerLayer == schedule.count,
            receipt.events.count == 4 * schedule.count else { throw ProbeError("Incomplete replay workload") }
        let dtype: DType = receipt.identity["syntheticDType"] == "bfloat16" ? .bfloat16 : .float32
        var starts = [Int](repeating: 0, count: 4)
        for (sequence, event) in receipt.events.enumerated() {
            let layer = sequence % 4, call = sequence / 4, rows = schedule[call]
            guard event.sequence == sequence, event.layer == layer, event.call == call,
                event.path == "model.layers.\(layer).mlp", event.rows == rows,
                event.processedTokenStart == starts[layer], event.inputShape == [1, rows, 128],
                event.logitShape == [1, rows, 16], event.inputDType == String(describing: dtype),
                event.logitDType == event.inputDType, event.probabilityDType == event.inputDType,
                event.routingWeightDType == event.inputDType else { throw ProbeError("Invalid replay event sequence/shape/dtype") }
            _ = try qwenReplayBytes(event.inputs, width: 128, count: rows,
                                   dtype: event.inputDType, digest: event.inputSHA256)
            let bytes = try qwenReplayBytes(event.logits, width: 16, count: rows,
                                           dtype: event.logitDType, digest: event.logitSHA256)
            events[layer].append(Event(sequence: sequence, rows: rows, dtype: dtype,
                                       logits: MLXArray(bytes, [1, rows, 16], dtype: dtype)))
            starts[layer] += rows
        }
    }

    fileprivate func next(_ input: MLXArray, layer: Int) -> MLXArray {
        let call = calls[layer]
        calls[layer] += 1; completed += 1
        if call < events[layer].count {
            let event = events[layer][call]
            if event.sequence != completed - 1 { failure = failure ?? "Replay forward order changed" }
            if input.shape == [1, event.rows, 128], input.dtype == event.dtype { return event.logits }
            failure = failure ?? "Replay input shape/dtype differs from the recorded call"
        } else { failure = failure ?? "Replay received an extra router call" }
        // Forward cannot throw. Preserve live row geometry so peers can finish
        // their collective schedule, then reject the entire run in validateComplete.
        return MLXArray.zeros(Array(input.shape.dropLast()) + [16], dtype: input.dtype)
    }

    func validateComplete() throws {
        guard failure == nil, completed == events.reduce(0, { $0 + $1.count }),
            (0..<4).allSatisfy({ calls[$0] == events[$0].count }) else {
            throw ProbeError(failure ?? "Replay did not consume every recorded router call")
        }
    }
}

private final class QwenReplayGate: QuantizedLinear {
    let replay: QwenMoERoutingReplay
    let layer: Int
    init(_ source: QuantizedLinear, replay: QwenMoERoutingReplay, layer: Int) {
        self.replay = replay; self.layer = layer
        super.init(weight: source.weight, scales: source.scales, biases: source.biases,
                   groupSize: source.groupSize, bits: source.bits, mode: source.mode)
    }
    override func callAsFunction(_ input: MLXArray) -> MLXArray { replay.next(input, layer: layer) }
}

/// expectedIdentity contains exactly the eleven shared workload/model keys checked
/// above. Attach before reductions; trace and replay are mutually exclusive.
func attachQwenMoERoutingReplay(model: Module, referenceURL: URL,
                              expectedIdentity: [String: String]) throws -> QwenMoERoutingReplay {
    let replay = try QwenMoERoutingReplay(referenceURL: referenceURL, expectedIdentity: expectedIdentity)
    let blocks = model.namedModules().filter { $0.0.hasSuffix(".mlp") }
    guard blocks.count == 4 else { throw ProbeError("Replay requires exactly four synthetic MoE layers") }
    var seen = Set<Int>(), replacements: [(Module, QwenReplayGate)] = []
    for (path, block) in blocks {
        let pieces = path.split(separator: ".")
        let fields = Mirror(reflecting: block).children
        guard pieces.count == 4, pieces[0] == "model", pieces[1] == "layers",
            let layer = Int(pieces[2]), (0..<4).contains(layer), seen.insert(layer).inserted,
            fields.first(where: { $0.label == "numExperts" })?.value as? Int == 16,
            fields.first(where: { $0.label == "topK" })?.value as? Int == 4,
            fields.first(where: { $0.label == "normTopkProb" })?.value as? Bool == true,
            let gate = block.namedModules().first(where: { $0.0 == "gate" })?.1 as? QuantizedLinear,
            ObjectIdentifier(type(of: gate)) == ObjectIdentifier(QuantizedLinear.self),
            gate.bias == nil, gate.mode == .affine, gate.bits == 4, gate.groupSize == 64,
            gate.weight.dtype == .uint32, gate.weight.shape == [16, 16],
            gate.scales.shape == [16, 2], gate.biases?.shape == [16, 2] else {
            throw ProbeError("Cannot replay the expected original Qwen MoE router at \(path)")
        }
        replacements.append((block, QwenReplayGate(gate, replay: replay, layer: layer)))
    }
    for (block, gate) in replacements {
        try block.update(modules: ModuleChildren(values: ["gate": .value(gate)]), verify: [.noUnusedKeys])
    }
    model.freeze()
    return replay
}
