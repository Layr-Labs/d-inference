import Foundation
import MLXLMCommon

extension PrefixCachePolicy {
    /// Uses part of the existing slot grant. Persistent assistants must opt
    /// into exact immutable prompt-history checkpoints before enabling reuse.
    static func hybridConfig(
        modelId: String, promptContractID: String?, kvBytesCapacity: Int,
        hasMTPDrafter: Bool, supportsMTPPrefixCheckpoint: Bool = false, environment: [String: String]
    ) -> CBv2HybridPrefixCacheConfig? {
        guard isMemoryEnabled(environment: environment),
            !hasMTPDrafter || supportsMTPPrefixCheckpoint,
            let promptContractID, !promptContractID.isEmpty,
            environment["DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE"] != "0"
        else { return nil }
        let requested = environment["DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES"].flatMap(Int.init)
            ?? min(1 << 30, max(0, kvBytesCapacity / 8))
        guard requested > 0, requested < kvBytesCapacity else { return nil }
        return CBv2HybridPrefixCacheConfig(
            maximumBytes: requested, modelID: modelId,
            promptContractID: promptContractID,
            buildID: "provider-\(ProviderCore.version)-recurrent-checkpoint-v1")
    }
}
