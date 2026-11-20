import Foundation
import MLX
@_spi(ExpertParallel) import MLXLMCommon
import MLXNN

/// Whole-expert W4/G64 storage; neither projection's inner dimension is split.
struct ExpertAxisGeometry {
    let hidden: Int, intermediate: Int, experts: Int
    let metadataDType: DType
    static let names = ["down_proj", "gate_proj", "up_proj"].flatMap {
        projection in ["biases", "scales", "weight"].map { projection + "." + $0 }
    }

    init(hidden: Int, intermediate: Int, experts: Int, metadataDType: DType) throws {
        guard (64...2816).contains(hidden), hidden % 64 == 0,
              (64...704).contains(intermediate), intermediate % 64 == 0,
              (2...128).contains(experts), [.bfloat16, .float32].contains(metadataDType) else {
            throw ProbeError("Expert-axis check geometry/dtype is outside its explicit bounds")
        }
        self.hidden = hidden; self.intermediate = intermediate
        self.experts = experts; self.metadataDType = metadataDType
    }

    func shape(_ name: String) throws -> [Int] {
        guard Self.names.contains(name) else { throw ProbeError("Unknown expert-axis tensor") }
        let divisor = name.hasSuffix(".weight") ? 8 : 64
        return name.hasPrefix("down_proj.")
            ? [experts, hidden, intermediate / divisor]
            : [experts, intermediate, hidden / divisor]
    }
    func dtype(_ name: String) -> DType { name.hasSuffix(".weight") ? .uint32 : metadataDType }
}

/// Reuses the public quantized SwitchGLU implementation. The initializer's
/// random/quantization graphs are replaced before any model-parameter eval.
final class ExpertAxisBank {
    let geometry: ExpertAxisGeometry
    let globalExpertIDs: [Int]
    let module: SwitchGLU
    let loadedBytes: Int

    init(geometry: ExpertAxisGeometry, globalExpertIDs: [Int],
         read: (String, TensorSelection) throws -> MLXArray,
         check: () throws -> Void) throws {
        guard !globalExpertIDs.isEmpty, globalExpertIDs.count <= geometry.experts,
              globalExpertIDs == globalExpertIDs.sorted(), Set(globalExpertIDs).count == globalExpertIDs.count,
              globalExpertIDs.allSatisfy({ (0..<geometry.experts).contains($0) }) else {
            throw ProbeError("Expert-axis bank IDs must be increasing, unique and in range")
        }
        var ranges: [Range<Int>] = []
        for id in globalExpertIDs {
            if let last = ranges.last, last.upperBound == id {
                ranges[ranges.count - 1] = last.lowerBound..<(id + 1)
            } else { ranges.append(id..<(id + 1)) }
        }
        let selection = TensorSelection.axis(0, ranges)
        try check()
        let value = SwitchGLU(inputDims: geometry.hidden, hiddenDims: geometry.intermediate,
            numExperts: globalExpertIDs.count, activation: safeGeluApproximate,
            bias: false, fuseGateUp: false)
        try check()
        quantize(model: value, groupSize: 64, bits: 4, mode: .affine)
        try check()
        let expected = Dictionary(uniqueKeysWithValues: value.parameters().flattened().map { ($0.0, $0.1.shape) })
        guard Set(expected.keys) == Set(ExpertAxisGeometry.names) else {
            throw ProbeError("Constructed expert bank differs from split W4/G64 topology")
        }
        var bytes = 0
        for name in ExpertAxisGeometry.names {
            try check()
            let sourceShape = try geometry.shape(name)
            let array = try read(name, selection)
            try check()
            guard array.shape == expected[name], array.shape == (try selection.resultShape(sourceShape)),
                  array.dtype == geometry.dtype(name) else {
                throw ProbeError("Selected expert tensor shape/dtype differs: \(name)")
            }
            eval(array); try check()
            // Existing load-time ownership proof, never part of expert forward.
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
            let bound = try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)
            guard let storage = try array.evaluatedBufferInfo(), storage.isUnique,
                  storage.dataOffset == 0, storage.isRowContiguous, storage.dataElements == array.size,
                  storage.allocatedBytes >= array.nbytes, storage.allocatedBytes <= bound else {
                throw ProbeError("Selected expert tensor does not own compact storage: \(name)")
            }
            try check()
            try value.update(parameters: ModuleParameters.unflattened([name: array]),
                verify: [.noUnusedKeys, .shapeMismatch])
            bytes = try QwenLongPrefillCheckedBytes.sum([bytes, array.nbytes])
        }
        value.freeze(); eval(value); try check()
        self.geometry = geometry; self.globalExpertIDs = globalExpertIDs
        self.module = value; self.loadedBytes = bytes
    }

    /// Prepared/validated local IDs are owned by ExpertAxisPreparedDispatch.
    /// This graph construction does no CPU tensor read, eval, synchronization,
    /// normalization or host I/O. Empty local work is handled by the caller.
    func project(_ input: MLXArray, localIDs: MLXArray, policy: ExpertAxisProjectionPolicy) throws -> MLXArray {
        guard input.ndim == 2, input.dim(0) > 0, input.dim(1) == geometry.hidden,
              [.bfloat16, .float32].contains(input.dtype), localIDs.dtype == .uint32,
              localIDs.shape == [input.dim(0), 1], input.dim(0) == policy.executedAssignments,
              policy.localAssignments > 0, policy.globalExperts == geometry.experts,
              policy.ownedExperts == globalExpertIDs.count else {
            throw ProbeError("Expert-axis projection input contract differs")
        }
        let projected = module.callAsPartition(input, localIDs,
            sortAssignments: policy.sortAssignments, sortedProjection: policy.sortedProjection)
            .reshaped(input.dim(0), geometry.hidden)
        return policy.paddedAssignments == 0 ? projected : projected[..<policy.localAssignments, 0...]
    }
}
