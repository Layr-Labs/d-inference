import Foundation
import MLX
import MLXLMCommon

extension EngineV2Factory {
    /// The caller has already admitted this slot's unified-memory grant. A
    /// segmented pool starts empty and follows that grant; it has no second
    /// physical-RAM fraction, eager-pool budget, or model-demand ceiling.
    /// Native construction validates dtype, owner/borrower geometry, window
    /// rings, per-segment Metal buffer limits and kernel addressability. Native
    /// Admission reserves complete process C before subsequent page allocation.
    static func makeSegmentedPagedBackend(
        admittedGrantBytes: Int,
        layerKinds: [CBv2LayerKind],
        layerDTypes: [DType],
        schedulerConfig: CBv2SchedulerConfig,
        maxContextLength: Int?,
        maxBufferLength: Int,
        quantization: PagedKVQuantizationConfig? = nil,
        nativeLayerIndices: Set<Int> = [],
        residentPrefixCache: CBv2PagedPrefixCacheConfig? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PagedKVBackend {
        let retention = segmentRetentionEnabled(environment: environment)
        return try PagedKVBackend(
            layerKinds: layerKinds,
            config: PagedKVPoolConfig(
                capacityBytes: admittedGrantBytes,
                dtype: layerDTypes.first ?? .float16,
                maxPrefillChunk: max(
                    schedulerConfig.prefillChunkSize,
                    schedulerConfig.soloPrefillStripeTokens ?? 0),
                nominalMaxSequenceLength: max(1, maxContextLength ?? 8192),
                maxBufferLength: maxBufferLength,
                segmentSizeBytes: 64 << 20,
                layerDTypes: layerDTypes,
                quantization: quantization,
                nativeLayerIndices: nativeLayerIndices,
                retainedFreeSegmentBytes: retention
                    ? min(retainedFreeSegmentCapBytes, admittedGrantBytes / 8) : 0,
                hostZeroedSegments: retention
                    && environment[segmentHostZerosEnvironmentKey] != "0"),
            slabCommitment: .atFirstAdmission,
            residentPrefixCache: residentPrefixCache)
    }

    /// Free segment backing a pool may keep across requests, so admission
    /// reuses evaluated KV segments instead of allocating, filling and fencing
    /// new ones each time (bounded to an eighth of the slot grant).
    static let retainedFreeSegmentCapBytes = 2 << 30

    /// `DARKBLOOM_TTFT_SEGMENT_RETENTION=0` restores release-time segment
    /// retirement and the per-segment device zero fill plus stream fence;
    /// `DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS=0` keeps retention with device fills.
    static let segmentRetentionEnvironmentKey = "DARKBLOOM_TTFT_SEGMENT_RETENTION"
    static let segmentHostZerosEnvironmentKey = "DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS"

    static func segmentRetentionEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[segmentRetentionEnvironmentKey] != "0"
    }
}
