import Foundation
import MLX
import MLXLLM
@_spi(QuantizedProjectionScope) import MLXNN

/// Private model experiment. Only a fresh original target-resource observation
/// with the additional serial-head allowance can construct this adapter. It
/// owns no model, request, cache, allocator or transport lifetime.
final class Gemma4MTPDenseProjection {
    static let policy = "gemma4_verification_packed_m1_dense_serial_head_v1"
    static let packedHeadPolicy = "gemma4_verification_packed_m1_dense_packed_head_v1"
    enum HeadPolicy: Equatable { case serialM1, packedM1 }
    private let headPolicy: HeadPolicy
    var activePolicy: String { headPolicy == .serialM1 ? Self.policy : Self.packedHeadPolicy }
    struct Summary: Encodable {
        let policy: String
        let expectedDenseModules: Int
        let expectedTiedHeads = 1
        let serialHeadLogicalBytes = 4 * 1_048_576
        let gatheredOverrideEnabled = false
        let singleRowOverrideEnabled = false
        let wholeModelNumericsQualified = false
    }
    private let resources: Gemma4MTPRemoteTargetResources
    private let denseModules: Set<ObjectIdentifier>
    private let tiedHead: ObjectIdentifier
    var summary: Summary { .init(policy: activePolicy, expectedDenseModules: denseModules.count) }

    init(model: Gemma4Model, resources: Gemma4MTPRemoteTargetResources,
         headPolicy: HeadPolicy = .serialM1) throws {
        try resources.requireSerialTargetHead()
        self.headPolicy = headPolicy
        let leaves = model.textModel.leafModules().flattened().map { $0.1 }
        let dense = leaves.compactMap { $0 as? QuantizedLinear }
        let heads = leaves.compactMap { $0 as? QuantizedEmbedding }
        guard !dense.isEmpty, heads.count == 1 else {
            throw ProbeError("Dense verification scope requires actual quantized target modules and one tied head")
        }
        self.resources = resources
        denseModules = Set(dense.map(ObjectIdentifier.init))
        tiedHead = ObjectIdentifier(heads[0])
        guard denseModules.count == dense.count else { throw ProbeError("Dense verification module identity repeats") }
    }

    /// Called ONLY inside the original verification's synchronous `forward`
    /// closure. Its cache/root evaluation and guards run after this scope ends.
    func graph<Result>(width: Int, body: () throws -> Result) throws -> Result {
        // No traversal, cast, reshape, handler lookup or arithmetic change at M1.
        if width == 1 { return try body() }
        guard (2...3).contains(width) else { throw ProbeError("Dense verification scope requires width2 or3") }
        try resources.requireSerialTargetHead()
        var seen: Set<ObjectIdentifier> = []
        let result = try QuantizedProjectionScope.withHandler({ request in
            guard seen.insert(request.module).inserted,
                  request.input.shape.count == 3,
                  request.input.dim(0) == 1, request.input.dim(1) == width,
                  request.mode == .affine, request.groupSize == 64,
                  let biases = request.biases,
                  [.bfloat16, .float32].contains(request.input.dtype),
                  request.weight.dtype == .uint32, request.weight.ndim == 2,
                  request.scales.ndim == 2, biases.ndim == 2 else {
                throw ProbeError("Dense verification projection invocation differs or repeats")
            }
            let k = request.input.dim(2)
            let input = request.input.reshaped([width,k])
            switch request.kind {
            case .linear:
                guard self.denseModules.contains(request.module),
                      let geometry = GemmaSmallDenseQMV.geometries.first(where: {
                          $0.k == k && $0.n == request.weight.dim(0) && $0.bits == request.bits
                      }) else { throw ProbeError("Dense verification has an unqualified linear geometry") }
                // The original QuantizedLinear applied its constant scale and
                // offset casts BEFORE this hook; its external bias remains AFTER.
                return try GemmaSmallDenseQMV.project(input, weight: request.weight,
                    scales: request.scales, biases: biases, geometry: geometry)
                    .reshaped([1,width,geometry.n])
            case .embeddingHead:
                guard request.module == self.tiedHead, k == 2816, request.bits == 4,
                      request.weight.shape == [262_144,352],
                      request.scales.shape == [262_144,44], biases.shape == request.scales.shape,
                      request.scales.dtype == .bfloat16, biases.dtype == .bfloat16 else {
                    throw ProbeError("Dense verification tied head differs from registered geometry")
                }
                // Head N262144 was not a primitive qualifier geometry. Preserve
                // ordinary M1 quantizedMM including its original dtype promotion.
                // Four separately rounded F32 rows cover these live partials;
                // concatenation uses the existing width-four output workset.
                // Native affine QMM promotes input with scale/bias dtype.
                // This closed BF16-metadata + BF16/F32-input domain promotes
                // exactly to input.dtype. Hoist ONE identical cast pair so
                // row calls share the original budget's headCast roots rather
                // than creating width copies of each 262144x44 F32 array.
                let headScales = request.scales.asType(input.dtype)
                let headBiases = biases.asType(input.dtype)
                if self.headPolicy == .packedM1 {
                    // Keep every original head/cast/partial-row reservation.
                    // Only this separately named experiment changes projection.
                    return try GemmaSmallDenseQMV.projectRegisteredTiedHead(input,
                        weight: request.weight, scales: headScales, biases: headBiases)
                        .reshaped([1,width,262_144])
                }
                let rows = (0..<width).map { index in
                    quantizedMM(input[index..<(index+1),0...], request.weight,
                        scales: headScales, biases: headBiases, transpose: true,
                        groupSize: request.groupSize, bits: request.bits, mode: request.mode)
                }
                return concatenated(rows, axis: 0).reshaped([1,width,262_144])
            }
        }, body: body)
        guard seen == denseModules.union([tiedHead]) else {
            throw ProbeError("Dense verification graph bypassed an expected target projection")
        }
        try resources.requireSerialTargetHead()
        return result
    }
}
