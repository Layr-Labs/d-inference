import MLX
import MLXLLM
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
        #expect(resolve(.persistentExactHistory)?.backendLayout == CBv2CompleteCheckpointManifest.layout)
        #expect(resolve(.stateless) == nil)
        #expect(resolve(.unsupportedPersistent) == nil)
        #expect(resolve(.persistentCodec, types: nil) == nil)
    }

    /// Inkling 2: sliding-window and full attention beside recurrent state on
    /// the native paged pool select the SDK's historical recurrent layouts;
    /// the DSpark drafter's history rides only while its rounds keep it.
    @Test("Sliding windows beside recurrent state select the historical recurrent layouts")
    func historicalRecurrentCapability() {
        let kinds = [
            CBv2LayerKind(attention: .slidingWindow(1024), headDim: 128, kvHeads: 8, queryHeads: 16),
            CBv2LayerKind(attention: .full, headDim: 128, kvHeads: 8, queryHeads: 16),
        ]
        let types: [DType] = [.bfloat16, .bfloat16]
        let config = PagedKVPoolConfig(capacityBytes: 1 << 20, segmentSizeBytes: 64 << 10, layerDTypes: types)
        func resolve(_ assistant: EngineV2SlotFactory.CompleteCheckpointAssistant, keepsHistory: Bool = true,
                     kind: EngineV2KVBackendKind = .paged, nativeTypes: [DType]? = [.bfloat16, .bfloat16],
                     modelTypes: [DType]? = nil, quantization: PagedKVQuantizationConfig? = nil)
            -> CompleteCheckpointStorageIdentity?
        {
            EngineV2SlotFactory.completeCheckpointStorage(kind: kind, layerKinds: kinds,
                supportsRecurrent: true, supportsHistoricalAttention: false, isInkling2: true,
                modelDTypes: modelTypes, nativeDTypes: nativeTypes, pagedConfig: kind == .paged ? config : nil,
                assistant: assistant, assistantKeepsHistory: keepsHistory,
                checkpointQuantization: quantization)
        }
        let plain = resolve(.none)
        #expect(plain?.backendLayout == CBv2CompleteCheckpointManifest.pagedHistoricalRecurrentLayout)
        #expect(plain?.checkpointQuantization == nil)
        #expect(plain?.fingerprintFields["storage.layout"] == CBv2CompleteCheckpointManifest.pagedHistoricalRecurrentLayout)
        #expect(plain?.fingerprintFields["storage.attention.0.window"] == "1024")
        #expect(plain?.fingerprintFields["storage.attention.1.window"] == "full")
        #expect(resolve(.persistentHistorical)?.backendLayout
            == CBv2CompleteCheckpointManifest.pagedHistoricalRecurrentMTPLayout)
        #expect(resolve(.persistentHistorical, keepsHistory: false)?.backendLayout
            == CBv2CompleteCheckpointManifest.pagedHistoricalRecurrentLayout)
        #expect(resolve(.none, modelTypes: types)?.backendLayout
            == CBv2CompleteCheckpointManifest.pagedHistoricalRecurrentLayout)
        // Only an assistant that exports its own history, the paged pool,
        // and the actual native dtypes.
        #expect(resolve(.persistentCodec) == nil)
        #expect(resolve(.persistentExactHistory) == nil)
        #expect(resolve(.stateless) == nil)
        #expect(resolve(.unsupportedPersistent) == nil)
        #expect(resolve(.none, kind: .contiguous) == nil)
        #expect(resolve(.none, nativeTypes: nil) == nil)
        #expect(resolve(.none, nativeTypes: [.float16, .float16]) == nil)
        #expect(resolve(.none, modelTypes: [.float16, .float16]) == nil)
        // The fleet's default checkpoint profile is lossy; this layout keeps
        // native rows, and the identity says so.
        let profiled = resolve(.none, quantization: EngineV2KVQuantizationSelection.balanced.configuration)
        #expect(profiled?.backendLayout == CBv2CompleteCheckpointManifest.pagedHistoricalRecurrentLayout)
        #expect(profiled?.checkpointQuantization == nil)
        #expect(profiled?.fingerprintFields["storage.quantization"] == "native")
    }

    /// The historical recurrent codec was reviewed for Inkling 2 alone: another
    /// model with Inkling's layer shape (sliding windows beside recurrent state
    /// on the native paged pool) gets no complete checkpoint store, as before
    /// that codec, whatever its assistant, dtypes or checkpoint profile.
    @Test("Only Inkling 2 selects the historical recurrent layouts")
    func historicalRecurrentNeedsInkling2() {
        let kinds = [
            CBv2LayerKind(attention: .slidingWindow(1024), headDim: 128, kvHeads: 8, queryHeads: 16),
            CBv2LayerKind(attention: .full, headDim: 128, kvHeads: 8, queryHeads: 16),
        ]
        let types: [DType] = [.bfloat16, .bfloat16]
        let config = PagedKVPoolConfig(capacityBytes: 1 << 20, segmentSizeBytes: 64 << 10, layerDTypes: types)
        func resolve(_ assistant: EngineV2SlotFactory.CompleteCheckpointAssistant, modelTypes: [DType]? = nil,
                     quantization: PagedKVQuantizationConfig? = nil) -> CompleteCheckpointStorageIdentity?
        {
            EngineV2SlotFactory.completeCheckpointStorage(kind: .paged, layerKinds: kinds,
                supportsRecurrent: true, supportsHistoricalAttention: false, modelDTypes: modelTypes,
                nativeDTypes: types, pagedConfig: config, assistant: assistant,
                checkpointQuantization: quantization)
        }
        for assistant in [EngineV2SlotFactory.CompleteCheckpointAssistant.none, .stateless, .persistentCodec,
                          .persistentExactHistory, .persistentHistorical, .unsupportedPersistent] {
            #expect(resolve(assistant) == nil, "\(assistant)")
            #expect(resolve(assistant, modelTypes: types) == nil, "\(assistant)")
        }
        #expect(resolve(.none, quantization: EngineV2KVQuantizationSelection.balanced.configuration) == nil)
    }

    @Test("A persistent assistant keeps history only while its rounds run")
    func assistantHistoryFollowsTheRoundDriver() {
        typealias Assistant = EngineV2SlotFactory.CompleteCheckpointAssistant
        #expect(Assistant.keepsHistory(Inkling2DSparkDrafter.defaultMTPConfig()) == CBv2MTPConfig.envEnabled)
        #expect(!Assistant.keepsHistory(CBv2MTPConfig()))
        #expect(!Assistant.keepsHistory(Inkling2DSparkDrafter.defaultMTPConfig(maxDraftTokens: 0)))
    }
}
