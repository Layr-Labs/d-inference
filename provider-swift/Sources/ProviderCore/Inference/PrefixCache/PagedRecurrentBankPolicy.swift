// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Artifacts whose recurrent checkpoint bank may live on paged KV storage.
///
/// The bank stays behind the resident-memory opt-in and every cache kill
/// switch (`PrefixCachePolicy.hybridConfig`); this policy decides only which
/// artifacts a paged backend may host it for, and how large it is. An entry is
/// one exact artifact whose banked restore was measured on paged storage. A
/// model type alone never qualifies, so a sibling artifact needs its own run.
enum PagedRecurrentBankPolicy {
    struct Artifact: Equatable, Sendable {
        let modelID: String
        let modelType: String
        /// The bank size the qualification run measured; the default never exceeds it.
        let maximumDefaultBytes: Int
    }

    static let qualified = [
        Artifact(modelID: "Qwen3.5-9B", modelType: "qwen3_5", maximumDefaultBytes: 4 << 30)
    ]

    static let granuleBytes = 256 << 20
    /// The smallest default bank. Under it the slot keeps its SSD checkpoints
    /// instead of trading them for a bank that small.
    static let minimumDefaultBytes = 1 << 30

    static func artifact(modelId: String, modelType: String?) -> Artifact? {
        let type = modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return qualified.first { $0.modelID == modelId && $0.modelType == type }
    }

    /// A quarter of the slot grant in 256 MiB steps, at most the measured size.
    /// Zero, which means no bank, when that is under 1 GiB.
    static func defaultBytes(for artifact: Artifact, kvBytesCapacity: Int) -> Int {
        let bytes = min(artifact.maximumDefaultBytes, max(0, kvBytesCapacity) / 4)
            / granuleBytes * granuleBytes
        return bytes >= minimumDefaultBytes ? bytes : 0
    }

    /// The bank a paged backend hosts for a qualified artifact, or nil, which
    /// leaves the slot on its SSD checkpoints. Contiguous storage never reads
    /// this config; it keeps `PrefixCachePolicy.hybridConfig`.
    static func config(
        modelId: String, modelType: String?, promptContractID: String?, kvBytesCapacity: Int,
        hasMTPDrafter: Bool, supportsMTPPrefixCheckpoint: Bool = false,
        environment: [String: String]
    ) -> CBv2HybridPrefixCacheConfig? {
        guard let artifact = artifact(modelId: modelId, modelType: modelType),
            var config = PrefixCachePolicy.hybridConfig(
                modelId: modelId, promptContractID: promptContractID,
                kvBytesCapacity: kvBytesCapacity, hasMTPDrafter: hasMTPDrafter,
                supportsMTPPrefixCheckpoint: supportsMTPPrefixCheckpoint,
                defaultBytes: defaultBytes(for: artifact, kvBytesCapacity: kvBytesCapacity),
                environment: environment)
        else { return nil }
        config.permitsPagedStorage = true
        return config
    }
}
