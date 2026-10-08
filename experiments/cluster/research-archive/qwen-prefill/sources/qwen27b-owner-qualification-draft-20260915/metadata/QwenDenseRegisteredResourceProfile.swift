import Foundation

/// Exact registered metadata limits, not an execution, payload or OS permit.
/// Legacy callers keep their original limits. Ordinary resident admission is
/// still 9B-only; native validation is a separate explicit admission decision.
struct QwenDenseRegisteredResourceProfile {
    static let maximumContextTokens = 8320
    static let maximumChunkTokens = 512

    let model: QwenRegisteredDenseModel
    let configurationSHA256: String, manifestSHA256: String, artifactAggregateSHA256: String
    let geometry: QwenLongPrefillBudgetGeometry
    let maximumManifestPayloadBytes: Int
    let namedTensorByteCeiling: Int
    let maximumNamedStateBudget: QwenLongPrefillTensorBudget
    let runtimeExecutionAuthorized = false
    let actualPayloadVerificationEstablished = false
    let independentResourcePolicyRequired = true

    init(specification: QwenDenseRegisteredSpecification) throws {
        let expectedMaximumStateBytes: Int
        switch specification.model {
        case .qwen35NineB:
            // Preserve the resident's prior legacy manifest limit and unchanged
            // exact-9B long-prefill ceiling; this does not alter that receipt.
            maximumManifestPayloadBytes = 8 * 1024 * 1024 * 1024
            namedTensorByteCeiling = QwenRegistered9BLongPrefillAdmission.namedTensorByteCeiling
            expectedMaximumStateBytes = 754_188_320
        case .qwen38TwentySevenB:
            // Independent registered metadata scope. No legacy constant grows,
            // and selecting these values grants no 27B execution permission.
            maximumManifestPayloadBytes = 16_320_415_757
            namedTensorByteCeiling = 1_616_248_896
            expectedMaximumStateBytes = 1_616_248_896
        }
        model = specification.model
        configurationSHA256 = specification.configurationSHA256
        manifestSHA256 = specification.manifestSHA256
        artifactAggregateSHA256 = specification.artifactSHA256
        geometry = try specification.expectedGeometry()
        maximumNamedStateBudget = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
            maximumTokens: Self.maximumContextTokens, chunkSize: Self.maximumChunkTokens)
        guard specification.manifestBytes > 0,
              specification.manifestBytes <= maximumManifestPayloadBytes,
              maximumNamedStateBudget.conservativeStateAndBoundaryBytes == expectedMaximumStateBytes,
              expectedMaximumStateBytes <= namedTensorByteCeiling else {
            throw QwenDenseProfileError("Registered resource profile differs from its exact byte vector")
        }
    }

    init(profile: QwenRegisteredDenseModelProfile) throws {
        guard let specification = QwenDenseRegisteredSpecification.all.first(where: { $0.model == profile.model }),
              profile.configurationSHA256 == specification.configurationSHA256,
              profile.manifestSHA256 == specification.manifestSHA256,
              profile.artifactAggregateSHA256 == specification.artifactSHA256,
              profile.canonicalInventorySHA256 == specification.inventorySHA256,
              profile.manifestPayloadBytes == specification.manifestBytes,
              profile.sourceTensorBytes == specification.sourceBytes,
              profile.largestSourceTensorBytes == specification.largestTensorBytes,
              profile.geometry == (try specification.expectedGeometry()) else {
            throw QwenDenseProfileError("Registered resource profile uses different admitted metadata")
        }
        try self.init(specification: specification)
    }

    /// Bounded calculation for the selected model, never a runtime admission.
    func namedStateBudget(maximumTokens: Int, chunkSize: Int) throws -> QwenLongPrefillTensorBudget {
        guard (1...Self.maximumContextTokens).contains(maximumTokens),
              (1...Self.maximumChunkTokens).contains(chunkSize), chunkSize <= maximumTokens else {
            throw QwenDenseProfileError("Registered resource request exceeds its context/chunk calculation scope")
        }
        let budget = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
            maximumTokens: maximumTokens, chunkSize: chunkSize)
        guard budget.conservativeStateAndBoundaryBytes <= namedTensorByteCeiling else {
            throw QwenDenseProfileError("Registered resource request exceeds its named-state ceiling")
        }
        return budget
    }
}
