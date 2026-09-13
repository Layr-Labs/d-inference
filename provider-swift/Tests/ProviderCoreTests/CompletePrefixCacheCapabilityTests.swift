import MLX
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Complete SSD loaded capability selection")
struct CompletePrefixCacheCapabilityTests {
    @Test("Historical targets keep stateless assistants and require actual segmented storage")
    func historicalCapability() {
        let kinds = [CBv2LayerKind(attention: .slidingWindow(1024), headDim: 256, kvHeads: 8, queryHeads: 16)]
        let config = PagedKVPoolConfig(capacityBytes: 1 << 20, segmentSizeBytes: 64 << 10, layerDTypes: [.float16])
        func resolve(_ assistant: EngineV2SlotFactory.CompleteCheckpointAssistant,
                     enabled: Bool = true, kind: EngineV2KVBackendKind = .paged,
                     nativeTypes: [DType]? = [.float16], actualConfig: PagedKVPoolConfig? = nil)
            -> CompleteCheckpointStorageIdentity?
        {
            EngineV2SlotFactory.completeCheckpointStorage(kind: kind, layerKinds: kinds,
                supportsRecurrent: false, supportsHistoricalAttention: enabled,
                modelDTypes: nil, nativeDTypes: nativeTypes, pagedConfig: actualConfig ?? config,
                assistant: assistant)
        }
        #expect(resolve(.none)?.backendLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout)
        #expect(resolve(.stateless)?.backendLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout)
        #expect(resolve(.persistentCodec) == nil)
        #expect(resolve(.unsupportedPersistent) == nil)
        #expect(resolve(.stateless, enabled: false) == nil)
        #expect(resolve(.stateless, kind: .contiguous) == nil)
        #expect(resolve(.stateless, nativeTypes: nil) == nil)
        #expect(resolve(.stateless, nativeTypes: [.float32]) == nil)
        var unsegmented = config
        unsegmented.segmentSizeBytes = nil
        #expect(resolve(.stateless, actualConfig: unsegmented) == nil)
    }

    @Test("Recurrent Qwen keeps its existing persistent-assistant and dtype contract")
    func recurrentCapability() {
        let kinds = [CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 1, queryHeads: 2)]
        func resolve(_ assistant: EngineV2SlotFactory.CompleteCheckpointAssistant, types: [DType]? = [.float16])
            -> CompleteCheckpointStorageIdentity?
        {
            EngineV2SlotFactory.completeCheckpointStorage(kind: .contiguous, layerKinds: kinds,
                supportsRecurrent: true, supportsHistoricalAttention: false, modelDTypes: types,
                nativeDTypes: nil, pagedConfig: nil, assistant: assistant)
        }
        #expect(resolve(.none)?.backendLayout == CBv2CompleteCheckpointManifest.layout)
        #expect(resolve(.persistentCodec)?.backendLayout == CBv2CompleteCheckpointManifest.layout)
        #expect(resolve(.stateless) == nil)
        #expect(resolve(.unsupportedPersistent) == nil)
        #expect(resolve(.persistentCodec, types: nil) == nil)
    }
}
