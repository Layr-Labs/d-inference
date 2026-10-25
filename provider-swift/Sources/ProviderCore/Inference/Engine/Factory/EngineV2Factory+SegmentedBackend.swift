import MLX
import MLXLMCommon

extension EngineV2Factory {
    /// The caller has already admitted this slot's unified-memory grant. The
    /// shared serving pool (`PagedKVBackend.segmented`) starts empty and follows
    /// that grant; it has no second physical-RAM fraction, eager-pool budget, or
    /// model-demand ceiling. Native Admission reserves complete process C
    /// before subsequent page allocation.
    static func makeSegmentedPagedBackend(
        admittedGrantBytes: Int,
        layerKinds: [CBv2LayerKind],
        layerDTypes: [DType],
        schedulerConfig: CBv2SchedulerConfig,
        maxContextLength: Int?,
        maxBufferLength: Int,
        quantization: PagedKVQuantizationConfig? = nil,
        nativeLayerIndices: Set<Int> = [],
        residentPrefixCache: CBv2PagedPrefixCacheConfig? = nil
    ) throws -> PagedKVBackend {
        try PagedKVBackend.segmented(
            admittedGrantBytes: admittedGrantBytes,
            layerKinds: layerKinds,
            layerDTypes: layerDTypes,
            maxPrefillChunk: max(
                schedulerConfig.prefillChunkSize,
                schedulerConfig.soloPrefillStripeTokens ?? 0),
            nominalMaxSequenceLength: max(1, maxContextLength ?? 8192),
            maxBufferLength: maxBufferLength,
            quantization: quantization,
            nativeLayerIndices: nativeLayerIndices,
            residentPrefixCache: residentPrefixCache)
    }
}
