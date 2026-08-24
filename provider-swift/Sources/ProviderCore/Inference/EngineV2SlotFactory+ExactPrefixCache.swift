// Copyright © 2026 Eigen Labs.
//
// Default-off deployment policy for exact Qwen prompt-state reuse. This is
// deliberately separate from `PrefixCachePolicy`, which continues to own the
// legacy KV-only encrypted SSD tier. A model must advertise the stronger
// exact-state capability and the slot factory must provide verified artifact
// identities before any RAM is carved from live KV.

import CryptoKit
import Foundation
import MLXLMCommon

extension EngineV2SlotFactory {

    /// Explicit operator/programmatic controls for exact-state RAM reuse.
    ///
    /// Both limits are hard ceilings. The effective budget is:
    ///
    ///     min(maxBytes, maxFraction × slotGrant, slotGrant − liveKVFloor)
    ///
    /// where `slotGrant` already came from `UnifiedMemoryCap.kvBudgetBytes`.
    /// The factory subtracts that exact result from the engine's KV ceiling.
    struct ExactPrefixCacheConfiguration: Sendable, Equatable {
        let enabled: Bool
        let maxBytes: Int
        let maxFraction: Double

        init(enabled: Bool, maxBytes: Int, maxFraction: Double) {
            self.enabled = enabled
            self.maxBytes = maxBytes
            self.maxFraction = maxFraction
        }
    }

    enum ExactPrefixCacheDecisionReason: String, Sendable, Equatable {
        case ready
        case configDisabled = "config_disabled"
        case invalidBudget = "invalid_budget"
        case unsupportedModel = "unsupported_model"
        case unsupportedBackend = "unsupported_backend"
        case weightHashUnavailable = "weight_hash_unavailable"
        case promptContractUnavailable = "prompt_contract_unavailable"
        case insufficientKVGrant = "insufficient_kv_grant"
    }

    struct ExactPrefixCacheIdentity: Sendable, Equatable {
        let modelIdentity: String
        let policyIdentity: String
    }

    /// Pure construction decision. `cacheBudgetBytes + engineKVBytesCapacity`
    /// always equals the nonnegative input grant.
    struct ExactPrefixCacheDecision: Sendable, Equatable {
        let configured: Bool
        let reason: ExactPrefixCacheDecisionReason
        let cacheBudgetBytes: Int
        let engineKVBytesCapacity: Int
        let identity: ExactPrefixCacheIdentity?

        var isActive: Bool {
            reason == .ready && cacheBudgetBytes > 0 && identity != nil
        }
    }

    static let exactPrefixCacheEnabledEnvironmentKey =
        "DARKBLOOM_EXACT_PREFIX_CACHE"
    static let exactPrefixCacheMaxBytesEnvironmentKey =
        "DARKBLOOM_EXACT_PREFIX_CACHE_MAX_BYTES"
    static let exactPrefixCacheMaxFractionEnvironmentKey =
        "DARKBLOOM_EXACT_PREFIX_CACHE_MAX_FRACTION"

    /// Two GiB retains the measured 6,144/7,168-token 8K boundaries under
    /// sequential LRU. The fractional ceiling still prevents the cache from
    /// dominating a small slot; retaining all 32 boundaries (~4.83 GB)
    /// requires an explicit larger byte ceiling.
    static let defaultExactPrefixCacheMaxBytes = 2_147_483_648
    static let defaultExactPrefixCacheMaxFraction = 0.125

    /// Versioned snapshot/execution contract. Changing this value invalidates
    /// every key even if model artifacts and prompt tokens stay unchanged.
    static let exactPrefixCachePolicyDomain =
        "darkbloom.cbv2-exact-prompt-state-v3"

    /// Environment resolution is fail-closed:
    ///   * absent/unrecognized enable values keep the feature off;
    ///   * once explicitly enabled, malformed budget values produce an invalid
    ///     configuration instead of silently selecting a different RAM claim.
    static func exactPrefixCacheConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ExactPrefixCacheConfiguration {
        let enabled = affirmativeEnvironmentValue(
            environment[exactPrefixCacheEnabledEnvironmentKey])
        guard enabled else {
            return ExactPrefixCacheConfiguration(
                enabled: false,
                maxBytes: defaultExactPrefixCacheMaxBytes,
                maxFraction: defaultExactPrefixCacheMaxFraction)
        }

        let maxBytes: Int
        if let raw = environment[exactPrefixCacheMaxBytesEnvironmentKey] {
            maxBytes = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } else {
            maxBytes = defaultExactPrefixCacheMaxBytes
        }

        let maxFraction: Double
        if let raw = environment[exactPrefixCacheMaxFractionEnvironmentKey] {
            maxFraction =
                Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? .nan
        } else {
            maxFraction = defaultExactPrefixCacheMaxFraction
        }
        return ExactPrefixCacheConfiguration(
            enabled: true, maxBytes: maxBytes, maxFraction: maxFraction)
    }

    /// Reusable cache identity needs a fresh pre/post-load cryptographic
    /// weight bracket whenever either independent tier is requested. This
    /// keeps the exact RAM opt-in functional when an operator explicitly
    /// disables the legacy SSD tier.
    static func cacheIdentityRequiresFreshWeightHash(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        PrefixCachePolicy.isEnabled(environment: environment)
            || exactPrefixCacheConfiguration(environment: environment).enabled
    }

    /// Resolve the exact-state cache and live-KV split without constructing
    /// either object. The stronger model capability is the selection gate;
    /// model names are never used as a capability proxy.
    static func exactPrefixCacheDecision(
        modelId: String,
        capabilities: CBv2ModelCapabilities,
        backend: EngineV2KVBackendKind,
        backendDType: String?,
        weightHash: String?,
        promptContractID: String?,
        slotKVBytesCapacity: Int,
        configuration: ExactPrefixCacheConfiguration,
        minimumEngineKVBytes: UInt64 = UnifiedMemoryCap.minimumLoadKVBytes,
        policyDomain: String = exactPrefixCachePolicyDomain
    ) -> ExactPrefixCacheDecision {
        let slot = max(0, slotKVBytesCapacity)
        func inactive(
            _ reason: ExactPrefixCacheDecisionReason
        ) -> ExactPrefixCacheDecision {
            ExactPrefixCacheDecision(
                configured: configuration.enabled,
                reason: reason,
                cacheBudgetBytes: 0,
                engineKVBytesCapacity: slot,
                identity: nil)
        }

        guard configuration.enabled else { return inactive(.configDisabled) }
        guard capabilities.supportsExactStatePrefixReuse else {
            return inactive(.unsupportedModel)
        }
        // The proved snapshot owns contiguous full-attention rows. Do not infer
        // that a future exact-capable model makes paged adoption valid.
        guard backend == .contiguous else { return inactive(.unsupportedBackend) }
        guard configuration.maxBytes > 0,
            configuration.maxFraction.isFinite,
            configuration.maxFraction > 0,
            configuration.maxFraction <= 1
        else {
            return inactive(.invalidBudget)
        }

        let identityResult = exactPrefixCacheIdentity(
            modelId: modelId,
            weightHash: weightHash,
            promptContractID: promptContractID,
            backend: backend,
            backendDType: backendDType,
            policyDomain: policyDomain)
        switch identityResult {
        case .failure(.weightHashUnavailable):
            return inactive(.weightHashUnavailable)
        case .failure(.promptContractUnavailable):
            return inactive(.promptContractUnavailable)
        case .failure(.invalidModel):
            return inactive(.unsupportedModel)
        case .success:
            break
        }

        let floor = Int(min(minimumEngineKVBytes, UInt64(Int.max)))
        guard slot > floor else { return inactive(.insufficientKVGrant) }
        let scaled = Double(slot) * configuration.maxFraction
        let fractionBudget =
            !scaled.isFinite || scaled >= Double(Int.max)
            ? Int.max
            : max(0, Int(scaled.rounded(.down)))
        let budget = min(configuration.maxBytes, fractionBudget, slot - floor)
        guard budget > 0 else { return inactive(.insufficientKVGrant) }

        guard case .success(let identity) = identityResult else {
            preconditionFailure(
                "exact prefix identity resolution changed within one decision")
        }
        return ExactPrefixCacheDecision(
            configured: true,
            reason: .ready,
            cacheBudgetBytes: budget,
            engineKVBytesCapacity: slot - budget,
            identity: identity)
    }

    static func makeExactPrefixCache(
        decision: ExactPrefixCacheDecision
    ) -> ExactPrefixCacheV2? {
        guard decision.isActive, let identity = decision.identity else { return nil }
        return ExactPrefixCacheV2(
            config: CBv2ExactPrefixCacheConfig(
                modelIdentity: identity.modelIdentity,
                policyIdentity: identity.policyIdentity,
                maxBytes: decision.cacheBudgetBytes))
    }

    // MARK: - Verified identity

    enum ExactPrefixCacheIdentityError: Error, Sendable, Equatable {
        case invalidModel
        case weightHashUnavailable
        case promptContractUnavailable
    }

    /// Compose content-free cache identities from the verified live artifacts.
    /// Only the resulting SHA-256 digests are retained by the cache; raw
    /// artifact digests never enter logs, status, or telemetry.
    static func exactPrefixCacheIdentity(
        modelId: String,
        weightHash: String?,
        promptContractID: String?,
        backend: EngineV2KVBackendKind,
        backendDType: String?,
        policyDomain: String = exactPrefixCachePolicyDomain
    ) -> Result<ExactPrefixCacheIdentity, ExactPrefixCacheIdentityError> {
        guard !modelId.isEmpty,
            modelId == modelId.trimmingCharacters(in: .whitespacesAndNewlines),
            modelId.utf8.count <= 1_024
        else {
            return .failure(.invalidModel)
        }
        guard let weightDigest = canonicalSHA256Digest(weightHash) else {
            return .failure(.weightHashUnavailable)
        }
        guard let promptDigest = canonicalSHA256Digest(promptContractID) else {
            return .failure(.promptContractUnavailable)
        }
        guard !policyDomain.isEmpty else { return .failure(.invalidModel) }

        let modelIdentity = digestIdentity(
            domain: "darkbloom.cbv2-exact-model-identity.v1",
            fields: [
                Data(modelId.utf8),
                weightDigest,
                promptDigest,
            ])
        let policyIdentity = digestIdentity(
            domain: "darkbloom.cbv2-exact-policy-identity.v1",
            fields: [
                Data(policyDomain.utf8),
                Data(backend.rawValue.utf8),
                Data((backendDType ?? "native").utf8),
            ])
        return .success(
            ExactPrefixCacheIdentity(
                modelIdentity: modelIdentity,
                policyIdentity: policyIdentity))
    }

    private static func affirmativeEnvironmentValue(_ raw: String?) -> Bool {
        guard let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }

    private static func canonicalSHA256Digest(_ raw: String?) -> Data? {
        guard let raw,
            raw.count == 64,
            raw == raw.lowercased(),
            raw.unicodeScalars.allSatisfy({
                (48 ... 57).contains($0.value)
                    || (97 ... 102).contains($0.value)
            })
        else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = raw.startIndex
        while index < raw.endIndex {
            let next = raw.index(index, offsetBy: 2)
            guard let byte = UInt8(raw[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func digestIdentity(domain: String, fields: [Data]) -> String {
        var input = Data(domain.utf8)
        for field in fields {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(field)
        }
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
