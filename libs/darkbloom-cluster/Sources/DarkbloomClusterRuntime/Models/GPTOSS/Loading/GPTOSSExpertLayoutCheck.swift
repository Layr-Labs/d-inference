import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// One Mac, the real artifact, no model and no collective: are the experts as
/// a stage holds them (the stored gate and up projections, separate) the same
/// arithmetic as the product's load-time layout (gate and up concatenated
/// along the output rows into one projection, whose output is then halved)?
///
/// For each chosen layer it reads the layer's stored gate and up tensors,
/// builds both layouts over those exact bytes with the product's own routed
/// projection class, runs the same inputs and routes through both, and
/// compares the outputs byte for byte: one routed step as decode issues it,
/// and a prompt chunk as prefill issues it (routes sorted by expert). Inputs
/// are seeded random activations in the model's dtype; this compares two
/// layouts of one kernel, it is not a model evaluation.
public enum GPTOSSExpertLayoutCheck {
    public struct Comparison: Encodable, Sendable {
        public let layer: Int
        /// `decode` (one position, four routes) or `prefill` (a chunk, routes sorted by expert).
        public let shape: String
        public let positions: Int
        public let outputDType: String
        public let elementsPerHalf: Int
        public let gateBitIdentical: Bool
        public let upBitIdentical: Bool
        public let gateDifferingElements: Int
        public let upDifferingElements: Int
        public let maximumAbsoluteDifference: Float
        public let splitGateSHA256: String
        public let fusedGateSHA256: String
        public let splitUpSHA256: String
        public let fusedUpSHA256: String
    }
    public struct Report: Encodable, Sendable {
        public let schema = "gpt_oss_expert_layout_check_v1"
        public let runtimeModelID: String
        public let verifiedAggregateSHA256: String
        public let quantization: String
        public let seed: UInt64
        public let comparisons: [Comparison]
        public let everyOutputBitIdentical: Bool
        public let activeBytesAfterRelease: Int
    }

    public static func run(modelDirectory: URL, layers: [Int], chunkTokens: Int = 512, seed: UInt64 = 20_261_009,
                           deadlineUptimeNanoseconds: UInt64) throws -> Report {
        let configuration = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
                                                      maximumBytes: 1_048_576)
        let manifest = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"),
                                                 maximumBytes: 4_194_304)
        let spec = try GPTOSSRegisteredSpecification.specification(configuration: configuration)
        // Admitted before any model construction, as every other entry does.
        _ = try GPTOSSArithmeticEnvironment.admit(ProcessInfo.processInfo.environment)
        let plan = try GPTOSSLayerStagePlan(configuration: configuration, cut: spec.supportedCuts[0])
        guard !layers.isEmpty, layers.count <= spec.layers, Set(layers).count == layers.count,
              layers.allSatisfy({ (0..<spec.layers).contains($0) }),
              (64...GPTOSSRegisteredSpecification.maximumChunkTokens).contains(chunkTokens) else {
            throw ProbeError("Expert layout check needs distinct layer indices of the model and a chunk of 64...512 tokens")
        }
        let control = QwenResidentControl(deadline: deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        defer { QwenResidentProcessLease.shared.release() }
        try QwenResidentResourceEnvironment.require()
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
            var comparisons: [Comparison] = []
            var aggregate = ""
            try autoreleasepool {
                let source = try prepareGPTOSSResidentSource(directory: modelDirectory, configuration: configuration,
                    manifest: manifest, specification: spec, plan: plan, check: checked)
                aggregate = source.checkpoint.aggregate
                let policy = GPTOSSStageMetadata.Policy.experts
                guard let mode = QuantizationMode(rawValue: policy.mode) else { throw ProbeError("Unknown expert quantization mode") }
                for layer in layers {
                    try autoreleasepool {
                        let base = GPTOSSLayerStagePlan.layerPrefix + "\(layer).mlp.experts."
                        func stored(_ name: String) throws -> MLXArray {
                            guard let descriptor = source.descriptors[base + name] else {
                                throw ProbeError("Stored expert tensor is missing: \(base + name)")
                            }
                            let array = try descriptor.read(.all).array
                            eval(array); try checked()
                            return array
                        }
                        func projection(outputs: Int, weight: MLXArray, scales: MLXArray, bias: MLXArray) throws -> QuantizedSwitchLinear {
                            let module = try withRandomState(MLXRandom.RandomState(seed: 7)) {
                                QuantizedSwitchLinear(SwitchLinear(inputDims: spec.hidden, outputDims: outputs,
                                    numExperts: spec.experts, bias: true),
                                    groupSize: policy.groupSize, bits: policy.bits, mode: mode)
                            }
                            try module.update(parameters: ModuleParameters.unflattened([
                                "weight": weight, "scales": scales, "bias": bias]), verify: [.noUnusedKeys, .shapeMismatch])
                            return module
                        }
                        let gateWeight = try stored("gate_proj.weight"), gateScales = try stored("gate_proj.scales")
                        let gateBias = try stored("gate_proj.bias")
                        let upWeight = try stored("up_proj.weight"), upScales = try stored("up_proj.scales")
                        let upBias = try stored("up_proj.bias")
                        let gate = try projection(outputs: spec.intermediate, weight: gateWeight, scales: gateScales, bias: gateBias)
                        let up = try projection(outputs: spec.intermediate, weight: upWeight, scales: upScales, bias: upBias)
                        // The product's fusion: packed rows concatenated, gate first.
                        let fused = try projection(outputs: spec.intermediate * 2,
                            weight: concatenated([gateWeight, upWeight], axis: -2),
                            scales: concatenated([gateScales, upScales], axis: -2),
                            bias: concatenated([gateBias, upBias], axis: -1))
                        for (shape, positions) in [("decode", 1), ("prefill", chunkTokens)] {
                            try autoreleasepool {
                                let key = MLXRandom.key(seed &+ UInt64(layer * 1000 + positions))
                                let activations = MLXRandom.normal([1, positions, spec.hidden], key: key).asType(.bfloat16)
                                // Four distinct experts per position, from a fixed sequence.
                                var state = seed &+ UInt64(layer) &* 0x9E37_79B9_7F4A_7C15
                                var routes: [Int32] = []
                                for _ in 0..<positions {
                                    var chosen: [Int32] = []
                                    while chosen.count < spec.expertsPerToken {
                                        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                                        let expert = Int32((state >> 33) % UInt64(spec.experts))
                                        if !chosen.contains(expert) { chosen.append(expert) }
                                    }
                                    routes += chosen
                                }
                                let indices = MLXArray(routes).reshaped([1, positions, spec.expertsPerToken])
                                // The product class's own preparation of a routed call.
                                var x = MLX.expandedDimensions(activations, axes: [-2, -3])
                                var routed = indices
                                let sorted = indices.size >= 64
                                if sorted { (x, routed, _) = gatherSort(x: x, indices: indices) }
                                let splitUp = up(x, routed, sortedIndices: sorted)
                                let splitGate = gate(x, routed, sortedIndices: sorted)
                                let projected = fused(x, routed, sortedIndices: sorted)
                                let fusedGate = projected[.ellipsis, ..<spec.intermediate]
                                let fusedUp = projected[.ellipsis, spec.intermediate...]
                                eval(splitUp, splitGate, fusedGate, fusedUp); try checked()
                                Stream.gpu.synchronize()
                                guard splitGate.shape == fusedGate.shape, splitUp.shape == fusedUp.shape,
                                      splitGate.dtype == fusedGate.dtype, splitUp.dtype == fusedUp.dtype else {
                                    throw ProbeError("Split and fused expert outputs differ in shape or dtype")
                                }
                                func differing(_ a: MLXArray, _ b: MLXArray) -> (count: Int, maximum: Float) {
                                    let difference = abs(a.asType(.float32) - b.asType(.float32))
                                    return ((a .!= b).asType(.int32).sum().item(Int.self), difference.max().item(Float.self))
                                }
                                let gateBytes = [splitGate.asData().data, fusedGate.asData().data]
                                let upBytes = [splitUp.asData().data, fusedUp.asData().data]
                                try checked()
                                let gateDifference = differing(splitGate, fusedGate), upDifference = differing(splitUp, fusedUp)
                                try checked()
                                comparisons.append(.init(layer: layer, shape: shape, positions: positions,
                                    outputDType: String(describing: splitGate.dtype), elementsPerHalf: splitGate.size,
                                    gateBitIdentical: gateBytes[0] == gateBytes[1], upBitIdentical: upBytes[0] == upBytes[1],
                                    gateDifferingElements: gateDifference.count, upDifferingElements: upDifference.count,
                                    maximumAbsoluteDifference: max(gateDifference.maximum, upDifference.maximum),
                                    splitGateSHA256: sha256(gateBytes[0]), fusedGateSHA256: sha256(gateBytes[1]),
                                    splitUpSHA256: sha256(upBytes[0]), fusedUpSHA256: sha256(upBytes[1])))
                            }
                        }
                    }
                }
            }
            Stream.gpu.synchronize(); Stream.cpu.synchronize()
            Memory.clearCache(); try nativeError.check()
            return Report(runtimeModelID: spec.model.rawValue, verifiedAggregateSHA256: aggregate,
                quantization: "\(GPTOSSStageMetadata.Policy.experts.mode) bits=\(GPTOSSStageMetadata.Policy.experts.bits) group=\(GPTOSSStageMetadata.Policy.experts.groupSize)",
                seed: seed, comparisons: comparisons,
                everyOutputBitIdentical: comparisons.allSatisfy { $0.gateBitIdentical && $0.upBitIdentical },
                activeBytesAfterRelease: Memory.snapshot().activeMemory)
        }
    }
}
