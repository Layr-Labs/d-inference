import Foundation
import MLX
import MLXNN

private struct GemmaBoundaryRecord: Encodable {
    let path: String
    let stage: String
    let call: Int
    let tokenStart: Int
    let shape: [Int]
    let dtype: String
    let nativeSHA256: String
    let values: [Float]
    let replayedExpertIDs: [UInt32]?
}

/// Only bounded synthetic diagnostics may retain these intermediates. Every
/// explicit chunk evaluates full logits and pending captures before draining;
/// no lazy capture from a pruned prepare graph is evaluated after the request.
final class GemmaBoundaryTrace {
    private struct Pending { let path: String; let stage: String; let value: MLXArray }
    private var pending: [Pending] = []
    private var records: [GemmaBoundaryRecord] = []
    private var calls: [String: Int] = [:]
    private var tokens: [String: Int] = [:]
    private var valueCount = 0

    var pendingArrays: [MLXArray] { pending.map(\.value) }

    func record(_ path: String, _ stage: String, _ value: MLXArray) {
        precondition(pending.count < 96, "Gemma capture exceeds one bounded forward")
        pending.append(Pending(path: path, stage: stage, value: value))
    }

    func drain() throws {
        guard !pending.isEmpty else { throw ProbeError("Gemma diagnostic forward captured no boundaries") }
        for event in pending {
            let value = event.value
            guard value.ndim == 3, value.dim(0) == 1, (1...128).contains(value.dim(1)),
                [4, 128].contains(value.dim(2)), [.float32, .bfloat16].contains(value.dtype),
                try value.evaluatedBufferInfo() != nil else {
                throw ProbeError("Gemma capture has unsupported geometry/dtype or was not evaluated")
            }
            let key = event.path + ":" + event.stage
            let start = tokens[key, default: 0], call = calls[key, default: 0]
            guard start + value.dim(1) <= 143, valueCount + value.size <= 4_000_000 else {
                throw ProbeError("Gemma boundary capture exceeds its synthetic workload bound")
            }
            let values = value.asType(.float32).asArray(Float.self)
            guard values.allSatisfy(\.isFinite) else { throw ProbeError("Nonfinite Gemma capture") }
            let ids: [UInt32]?
            if event.stage == "router.logits" {
                guard value.dim(2) == 4 else { throw ProbeError("Gemma router capture requires E4/top2") }
                // Same stock selection operation on captured logits. These are
                // reconstructed IDs, not intercepted private router outputs.
                ids = argPartition(value, kth: 2, axis: -1)[.ellipsis, 2...].asArray(UInt32.self)
            } else { ids = nil }
            records.append(GemmaBoundaryRecord(path: event.path, stage: event.stage, call: call,
                tokenStart: start, shape: value.shape, dtype: String(describing: value.dtype),
                nativeSHA256: sha256(value.asData().data), values: values, replayedExpertIDs: ids))
            calls[key] = call + 1; tokens[key] = start + value.dim(1); valueCount += value.size
        }
        pending.removeAll(keepingCapacity: true)
    }

    func write(to url: URL, identity: [String: String], expectedTokens: Int) throws {
        guard pending.isEmpty, !records.isEmpty, Set(tokens.values) == [expectedTokens] else {
            throw ProbeError("Gemma capture was not drained or has inconsistent token coverage")
        }
        struct Receipt: Encodable {
            let schemaVersion = 1
            let correctnessOnly = true
            let evaluationSchedule = "explicit-chunks-full-logits-and-captures"
            let routerIDsAreReplayed = true
            let identity: [String: String]
            let tokensPerBoundary: Int
            let records: [GemmaBoundaryRecord]
        }
        try canonicalJSONData(Receipt(identity: identity, tokensPerBoundary: expectedTokens,
                                      records: records)).write(to: url, options: .withoutOverwriting)
    }
}

private final class GemmaRouterCapture: QuantizedLinear {
    let trace: GemmaBoundaryTrace
    let path: String

    init(_ source: QuantizedLinear, path: String, trace: GemmaBoundaryTrace) throws {
        guard source.bias == nil, source.mode == .affine, [4, 8].contains(source.bits),
            source.groupSize == 64, source.shape == (4, 128) else {
            throw ProbeError("Gemma capture requires an unbiased E4/H128 affine router")
        }
        self.trace = trace; self.path = path
        super.init(weight: source.weight, scales: source.scales, biases: source.biases,
                   groupSize: source.groupSize, bits: source.bits, mode: source.mode)
    }

    override func callAsFunction(_ input: MLXArray) -> MLXArray {
        let output = super.callAsFunction(input)
        trace.record(path, "router.input", input)
        trace.record(path, "router.logits", output)
        return output
    }
}

func attachGemmaRouterCapture(model: Module, trace: GemmaBoundaryTrace) throws {
    let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
    let routers = modules.filter { $0.key.hasSuffix(".router.proj") }
    guard routers.count == 4 else { throw ProbeError("Gemma capture requires four router modules") }
    for (path, module) in routers {
        let parentPath = path.split(separator: ".").dropLast().joined(separator: ".")
        guard let parent = modules[parentPath], let router = module as? QuantizedLinear else {
            throw ProbeError("Gemma capture requires quantized routers")
        }
        try parent.update(modules: ModuleChildren(values: ["proj":
            .value(try GemmaRouterCapture(router, path: path, trace: trace))]), verify: [.noUnusedKeys])
    }
    model.freeze()
}
