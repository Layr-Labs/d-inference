import MLX
import MLXLMCommon

enum MiMoV26AdmissionGeometryError: Error, Equatable {
    case invalidProbe, invalidGeometry, arithmeticOverflow
}

/// Native contiguous target accounting only. These are checked LOGICAL shape
/// bytes, not allocator projections, physical measurements or materialized-M
/// credit. The real probe owns dtype truth; the backend deliberately prices a
/// mixed dtype table uniformly at FP32. Internal Admission already prices SWA
/// rings via its residency policy; only the shared bridge needs the extra fixed
/// target-ring term. Other model families/global defaults are unchanged.
struct MiMoV26AdmissionGeometry {
    let elementBytes: Int
    let fullKVBytesPerToken: Int
    let targetWindowLogicalBytes: Int
    let maximumContextTokens: Int

    init(layerKinds: [CBv2LayerKind], probedDTypes: [DType], maximumContextTokens: Int) throws {
        guard !layerKinds.isEmpty, probedDTypes.count == layerKinds.count,
            probedDTypes.allSatisfy({ [.float16, .bfloat16, .float32].contains($0) }) else {
            throw MiMoV26AdmissionGeometryError.invalidProbe
        }
        guard maximumContextTokens > 0 else { throw MiMoV26AdmissionGeometryError.invalidGeometry }
        let width = Set(probedDTypes).count == 1 ? probedDTypes[0].size : 4
        var full = 0, rings = 0
        for (index, kind) in layerKinds.enumerated() {
            guard kind.headDim > 0, kind.valueHeadDim > 0, kind.kvHeads > 0,
                kind.queryHeads > 0, kind.queryHeads.isMultiple(of: kind.kvHeads),
                kind.extraStorageBytesPerToken == 0 else {
                throw MiMoV26AdmissionGeometryError.invalidGeometry
            }
            if let source = kind.sharesKVWithLayer {
                guard layerKinds.indices.contains(source), source != index,
                    layerKinds[source].sharesKVWithLayer == nil,
                    layerKinds[source].attention == kind.attention,
                    layerKinds[source].headDim == kind.headDim,
                    layerKinds[source].valueHeadDim == kind.valueHeadDim,
                    layerKinds[source].kvHeads == kind.kvHeads,
                    probedDTypes[source] == probedDTypes[index] else {
                    throw MiMoV26AdmissionGeometryError.invalidGeometry
                }
                continue // A borrower owns no second ring or full KV allocation.
            }
            // Price independent K/V widths; never assume V width == K width.
            let keys = try Self.multiply(Self.multiply(kind.kvHeads, kind.headDim), width)
            let values = try Self.multiply(Self.multiply(kind.kvHeads, kind.valueHeadDim), width)
            let perToken = try Self.add(keys, values)
            switch kind.attention {
            case .full: full = try Self.add(full, perToken)
            case .slidingWindow(let window):
                guard window > 0 else { throw MiMoV26AdmissionGeometryError.invalidGeometry }
                rings = try Self.add(rings, Self.multiply(window, perToken))
            }
        }
        // Refuse an unrepresentable native context before constructing an
        // engine. This is arithmetic validation, not a new context-size cap.
        _ = try Self.add(Self.multiply(full, maximumContextTokens), rings)
        elementBytes = width; fullKVBytesPerToken = full
        targetWindowLogicalBytes = rings; self.maximumContextTokens = maximumContextTokens
    }

    var internalAdmissionConfig: AdmissionV2.Config {
        .init(elementBytes: elementBytes) // ZERO extra fixed target-ring bytes.
    }

    func sharedFixedRequestBytes(resolvedNonTargetFixedBytes: Int) throws -> Int {
        try Self.add(targetWindowLogicalBytes, resolvedNonTargetFixedBytes)
    }

    func logicalTargetBytes(positiveTokens: Int) throws -> Int {
        guard positiveTokens > 0, positiveTokens <= maximumContextTokens else {
            throw MiMoV26AdmissionGeometryError.invalidGeometry
        }
        return try Self.add(Self.multiply(fullKVBytesPerToken, positiveTokens), targetWindowLogicalBytes)
    }

    private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard lhs >= 0, rhs >= 0, !result.overflow else { throw MiMoV26AdmissionGeometryError.arithmeticOverflow }
        return result.partialValue
    }
    private static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs >= 0, rhs >= 0, !result.overflow else { throw MiMoV26AdmissionGeometryError.arithmeticOverflow }
        return result.partialValue
    }
}
