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
        residentPrefixCache: CBv2PagedPrefixCacheConfig? = nil
    ) throws -> PagedKVBackend {
        try PagedKVBackend(
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
                layerDTypes: layerDTypes),
            slabCommitment: .atFirstAdmission,
            residentPrefixCache: residentPrefixCache)
    }
}
