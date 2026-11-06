import Foundation

/// Actual-geometry named load/request ledger. It reuses the resident full-state
/// formula once and combines both disjoint fusion banks; no 8K output-one state
/// receipt is promoted to a generation permit. Unknown workspace is excluded.
struct QwenFullGenerationReferenceBudget: Encodable {
    let profileFingerprint: String
    let requestFingerprint: String
    let planFingerprint: String
    let sourceNames: [String]
    let sourceByteCounts: [Int]
    let allocationBounds: [Int]
    let largestHostTensorBytes: Int
    let stateBytes: Int
    let fusionBytes: Int
    let capturedRowsCPUBytes: Int
    let captureNativeBytes: Int
    let requestReservedBytes: Int
    let wholeProcessPeakBoundEstablished = false

    static func derive(profile: QwenRegisteredDenseModelProfile, plan: QwenLayerStagePlan,
        request: QwenLayerStageGenerationRequest, requirements: QwenGenerationReferenceRequirements,
        source: QwenDenseSourceReadPlan, bound: (Int) throws -> Int
    ) throws -> Self {
        guard profile.model == .qwen35NineB,
              profile.configuration == plan.originalConfiguration,
              try profile.makePlanningPlan(stageCut: plan.stages[0].sourceRange.upperBound).fingerprint == plan.fingerprint,
              request.promptCount == 8192, request.chunkSize == 512, (1...128).contains(request.outputCount),
              request.profile.identifier == QwenFullGenerationReferenceCLI.profileID,
              request.profile.vocabularySize == profile.vocabularySize,
              request.profile.hiddenSize == profile.geometry.hiddenSize,
              request.profile.activationDType == profile.requiredNativeDType,
              source.tensors.map(\.canonical) == profile.canonicalTensors,
              source.sourceBytes == profile.sourceTensorBytes,
              source.largestSourceBytes == profile.largestSourceTensorBytes else {
            throw ProbeError("Full generation budget differs from its actual registered source/request")
        }
        let expected = try QwenGenerationReferenceRequirements(request: request, geometry: profile.geometry,
            namedTensorByteCeiling: QwenRegistered9BLongPrefillAdmission.namedTensorByteCeiling)
        guard try canonicalJSONData(requirements) == canonicalJSONData(expected) else {
            throw ProbeError("Full generation resource requirements differ from the exact request")
        }
        let left = try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: 0,
            maximumTokens: request.maximumTokens, chunkSize: request.chunkSize, bound: bound)
        let right = try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: 1,
            maximumTokens: request.maximumTokens, chunkSize: request.chunkSize, bound: bound)
        guard left.stateBytes == right.stateBytes else { throw ProbeError("Full reference state formula depends on stage ownership") }
        let sum = QwenLongPrefillCheckedBytes.sum
        func allocation(_ bytes: Int) throws -> Int {
            let value = try bound(bytes)
            guard bytes > 0, value >= bytes else { throw ProbeError("Full generation allocator bound is invalid") }
            return value
        }
        let fusion = try sum([left.fusionBytes, right.fusionBytes])
        let rowBytes = try QwenLongPrefillCheckedBytes.product([
            request.profile.vocabularySize, qwenStageWireElementBytes(request.profile.activationDType),
        ])
        let capture = try sum([allocation(rowBytes), allocation(expected.temporaryFloat32RowBytes)])
        let allocations = try source.tensors.map { try allocation($0.canonical.byteCount) }
        _ = try sum(allocations)
        return .init(profileFingerprint: profile.fingerprint, requestFingerprint: request.fingerprint,
            planFingerprint: plan.fingerprint, sourceNames: source.tensors.map { $0.canonical.name },
            sourceByteCounts: source.tensors.map { $0.canonical.byteCount }, allocationBounds: allocations,
            largestHostTensorBytes: source.largestSourceBytes, stateBytes: left.stateBytes, fusionBytes: fusion,
            capturedRowsCPUBytes: expected.capturedRowsCPUBytes, captureNativeBytes: capture,
            requestReservedBytes: try sum([left.stateBytes, fusion, expected.capturedRowsCPUBytes, capture]))
    }

    func remainingAllocationBytes(after count: Int) throws -> Int {
        guard (0...allocationBounds.count).contains(count) else { throw ProbeError("Invalid full-load progress") }
        return try QwenLongPrefillCheckedBytes.sum(Array(allocationBounds.dropFirst(count)))
    }

    func requiredActualFreeBytes(after count: Int) throws -> Int {
        let remaining = try remainingAllocationBytes(after: count)
        let host = count == allocationBounds.count ? 0 : largestHostTensorBytes
        return max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
            try QwenLongPrefillCheckedBytes.sum([remaining, host, host, requestReservedBytes,
                QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
    }

    func requiredAllocatorBytes(after count: Int, active: Int, cache: Int) throws -> Int {
        guard active >= 0, cache >= 0 else { throw ProbeError("Invalid full-reference allocator observation") }
        let remaining = try remainingAllocationBytes(after: count)
        let host = count == allocationBounds.count ? 0 : largestHostTensorBytes
        return try QwenLongPrefillCheckedBytes.sum([active, cache, remaining, host, stateBytes, fusionBytes,
            captureNativeBytes, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
    }

    func requireEntry(name: String, byteCount: Int, ordinal: Int) throws {
        guard sourceNames.indices.contains(ordinal), sourceNames[ordinal] == name,
              sourceByteCounts[ordinal] == byteCount else { throw ProbeError("Full reference read a different or unordered tensor") }
    }
}
