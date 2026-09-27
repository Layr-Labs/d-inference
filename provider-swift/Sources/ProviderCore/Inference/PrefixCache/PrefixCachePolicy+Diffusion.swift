import Foundation
import MLXVLM
import ProviderCoreFoundation

extension PrefixCachePolicy {
    /// Resident-only snapshots preserve the stack's explicit RAM-retention
    /// opt-in. A runtime-only owner identity cannot enable disk restore or
    /// coordinator durable-holder advertisements.
    static func diffusionResidentConfig(modelDirectory: URL?, weightHash: String?, kvBytesCapacity: Int,
        environment: [String: String]) throws -> DiffusionGemmaResidentPrefixConfiguration?
    {
        guard isMemoryEnabled(environment: environment), let modelDirectory,
            let contract = try? PromptContractIdentity.compute(modelDirectory: modelDirectory)
        else { return nil }
        let bytes = min(1 << 30, max(0, kvBytesCapacity / 8))
        guard bytes > 0, bytes < kvBytesCapacity else { return nil }
        return try .init(maximumBytes: bytes,
            artifactIdentity: checkpointIdentityHash(weightHash) ?? "runtime-owner-" + UUID().uuidString,
            templateIdentity: contract,
            numericalProfile: "provider-\(ProviderCore.version)-native-diffusion-contiguous-v1")
    }
}
