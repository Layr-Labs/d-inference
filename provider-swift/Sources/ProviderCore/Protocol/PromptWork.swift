import Foundation

/// Numeric count evidence tied to verified model and prompt-contract bytes.
/// Unknown sources/versions remain decodable and cannot enable qualification.
public struct PromptWork: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let maxTokens = 1_048_576
    public var version: Int
    public var source: String
    public var promptTokens: Int
    public var upperBoundTokens: Int
    public var promptContractID: String?
    public var modelArtifactHash: String?
    public var calibrationID: String?

    public init(version: Int = Self.currentVersion, source: String, promptTokens: Int,
                upperBoundTokens: Int, promptContractID: String? = nil,
                modelArtifactHash: String? = nil, calibrationID: String? = nil) {
        self.version = version
        self.source = source
        self.promptTokens = promptTokens
        self.upperBoundTokens = upperBoundTokens
        self.promptContractID = promptContractID
        self.modelArtifactHash = modelArtifactHash
        self.calibrationID = calibrationID
    }

    enum CodingKeys: String, CodingKey {
        case version, source
        case promptTokens = "prompt_tokens"
        case upperBoundTokens = "upper_bound_tokens"
        case promptContractID = "prompt_contract_id"
        case modelArtifactHash = "model_artifact_hash"
        case calibrationID = "calibration_id"
    }

    public func isQualified(for identity: PromptWorkIdentity) -> Bool {
        guard version == Self.currentVersion, promptTokens > 0,
              upperBoundTokens >= promptTokens, upperBoundTokens <= Self.maxTokens,
              Self.isDigest(modelArtifactHash), Self.isDigest(promptContractID),
              modelArtifactHash == identity.modelArtifactHash,
              promptContractID == identity.promptContractID else { return false }
        switch source {
        case "exact_contract":
            return promptTokens == upperBoundTokens && (calibrationID ?? "").isEmpty
        case "calibrated_template":
            guard let calibrationID, !calibrationID.isEmpty,
                  calibrationID.utf8.count <= 128 else { return false }
            return calibrationID.utf8.allSatisfy { (33...126).contains($0) }
        default:
            return false
        }
    }

    /// Actual tokenization stays authoritative. An exact-count mismatch or a
    /// calibrated bound exceeded by real work withdraws calibrated admission;
    /// it never extends the deadline or changes token/memory accounting.
    public func reconciled(actualPromptTokens: Int, identity: PromptWorkIdentity?) -> ReconciledPromptWork? {
        guard let identity, isQualified(for: identity), actualPromptTokens > 0,
              actualPromptTokens <= upperBoundTokens,
              source != "exact_contract" || actualPromptTokens == promptTokens else { return nil }
        return ReconciledPromptWork(evidence: self, actualPromptTokens: actualPromptTokens)
    }

    private static func isDigest(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Factory-owned identity computed from verified model artifacts regardless
/// of whether prefix-cache storage is enabled.
public struct PromptWorkIdentity: Sendable, Equatable {
    public let modelArtifactHash: String
    public let promptContractID: String

    public init(modelArtifactHash: String, promptContractID: String) {
        self.modelArtifactHash = modelArtifactHash
        self.promptContractID = promptContractID
    }
}

public struct ReconciledPromptWork: Sendable, Equatable {
    public let evidence: PromptWork
    public let actualPromptTokens: Int
    fileprivate init(evidence: PromptWork, actualPromptTokens: Int) {
        self.evidence = evidence
        self.actualPromptTokens = actualPromptTokens
    }
}
