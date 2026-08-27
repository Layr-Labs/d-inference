// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation

/// Model-specific activation working-set policy.
///
/// Activation memory is determined by the executed kernels, not by parameter
/// count alone. Lower reserves therefore require a measured execution profile
/// whose architecture signature matches the local checkpoint exactly.
/// Unmeasured, incomplete, vision, or changed shapes retain the conservative
/// fleet reserve.
public enum ModelActivationPolicy {
    static let bytesPerGiB: UInt64 = 1 << 30

    /// Exact `config.json` measured by the v0.8.0 batch-8 sweep:
    /// `mlx-community/gpt-oss-20b-MXFP4-Q8`, snapshot
    /// `773a7da77e569019bb0fd17a554b263738d669a3`.
    static let measuredGPTOSS20BConfigSHA256 =
        "d1c1f73bf62116ed0bb37c068af80534543cd1de9b61d609fc01bf70920e842d"

    /// GPT-OSS 20B peaks at 2.56 GiB above resident weights on M4 Max at
    /// the shipping decode batch of 8. Three GiB keeps 0.44 GiB of measured
    /// slack while returning 2.5 GiB to KV versus the conservative profile.
    static let gptOSS20BReserveBytes: UInt64 = 3 * bytesPerGiB

    /// Resolve the reserve for one model from already-parsed local metadata.
    ///
    /// The environment override remains raise-only and is applied after profile
    /// selection, so an operator can add headroom but cannot accidentally lower
    /// a measured safety floor.
    public static func reserveBytes(
        modelType: String?,
        architecture: ModelArchitecture,
        isVision: Bool,
        configSHA256: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt64 {
        let profile = profileReserveBytes(
            modelType: modelType,
            architecture: architecture,
            isVision: isVision,
            configSHA256: configSHA256)
        return UnifiedMemoryCap.resolvedActivationReserveBytes(
            modelReserveBytes: profile,
            env: environment)
    }

    /// Resolve from a local `config.json`. The bounded read and digest bind a
    /// lower reserve to the exact measured execution profile; a missing,
    /// oversized, or modified config retains the conservative reserve.
    public static func reserveBytes(
        modelType: String?,
        configURL: URL,
        isVision: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt64 {
        guard let configData = KVEstimation.readBoundedConfigJSON(configURL) else {
            return UnifiedMemoryCap.resolvedActivationReserveBytes(env: environment)
        }
        return reserveBytes(
            modelType: modelType,
            architecture: KVEstimation.parseModelArchitecture(configData: configData),
            isVision: isVision,
            configSHA256: sha256Hex(configData),
            environment: environment)
    }

    static func profileReserveBytes(
        modelType: String?,
        architecture: ModelArchitecture,
        isVision: Bool,
        configSHA256: String?
    ) -> UInt64 {
        guard !isVision,
            configSHA256?.lowercased() == measuredGPTOSS20BConfigSHA256,
            matchesMeasuredGPTOSS20B(modelType, architecture)
        else {
            return UnifiedMemoryCap.defaultActivationReserveBytes
        }
        return gptOSS20BReserveBytes
    }

    /// Normalize an optional wire value from `ModelInfo`. Zero is never a valid
    /// resolved profile, so old or malformed records retain the conservative
    /// environment-aware fallback.
    static func reportedOrDefault(_ bytes: UInt64?) -> UInt64 {
        guard let bytes, bytes > 0 else {
            return UnifiedMemoryCap.resolvedActivationReserveBytes()
        }
        return UnifiedMemoryCap.resolvedActivationReserveBytes(
            modelReserveBytes: bytes)
    }

    /// Process-wide reserve for a residency set. MLX evaluations are serialized
    /// by the process-global eval lock, so transient working sets cannot overlap;
    /// the maximum resident-model reserve is sufficient and summing them would
    /// strand memory. An empty set stays conservative for the next unknown load.
    static func fleetReserveBytes<S: Sequence>(
        _ residentReserves: S,
        including candidate: UInt64? = nil
    ) -> UInt64 where S.Element == UInt64 {
        var reserve = candidate ?? 0
        for value in residentReserves {
            reserve = max(reserve, value)
        }
        return reserve > 0
            ? reserve
            : UnifiedMemoryCap.resolvedActivationReserveBytes()
    }

    /// Architecture binding for the measured gpt-oss-20b profile. The config
    /// digest above also covers the full per-layer quantization map, so it binds
    /// kernel/storage shape without depending on whichever catalog id carries
    /// the same checkpoint bytes. A missing or changed value fails closed to
    /// 5.5 GiB rather than extending one measurement to a new execution shape.
    private static func matchesMeasuredGPTOSS20B(
        _ modelType: String?,
        _ architecture: ModelArchitecture
    ) -> Bool {
        guard modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == "gpt_oss",
            architecture.numLayers == 24,
            architecture.kvHeads == 8,
            architecture.headDim == 64,
            architecture.globalHeadDim == nil,
            architecture.hiddenSize == 2_880,
            architecture.intermediateSize == 2_880,
            architecture.numLocalExperts == 32,
            architecture.numExpertsPerTok == 4,
            architecture.maxContextLength == 131_072,
            let layerTypes = architecture.layerTypes,
            layerTypes.count == 24
        else {
            return false
        }

        return layerTypes.enumerated().allSatisfy { index, layerType in
            layerType == (index.isMultiple(of: 2) ? "sliding_attention" : "full_attention")
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
