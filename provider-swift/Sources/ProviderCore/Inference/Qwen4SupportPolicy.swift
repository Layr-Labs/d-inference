// Copyright © 2026 Eigen Labs.
import Foundation
import ProviderCoreFoundation

/// Native capacity and identity policy for the qualified Flash-Next artifact.
/// Coordinator SLA admission is separate from the model's native window.
/// These defaults
/// neither register a catalog model nor establish artifact/runtime qualification.
/// Architecture support remains separate from automatic paging/cache activation.
enum Qwen4SupportPolicy {
    static let ownedModelID = ModelMediaPolicy.ownedQwen4ModelID
    static let registryModelID = Qwen4ModelIdentity.registryModelID
    /// Metadata-only fallback for the two known artifact identities. Loaded
    /// native configuration takes precedence; never derive this from test size.
    static let defaultContextTokens = 262_144
    static let contextEnvironmentKey = "DARKBLOOM_QWEN4_LISTING_CONTEXT"
    static let contextRejectionMessage = "advertised_context_exceeded"

    static func isOwnedModelID(_ modelID: String?) -> Bool {
        Qwen4ModelIdentity.isQualified(modelID)
    }

    static func isQwen4ModelType(_ modelType: String?) -> Bool {
        switch modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "qwen4_exp", "qwen4_exp_text": return true
        default: return false
        }
    }

    /// Validate this owned artifact's template contract after the existing
    /// boolean/effort precedence has resolved. Other Qwen4 artifacts may ship
    /// different templates, so architecture identity alone is insufficient.
    /// Never coerce an unsupported effort or change disabled-thinking behavior.
    static func validateReasoningContext(
        modelID: String,
        modelType: String?,
        additionalContext: [String: any Sendable]?
    ) throws {
        guard isOwnedModelID(modelID), isQwen4ModelType(modelType),
            additionalContext?["enable_thinking"] as? Bool != false,
            let effort = additionalContext?["reasoning_effort"] as? String
        else { return }
        // The original template defaults to xhigh and accepts these exact
        // spellings. Preserve that behavior rather than inventing aliases.
        guard ["low", "medium", "xhigh"].contains(effort) else {
            throw MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort
        }
    }

    /// An explicit operator limit can narrow the native window. Unset or
    /// invalid controls preserve native capacity, not a qualification ceiling.
    static func configuredContextTokens(
        nativeContextTokens: Int = defaultContextTokens,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        let nativeLimit = nativeContextTokens > 0 ? nativeContextTokens : defaultContextTokens
        guard let raw = environment[contextEnvironmentKey],
            let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            value > 0
        else { return nativeLimit }
        return min(nativeLimit, value)
    }

    static func contextLimit(
        modelID: String,
        modelType: String? = nil,
        nativeContextTokens: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard isOwnedModelID(modelID) || isQwen4ModelType(modelType) else { return nil }
        if let nativeContextTokens, nativeContextTokens > 0 {
            return configuredContextTokens(nativeContextTokens: nativeContextTokens,
                environment: environment)
        }
        // An unknown artifact without native metadata has no proven capacity.
        guard isOwnedModelID(modelID) else { return nil }
        return configuredContextTokens(environment: environment)
    }

    /// The factory already resolved this trusted value from model metadata and
    /// operator policy. The generic bridge must not apply a Qwen-sized cap to
    /// other models or clamp a larger native configuration a second time.
    static func validatedContextTokens(_ proposed: Int?) -> Int? {
        guard let proposed, proposed > 0 else { return nil }
        return proposed
    }
}
