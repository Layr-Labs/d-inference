import Foundation

/// The named storage of one request on the registered Gemma 4 26B geometry, in
/// logical bytes. Either rank is charged the whole model's state, as the
/// registered Qwen allowance charges it: a conservative ledger of named arrays,
/// not a whole-process peak.
struct Gemma4StateBudget: Equatable {
    let maximumTokens: Int, chunkSize: Int
    let fullLayers: Int, slidingLayers: Int
    /// Keys or values of one full-attention layer at the request's capacity.
    let fullKVBytes: Int
    /// Keys or values of one sliding layer's ring, allocated whole at first write.
    let ringKVBytes: Int
    /// Keys or values one sliding layer attends over during a prompt chunk: the
    /// history the ring is about to overwrite, then the chunk.
    let slidingViewKVBytes: Int
    /// One chunk of residual rows.
    let boundaryBytes: Int
    /// One vocabulary row of float32 logits.
    let logitsBytes: Int
    let largestSingleHostStateComponentBytes: Int
    let stateAndBoundaryBytes: Int

    static func estimate(maximumTokens: Int, chunkSize: Int) throws -> Self {
        guard (1...32_768).contains(maximumTokens), (1...512).contains(chunkSize) else {
            throw ProbeError("Gemma state budget requires bounded tokens and chunk")
        }
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let layers = Gemma4StageGeometry.layerCount
        let full = layers / Gemma4StageGeometry.fullAttentionInterval, sliding = layers - full
        let elementBytes = 2
        let fullKV = try product([maximumTokens, Gemma4StageGeometry.fullKVHeads,
                                  Gemma4StageGeometry.fullHeadDimension, elementBytes])
        let slidingRow = try product([Gemma4StageGeometry.slidingKVHeads,
                                      Gemma4StageGeometry.slidingHeadDimension, elementBytes])
        let ring = try product([Gemma4StageGeometry.slidingWindow, slidingRow])
        let view = try product([Gemma4StageGeometry.slidingWindow - 1 + chunkSize, slidingRow])
        let boundary = try product([chunkSize, Gemma4StageGeometry.hiddenSize, elementBytes])
        let logits = try product([Gemma4StageGeometry.vocabularySize, 4])
        let total = try sum([product([2, full, fullKV]), product([2, sliding, ring]),
            product([2, sliding, view]), product([4, layers]), max(fullKV, ring),
            product([2, boundary]), product([2, logits])])
        return .init(maximumTokens: maximumTokens, chunkSize: chunkSize, fullLayers: full, slidingLayers: sliding,
            fullKVBytes: fullKV, ringKVBytes: ring, slidingViewKVBytes: view, boundaryBytes: boundary,
            logitsBytes: logits, largestSingleHostStateComponentBytes: max(fullKV, ring),
            stateAndBoundaryBytes: total)
    }

    /// The same ledger with every named array at the allocator's own bound.
    func allowance(bound: (Int) throws -> Int) throws -> QwenResidentRequestAllowance {
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func charge(_ bytes: Int, _ count: Int) throws -> Int {
            let rounded = try bound(bytes)
            guard bytes > 0, rounded >= bytes else { throw ProbeError("Resident allocator bound is invalid") }
            return try product([rounded, count])
        }
        let layers = fullLayers + slidingLayers
        let state = try sum([charge(fullKVBytes, 2 * fullLayers), charge(ringKVBytes, 2 * slidingLayers),
            charge(slidingViewKVBytes, 2 * slidingLayers), charge(4, layers),
            charge(largestSingleHostStateComponentBytes, 1), charge(boundaryBytes, 2), charge(logitsBytes, 2)])
        return .init(stateBytes: state, fusionBytes: 0, reservedBytes: state)
    }
}

/// Byte ceilings of the registered Gemma resident scope. A ceiling is a refusal
/// bound, not a memory grant or a fit on any Mac; the live gates stay in force.
struct Gemma4ResidentResourceCeilings: Equatable {
    /// The resident profile's largest request: 8,192 prompt plus 128 output
    /// tokens, prefilled in chunks of at most 512.
    static let maximumContextTokens = 8320
    static let maximumChunkTokens = 512
    /// The ledger at that request, recomputed from the geometry and required to
    /// equal this independently pinned integer.
    static let pinnedMaximumNamedStateBytes = 719_380_600

    /// Largest manifest payload the verified loader will hash for this model:
    /// the registered manifest total itself.
    let maximumManifestPayloadBytes: Int
    let namedStateByteCeiling: Int
    let maximumNamedStateBytes: Int

    init(specification: Gemma4RegisteredSpecification) throws {
        maximumManifestPayloadBytes = specification.manifestBytes
        namedStateByteCeiling = Self.pinnedMaximumNamedStateBytes
        maximumNamedStateBytes = try Gemma4StateBudget.estimate(maximumTokens: Self.maximumContextTokens,
            chunkSize: Self.maximumChunkTokens).stateAndBoundaryBytes
        guard specification.manifestBytes > 0, maximumNamedStateBytes == Self.pinnedMaximumNamedStateBytes else {
            throw ProbeError("Registered Gemma ceilings differ from the model's own byte vector")
        }
    }
}
