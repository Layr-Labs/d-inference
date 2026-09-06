import CryptoKit
import Foundation
import MLXLMCommon

extension PrefixCachePolicy {
    /// Computed once per process, not per model or request. The bound metallib
    /// digest is read separately after MLX startup has pinned its immutable file.
    static let checkpointBinaryHash = selfBinaryHash()

    static func completeCheckpointIdentity(
        modelAggregateHash: String?, promptContractID: String?,
        binaryHash: String?, loadedMetallibHash: String?, osVersion: String,
        mtpConfig: CBv2MTPConfig, assistantCodecID: String?,
        environment: [String: String], processEnvironment: [String: String],
        storage: CompleteCheckpointStorageIdentity? = nil
    ) -> CBv2CompleteCheckpointIdentity? {
        guard let modelHash = checkpointIdentityHash(modelAggregateHash),
            let promptHash = checkpointIdentityHash(promptContractID),
            let binaryHash = checkpointIdentityHash(binaryHash),
            let loadedMetallibHash = checkpointIdentityHash(loadedMetallibHash),
            !osVersion.isEmpty
        else { return nil }
        let buildID = checkpointFingerprint([
            "binary": binaryHash, "metallib": loadedMetallibHash,
            "format": "complete-checkpoint-v1",
        ])
        var numerics = [
            "os": osVersion,
            "mtp.enabled": String(mtpConfig.enabled),
            "mtp.codec": assistantCodecID ?? "none",
            "mtp.verification": mtpConfig.verificationMode.rawValue,
            "mtp.maxDraftTokens": String(mtpConfig.maxDraftTokens),
            "mtp.fixedDraftTokens": mtpConfig.fixedDraftTokens.map(String.init) ?? "adaptive",
            "mtp.maxSpeculativeBatch": String(mtpConfig.maxSpeculativeBatch),
            "mtp.maxAutomaticRectangularTokens": String(mtpConfig.maxAutomaticRectangularTokens),
        ]
        if let storage { numerics.merge(storage.fingerprintFields) { _, actual in actual } }
        // Include both the actual process switches used by MLX/model kernels
        // and slot overrides used by provider assembly. Extra invalidations are
        // safe; missing a numerics switch could restore incompatible state.
        for (scope, values) in [("process", processEnvironment), ("slot", environment)] {
            for (key, value) in values where
                key.hasPrefix("MLX_") || key.hasPrefix("DARKBLOOM_CBV2_")
                    || key.hasPrefix("DARKBLOOM_QWEN_") || key.hasPrefix("DARKBLOOM_MTP_")
                    || key.hasPrefix("DARKBLOOM_GPTOSS_") || key.hasPrefix("DARKBLOOM_GEMMA4_") {
                numerics[scope + "." + key] = value
            }
        }
        return CBv2CompleteCheckpointIdentity(
            modelAggregateHash: modelHash, promptContractID: promptHash,
            buildID: buildID, numericsFingerprint: checkpointFingerprint(numerics))
    }

    /// Attested identities use canonical SHA-256 hex, never a model name or
    /// caller-supplied nonempty placeholder. Do not rehash the underlying files.
    static func checkpointIdentityHash(_ value: String?) -> String? {
        guard let value, value.utf8.count == 64,
            value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        return value
    }

    /// Sorted length-delimited fields prevent concatenation ambiguity. Only
    /// the digest reaches the store; raw settings never enter its index/logs.
    private static func checkpointFingerprint(_ fields: [String: String]) -> String {
        var hasher = SHA256()
        for (key, fieldValue) in fields.sorted(by: { $0.key < $1.key }) {
            for value in [key, fieldValue] {
                let bytes = Data(value.utf8)
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
                hasher.update(data: bytes)
            }
        }
        return hasher.finalize().hexString
    }
}
