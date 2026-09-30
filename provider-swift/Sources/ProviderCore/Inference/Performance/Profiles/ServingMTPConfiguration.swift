import CryptoKit
import Foundation
import MLXLMCommon

/// Nil in a serving profile means plain-target execution. A non-nil value
/// names the verified assistant and every effective scheduling/verification
/// option; matching only the target checkpoint never certifies an MTP runtime.
public struct ServingMTPConfiguration: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var artifactSha256: String
    public var maxDraftTokens: Int
    public var fixedDraftTokens: Int?
    public var maxSpeculativeBatch: Int
    public var verificationMode: String
    public var maxAutomaticRectangularTokens: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case artifactSha256 = "artifact_sha256"
        case maxDraftTokens = "max_draft_tokens"
        case fixedDraftTokens = "fixed_draft_tokens"
        case maxSpeculativeBatch = "max_speculative_batch"
        case verificationMode = "verification_mode"
        case maxAutomaticRectangularTokens = "max_automatic_rectangular_tokens"
    }

    var isValid: Bool {
        enabled && ServingPerformanceProfiles.validDigest(artifactSha256)
            && (0...7).contains(maxDraftTokens)
            && (fixedDraftTokens.map { (0...maxDraftTokens).contains($0) } ?? true)
            && (1...8).contains(maxSpeculativeBatch)
            && ["serial_target", "rectangular", "rectangular_exact", "automatic"].contains(verificationMode)
            && maxAutomaticRectangularTokens >= 0
    }

    static func resolve(config: CBv2MTPConfig, artifact: SpecDecArtifact?) -> Self? {
        guard config.effectiveEnabled, let artifact, let digest = artifactDigest(artifact) else { return nil }
        let result = Self(enabled: true, artifactSha256: digest,
            maxDraftTokens: config.maxDraftTokens, fixedDraftTokens: config.fixedDraftTokens,
            maxSpeculativeBatch: config.maxSpeculativeBatch,
            verificationMode: config.verificationMode.rawValue,
            maxAutomaticRectangularTokens: config.maxAutomaticRectangularTokens)
        return result.isValid ? result : nil
    }

    /// Uses inspection-time verification facts only; never hashes model files
    /// on the startup scan or invents an identity from a display revision.
    static func artifactDigest(_ artifact: SpecDecArtifact) -> String? {
        switch artifact.source {
        case .catalog:
            return artifact.manifestSHA256.flatMap { ServingPerformanceProfiles.validDigest($0) ? $0 : nil }
        case .inline:
            return artifact.inlineIndexSHA256.flatMap { ServingPerformanceProfiles.validDigest($0) ? $0 : nil }
        case .local:
            guard let config = artifact.localConfigSHA256, ServingPerformanceProfiles.validDigest(config),
                let weights = artifact.localWeightSHA256, !weights.isEmpty,
                weights.values.allSatisfy(ServingPerformanceProfiles.validDigest) else { return nil }
            struct Identity: Encodable {
                let config_sha256: String
                let weights_sha256: [String: String]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(Identity(config_sha256: config, weights_sha256: weights)) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
