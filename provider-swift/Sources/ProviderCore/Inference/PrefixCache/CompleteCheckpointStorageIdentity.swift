import MLX
import MLXLLM
import MLXLMCommon

/// Storage facts read from the resolved backend, never from operator intent.
/// Precision and page geometry enter both the compatibility fingerprint and
/// disk namespace before a store can become eligible for reuse.
struct CompleteCheckpointStorageIdentity: Sendable {
    enum Target: Sendable {
        case recurrentFull
        case historicalAttention([CBv2LayerKind])
        case glm5Next([CBv2LayerKind])
    }

    let backendLayout: String
    let fingerprintFields: [String: String]
    let checkpointQuantization: PagedKVQuantizationConfig?

    init?(kind: EngineV2KVBackendKind, layerDTypes: [DType], pagedConfig: PagedKVPoolConfig?,
          target: Target = .recurrentFull, checkpointQuantization: PagedKVQuantizationConfig? = nil) {
        guard !layerDTypes.isEmpty,
            layerDTypes.allSatisfy({ $0 == .float16 || $0 == .bfloat16 || $0 == .float32 }),
            checkpointQuantization == nil || pagedConfig?.quantization == nil
        else { return nil }
        self.checkpointQuantization = checkpointQuantization
        var fields = ["storage.backend": kind.rawValue,
                      "storage.quantization": checkpointQuantization?.identity
                        ?? pagedConfig?.quantization?.identity ?? "native"]
        for (index, dtype) in layerDTypes.enumerated() {
            fields["storage.dtype.\(index)"] = EngineV2Factory.pagedPoolDTypeName(dtype)
        }
        fields["storage.layerCount"] = String(layerDTypes.count)
        switch kind {
        case .contiguous:
            guard pagedConfig == nil else { return nil }
            switch target {
            case .glm5Next:
                return nil
            case .recurrentFull:
                backendLayout = checkpointQuantization == nil
                    ? CBv2CompleteCheckpointManifest.layout
                    : CBv2CompleteCheckpointManifest.nativeQuantizedContiguousLayout
            case .historicalAttention(let kinds):
                let asymmetric = kinds.contains { $0.headDim != $0.valueHeadDim }
                guard let layers = try? (asymmetric
                    ? CBv2CheckpointAttentionLayer.resolveContiguousAsymmetric(layerKinds: kinds, dtypes: layerDTypes)
                    : CBv2CheckpointAttentionLayer.resolve(layerKinds: kinds, dtypes: layerDTypes))
                else { return nil }
                backendLayout = checkpointQuantization == nil
                    ? (asymmetric ? CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout
                        : CBv2CompleteCheckpointManifest.nativeContiguousHistoricalLayout)
                    : CBv2CompleteCheckpointManifest.nativeQuantizedContiguousHistoricalLayout
                Self.appendAttentionFields(layers, includeValueHeadDimension: asymmetric, to: &fields)
            }
        case .paged:
            guard let pagedConfig, let segmentBytes = pagedConfig.segmentSizeBytes,
                segmentBytes > 0, pagedConfig.pageSize > 0, pagedConfig.maxBufferLength > 0,
                pagedConfig.layerDTypes == layerDTypes
            else { return nil }
            switch target {
            case .glm5Next(let kinds):
                guard checkpointQuantization == nil, pagedConfig.quantization == nil,
                    pagedConfig.prefixSharingBlockSize == nil,
                    layerDTypes == Array(repeating: .float32, count: kinds.count),
                    let limits = pagedConfig.gatheredAttention,
                    limits.admissionMode == .stepOwned(.pinnedMetal),
                    let layers = try? CBv2CheckpointAttentionLayer.resolvePagedAsymmetric(
                        layerKinds: kinds, dtypes: layerDTypes) else { return nil }
                backendLayout = CBv2CompleteCheckpointManifest.glm5NextPagedLayout
                Self.appendAttentionFields(layers, includeValueHeadDimension: true, to: &fields)
                fields["storage.nativeProfile"] = "glm5_next_native_paged_full_state_serial_mtp_v1"
                // Arithmetic choices are not bitwise across policies; never
                // restore state written under a different one.
                fields["storage.executionPolicy"] = String(describing: GLM5NextManagedLoad.executionPolicy)
                fields["storage.maximumBatch"] = String(limits.maximumBatchSize)
                fields["storage.maximumQuery"] = String(limits.maximumQueryTokens)
                fields["storage.maximumContext"] = String(limits.maximumContextTokens)
                fields["storage.maximumPrefill"] = String(pagedConfig.maxPrefillChunk)
                fields["storage.inFlightGraphs"] = String(limits.maximumInFlightGraphs)
            case .recurrentFull:
                backendLayout = checkpointQuantization != nil
                    ? CBv2CompleteCheckpointManifest.nativeQuantizedPagedLayout
                    : (pagedConfig.quantization == nil
                        ? CBv2CompleteCheckpointManifest.pagedLayout
                        : CBv2CompleteCheckpointManifest.quantizedPagedLayout)
            case .historicalAttention(let kinds):
                let asymmetric = kinds.contains { $0.headDim != $0.valueHeadDim }
                guard !asymmetric || pagedConfig.gatheredAttention?.admissionMode == .stepOwned(.pinnedMetal),
                      let layers = try? (asymmetric
                        ? CBv2CheckpointAttentionLayer.resolvePagedAsymmetric(layerKinds: kinds, dtypes: layerDTypes)
                        : CBv2CheckpointAttentionLayer.resolve(layerKinds: kinds, dtypes: layerDTypes))
                else { return nil }
                backendLayout = checkpointQuantization != nil
                    ? CBv2CompleteCheckpointManifest.nativeQuantizedHistoricalLayout
                    : (pagedConfig.quantization != nil
                        ? CBv2CompleteCheckpointManifest.quantizedHistoricalLayout
                        : (asymmetric ? CBv2CompleteCheckpointManifest.pagedAsymmetricLayout
                            : CBv2CompleteCheckpointManifest.historicalAttentionLayout))
                Self.appendAttentionFields(layers, includeValueHeadDimension: asymmetric, to: &fields)
                if asymmetric, let limits = pagedConfig.gatheredAttention {
                    fields["storage.nativeProfile"] = "mimo-native-gathered-pages-v1"
                    fields["storage.maximumBatch"] = String(limits.maximumBatchSize)
                    fields["storage.maximumQuery"] = String(limits.maximumQueryTokens)
                    fields["storage.maximumContext"] = String(limits.maximumContextTokens)
                    fields["storage.maximumPrefill"] = String(pagedConfig.maxPrefillChunk)
                    fields["storage.inFlightGraphs"] = String(limits.maximumInFlightGraphs)
                }
            }
            fields["storage.pageSize"] = String(pagedConfig.pageSize)
            fields["storage.nativeOwnerIndices"] = pagedConfig.nativeLayerIndices.sorted().map(String.init).joined(separator: ",")
            fields["storage.segmentBytes"] = String(segmentBytes)
            fields["storage.maximumBufferBytes"] = String(pagedConfig.maxBufferLength)
        }
        fields["storage.layout"] = backendLayout
        fingerprintFields = fields
    }

    private static func appendAttentionFields(
        _ layers: [CBv2CheckpointAttentionLayer], includeValueHeadDimension: Bool,
        to fields: inout [String: String]
    ) {
        for (index, layer) in layers.enumerated() {
            let prefix = "storage.attention.\(index)."
            fields[prefix + "modelLayer"] = String(layer.modelLayer)
            fields[prefix + "owner"] = String(layer.owner)
            fields[prefix + "window"] = layer.window.map(String.init) ?? "full"
            fields[prefix + "kvHeads"] = String(layer.kvHeads)
            fields[prefix + "headDim"] = String(layer.headDim)
            if includeValueHeadDimension {
                fields[prefix + "valueHeadDim"] = String(layer.valueHeadDim)
            }
            fields[prefix + "queryHeads"] = String(layer.queryHeads)
            fields[prefix + "sinks"] = String(layer.hasSinks)
            fields[prefix + "dtype"] = layer.dtype.rawValue
        }
    }
}
