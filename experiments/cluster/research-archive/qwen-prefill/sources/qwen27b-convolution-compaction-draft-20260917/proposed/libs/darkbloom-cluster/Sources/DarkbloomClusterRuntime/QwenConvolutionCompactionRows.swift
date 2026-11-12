import MLX
import MLXLMCommon

/// Mechanics shared with the model-free transaction fixture. Production reaches
/// this only through QwenConvolutionCompaction's actual profile/reservation join.
struct QwenConvolutionCompactionRows {
    let spec: CBv2RecurrentStateSpec
    let compactAllocationBound: Int
    let compactThreeGenerationBytes: Int
    let namedConvolutionBytes: Int
    private let localLayerCount: Int

    init(rank: Int, bound: (Int) throws -> Int) throws {
        guard (0...1).contains(rank) else { throw ProbeError("Invalid convolution compaction rank") }
        let registered = QwenDenseRegisteredSpecification.all.first { $0.model == .qwen38TwentySevenB }!
        let g = try registered.expectedGeometry()
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        localLayerCount = rank == 0 ? 16 : 48
        let indices = (0..<localLayerCount).filter { ($0 + 1) % g.fullAttentionInterval != 0 }
        let channels = try sum([product([2, g.linearKeyHeads, g.linearKeyDimension]),
                                product([g.linearValueHeads, g.linearValueDimension])])
        let convShape = [1, g.convolutionKernel - 1, channels]
        let logicalBF16 = try product(convShape + [2]), logicalF32 = try product(convShape + [4])
        let compactBound = try bound(logicalBF16), namedBound = try bound(logicalF32)
        guard compactBound >= logicalBF16, namedBound >= logicalF32 else {
            throw ProbeError("Invalid convolution allocator bound")
        }
        compactAllocationBound = compactBound
        compactThreeGenerationBytes = try product([3, indices.count, compactBound])
        // This is exactly the existing allowance(b.convolutionBytesPerLayer,
        // 3 * b.recurrentLayers) term. No SSM/KV/fusion/workspace is repurposed.
        namedConvolutionBytes = try product([3, g.layers - g.layers / g.fullAttentionInterval, namedBound])
        guard compactThreeGenerationBytes <= namedConvolutionBytes else {
            throw ProbeError("Compact convolution generations exceed their existing named allowance")
        }
        spec = .init(layers: indices.map {
            .init(modelLayerIndex: $0, convShape: convShape, convDType: .bfloat16,
                  ssmShape: [1, g.linearValueHeads, g.linearValueDimension, g.linearKeyDimension],
                  ssmDType: .float32)
        })
    }

    func require(_ geometry: CBv2RequestGeometry) throws {
        guard geometry.recurrent == spec, geometry.kvDType == .bfloat16,
              geometry.kinds.count == localLayerCount / 4,
              geometry.kinds.enumerated().allSatisfy({ index, kind in
                  kind.modelLayerIndex == index * 4 + 3 && kind.kvHeads == 4
                      && kind.queryHeads == 24 && kind.headDim == 256
              }) else {
            throw ProbeError("Convolution compaction differs from actual local state geometry")
        }
    }

    /// All semantic guards and all lazy copy construction precede any wrapper
    /// mutation. No array data is read and no graph is evaluated here.
    func stage(owner: CBv2RecurrentRequestState, evaluation: CBv2RecurrentStateEvaluation,
               roots: [MLXArray], check: () throws -> Void) throws {
        try check()
        let confirmed = owner.confirmedStateSnapshot()
        let indices = spec.modelLayerIndices
        guard !evaluation.isCaptured, !owner.isReleased, owner.spec == spec,
              roots.count == 2 * indices.count,
              confirmed == nil || Set(confirmed!.keys) == Set(indices),
              owner.materializedByteCount == (try QwenLongPrefillCheckedBytes.product([
                  owner.byteCount, confirmed == nil ? 1 : 2])) else {
            throw ProbeError("Convolution compaction requires exactly one plain pending generation")
        }
        var forbidden = Set<ObjectIdentifier>()
        var pending = [MLXArray]()
        pending.reserveCapacity(indices.count)
        for (position, layer) in spec.layers.enumerated() {
            let index = layer.modelLayerIndex
            let input = evaluation.inputState(modelLayerIndex: index)
            if let committed = confirmed?[index] {
                guard let a = input?.conv, let b = input?.ssm,
                      let oldConv = committed.conv, let oldSSM = committed.ssm,
                      a === oldConv, b === oldSSM else {
                    throw ProbeError("Convolution input is not the confirmed plain generation")
                }
            } else if input != nil {
                throw ProbeError("Convolution first generation has an unconfirmed input")
            }
            for state in [input, confirmed?[index]].compactMap({ $0 }) {
                guard let conv = state.conv, let ssm = state.ssm,
                      conv.shape == layer.convShape, conv.dtype == layer.convDType,
                      ssm.shape == layer.ssmShape, ssm.dtype == layer.ssmDType else {
                    throw ProbeError("Convolution input/confirmed geometry differs")
                }
                forbidden.insert(ObjectIdentifier(conv)); forbidden.insert(ObjectIdentifier(ssm))
            }
            guard let state = owner.state(modelLayerIndex: index),
                  let conv = state.conv, let ssm = state.ssm,
                  conv.shape == layer.convShape, conv.dtype == layer.convDType,
                  ssm.shape == layer.ssmShape, ssm.dtype == layer.ssmDType,
                  roots[2 * position] === conv, roots[2 * position + 1] === ssm else {
                throw ProbeError("Convolution pending roots or geometry differ")
            }
            forbidden.insert(ObjectIdentifier(ssm)); pending.append(conv)
        }
        let pendingIDs = pending.map(ObjectIdentifier.init)
        guard Set(pendingIDs).count == indices.count,
              Set(pendingIDs).isDisjoint(with: forbidden) else {
            throw ProbeError("Convolution pending wrapper aliases input, confirmed state or another component")
        }
        let compact = pending.map { $0.contiguous() }
        try check()
        guard zip(pending, compact).allSatisfy({ pair in
            pair.0.shape == pair.1.shape && pair.0.dtype == pair.1.dtype
        }) else {
            throw ProbeError("Convolution copy changed its logical geometry")
        }
        for (target, replacement) in zip(pending, compact) { target._updateInternal(replacement) }
        // A failure now is still pending-only. The existing owner catch marks
        // failed; existing retirement synchronizes and rolls back, never reuses.
        try check()
    }

    /// Nonblocking metadata only, after the one existing joint eval. Do not
    /// require unique=true: Metal completion handlers can still hold references.
    func requireEvaluated(_ owner: CBv2RecurrentRequestState) throws {
        for layer in spec.layers {
            guard let conv = owner.state(modelLayerIndex: layer.modelLayerIndex)?.conv,
                  conv.shape == layer.convShape, conv.dtype == layer.convDType,
                  let buffer = try conv.evaluatedBufferInfo(), buffer.dataOffset == 0,
                  buffer.dataElements == conv.size, buffer.isRowContiguous,
                  buffer.allocatedBytes >= conv.nbytes, buffer.allocatedBytes <= compactAllocationBound else {
                throw ProbeError("Evaluated convolution tail is not independently bounded compact storage")
            }
        }
    }
}
