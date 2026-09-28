import CryptoKit
import Foundation
import MLX
import MLXNN

/// A bounded diagnostic for the current four-layer, H128, E16/top4 synthetic
/// Qwen MoE fixture. Attach before reduction wrappers are installed. Captures
/// retain the original lazy arrays and never synchronize inside model forward.
final class QwenMoERouterTrace {
    fileprivate struct Event {
        let path: String
        let layer: Int
        let call: Int
        let input: MLXArray
        let logits: MLXArray
    }
    fileprivate var events: [Event] = []
    fileprivate var layerPaths: [Int: String] = [:]

    /// Call only after the single controlled-history execute has completed.
    /// Identity is supplied by the caller (rank, transport, partition, model and
    /// prompt/teacher identities). Values are copied verbatim into the receipt.
    /// Evaluation and retained graphs invalidate timing and memory measurements.
    func write(to url: URL, identity: [String: String]) throws {
        guard !events.isEmpty, events.count <= 4 * 543, layerPaths.count == 4 else {
            throw ProbeError("Router trace has no events or exceeds the bounded synthetic workload")
        }
        var processed: [Int: Int] = [:], calls: [Int: Int] = [:]
        var records: [QwenRoutingEventRecord] = []
        for (sequence, event) in events.enumerated() {
            guard event.path == layerPaths[event.layer],
                event.call == calls[event.layer, default: 0],
                event.input.ndim == 3, event.input.dim(0) == 1,
                event.input.dim(2) == 128 else {
                throw ProbeError("Unexpected router event path, call sequence or activation geometry")
            }
            let rows = event.input.dim(1), start = processed[event.layer, default: 0]
            guard rows > 0, start + rows <= 543 else {
                throw ProbeError("Router trace exceeds prompt<=512 plus at most31 teacher inputs")
            }
            let routes = try QwenStockRoutes(event)
            let inputs = event.input.asType(.float32).asArray(Float.self)
            guard inputs.allSatisfy(\.isFinite) else { throw ProbeError("Nonfinite router input") }
            let probabilities = routes.probabilities
            let logits = routes.logits
            var probabilityTies: [Int] = [], logitTies: [Int] = []
            var cutoff: [[Float]] = []
            for row in 0..<rows {
                let p = probabilities[row].sorted(by: >), l = logits[row].sorted(by: >)
                cutoff.append([p[3], p[4]])
                if p[3] == p[4] { probabilityTies.append(row) }
                if l[3] == l[4] { logitTies.append(row) }
            }
            records.append(QwenRoutingEventRecord(sequence: sequence, path: event.path,
                layer: event.layer, call: event.call, processedTokenStart: start, rows: rows,
                inputShape: event.input.shape, logitShape: event.logits.shape,
                inputDType: String(describing: event.input.dtype),
                logitDType: String(describing: event.logits.dtype),
                probabilityDType: routes.probabilityDType, routingWeightDType: routes.weightDType,
                inputSHA256: routingDigest(event.input), logitSHA256: routingDigest(event.logits),
                inputs: (0..<rows).map { Array(inputs[($0 * 128)..<(($0 + 1) * 128)]) },
                logits: logits, probabilities: probabilities, selectedExpertIDs: routes.ids,
                selectedExpertWeights: routes.weights, probabilityCutoff: cutoff,
                probabilityBoundaryTieTokens: probabilityTies, logitBoundaryTieTokens: logitTies))
            processed[event.layer] = start + rows; calls[event.layer] = event.call + 1
        }
        guard processed.count == 4, Set(processed.values).count == 1,
            Set(calls.values).count == 1 else {
            throw ProbeError("Router trace did not cover every layer with an identical token/call count")
        }
        let receipt = QwenRoutingReceipt(identity: identity, tokensPerLayer: processed[0]!,
            callsPerLayer: calls[0]!, events: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        try data.write(to: url, options: .withoutOverwriting)
    }
}

private func routingDigest(_ value: MLXArray) -> String {
    SHA256.hash(data: value.asData().data).map { String(format: "%02x", $0) }.joined()
}

private final class QwenRoutingCapture: QuantizedLinear {
    let trace: QwenMoERouterTrace
    let path: String
    let layer: Int
    private var calls = 0

    init(_ source: QuantizedLinear, trace: QwenMoERouterTrace, path: String, layer: Int) throws {
        guard source.bias == nil, source.bits == 4, source.groupSize == 64,
            source.mode == .affine, source.weight.shape == [16, 16],
            source.scales.shape == [16, 2], source.biases?.shape == [16, 2] else {
            throw ProbeError("Routing capture requires the fixture's unbiased H128/E16 W4/G64 affine router")
        }
        self.trace = trace; self.path = path; self.layer = layer
        super.init(weight: source.weight, scales: source.scales, biases: source.biases,
                   groupSize: source.groupSize, bits: source.bits, mode: source.mode)
    }

    override func callAsFunction(_ input: MLXArray) -> MLXArray {
        let output = super.callAsFunction(input)
        trace.events.append(.init(path: path, layer: layer, call: calls, input: input, logits: output))
        calls += 1
        return output
    }
}

/// Validate the actual private block's immutable routing policy through
/// reflection; no fields or numerical operations inside that block are changed.
/// The caller must additionally restrict usage to the synthetic qwen-moe profile.
func attachQwenMoERouterTrace(model: Module) throws -> QwenMoERouterTrace {
    let trace = QwenMoERouterTrace()
    let blocks = model.namedModules().filter { $0.0.hasSuffix(".mlp") }
    guard blocks.count == 4 else { throw ProbeError("Routing capture requires exactly four MoE layers") }
    // Validate all replacements first so an unsupported block cannot leave a
    // partially instrumented model behind.
    var replacements: [(Module, QwenRoutingCapture)] = []
    for (path, block) in blocks {
        let components = path.split(separator: ".")
        let fields = Mirror(reflecting: block).children
        guard let index = components.firstIndex(of: "layers"), index + 1 < components.count,
            let layer = Int(components[index + 1]), (0..<4).contains(layer),
            trace.layerPaths[layer] == nil,
            fields.first(where: { $0.label == "numExperts" })?.value as? Int == 16,
            fields.first(where: { $0.label == "topK" })?.value as? Int == 4,
            fields.first(where: { $0.label == "normTopkProb" })?.value as? Bool == true,
            let gate = block.namedModules().first(where: { $0.0 == "gate" })?.1 as? QuantizedLinear,
            !(gate is QwenRoutingCapture) else {
            throw ProbeError("Cannot capture the expected stock Qwen MoE routing policy at \(path)")
        }
        replacements.append((block, try QwenRoutingCapture(gate, trace: trace, path: path, layer: layer)))
        trace.layerPaths[layer] = path
    }
    for (block, capture) in replacements {
        try block.update(modules: ModuleChildren(values: ["gate": .value(capture)]), verify: [.noUnusedKeys])
    }
    model.freeze()
    return trace
}

private struct QwenStockRoutes {
    let ids: [[UInt32]]
    let weights: [[Float]]
    let probabilities: [[Float]]
    let logits: [[Float]]
    let probabilityDType: String
    let weightDType: String

    /// H128/E16/top4 cannot select the specialized H2048/E256/top8 router.
    /// Replay Qwen35SparseMoeBlock + qwen35A3BStockRoute exactly, including
    /// BF16 softmax, selected-sum, division and final input-dtype rounding.
    /// These are replayed private-route outputs, not intercepted private IDs.
    init(_ event: QwenMoERouterTrace.Event) throws {
        guard event.logits.shape == [1, event.input.dim(1), 16],
            [.float32, .bfloat16].contains(event.logits.dtype),
            event.logits.dtype == event.input.dtype else {
            throw ProbeError("Unexpected actual router geometry or dtype")
        }
        let rows = event.input.dim(1)
        let probabilities = MLX.softmax(event.logits, axis: -1, precise: true)
        let indices = MLX.argPartition(probabilities, kth: 12, axis: -1)[.ellipsis, 12...]
        var scores = MLX.takeAlong(probabilities, indices, axis: -1)
        scores = scores / scores.sum(axis: -1, keepDims: true)
        scores = scores.asType(event.input.dtype)
        guard probabilities.dtype == event.logits.dtype, scores.dtype == event.input.dtype else {
            throw ProbeError("Stock router replay unexpectedly changed intermediate dtypes")
        }
        let flatIDs = indices.asArray(UInt32.self)
        let flatScores = scores.asType(.float32).asArray(Float.self)
        let flatProbabilities = probabilities.asType(.float32).asArray(Float.self)
        let flatLogits = event.logits.asType(.float32).asArray(Float.self)
        guard flatIDs.allSatisfy({ $0 < 16 }), flatScores.allSatisfy(\.isFinite),
            flatProbabilities.allSatisfy(\.isFinite), flatLogits.allSatisfy(\.isFinite) else {
            throw ProbeError("Nonfinite router values or invalid global expert IDs")
        }
        func split<T>(_ values: [T], width: Int) -> [[T]] {
            (0..<rows).map { Array(values[($0 * width)..<(($0 + 1) * width)]) }
        }
        ids = split(flatIDs, width: 4); weights = split(flatScores, width: 4)
        self.probabilities = split(flatProbabilities, width: 16)
        logits = split(flatLogits, width: 16)
        probabilityDType = String(describing: probabilities.dtype)
        weightDType = String(describing: scores.dtype)
        guard ids.allSatisfy({ Set($0).count == 4 }) else { throw ProbeError("Router returned duplicate expert IDs") }
    }
}

private struct QwenRoutingEventRecord: Encodable {
    let sequence: Int
    let path: String
    let layer: Int
    let call: Int
    let processedTokenStart: Int
    let rows: Int
    let inputShape: [Int]
    let logitShape: [Int]
    let inputDType: String
    let logitDType: String
    let probabilityDType: String
    let routingWeightDType: String
    let inputSHA256: String
    let logitSHA256: String
    let inputs: [[Float]]
    let logits: [[Float]]
    let probabilities: [[Float]]
    let selectedExpertIDs: [[UInt32]]
    let selectedExpertWeights: [[Float]]
    /// Each row is [lowest selected probability, highest unselected probability].
    let probabilityCutoff: [[Float]]
    let probabilityBoundaryTieTokens: [Int]
    let logitBoundaryTieTokens: [Int]
}

private struct QwenRoutingReceipt: Encodable {
    let formatVersion = 2
    let kind = "qwen_moe_router_trace"
    let identity: [String: String]
    let hiddenSize = 128
    let numExperts = 16
    let topK = 4
    let normalizeTopKProbabilities = true
    let tokensPerLayer: Int
    let callsPerLayer: Int
    let events: [QwenRoutingEventRecord]
    let routingMethod = "exact stock public-MLX replay from captured logits; private IDs not intercepted"
    let capturedValues = "actual input/logits converted losslessly to Float32; hashes cover original dtype bytes"
    let tokenCoordinates = "processedTokenStart + row follows prompt chunks then teacher-forced decode inputs"
    let correctnessOnly = true
    let numericalQualification = "diagnostic-only; no broad numerical pass gate"
    let timingsAndMemoryInvalidatedByCapture = true
}
