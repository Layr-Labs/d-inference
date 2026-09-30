import XCTest
import MLX
import MLXLMCommon
@testable import ProviderCore

final class MiMoCompleteCheckpointIdentityTests: XCTestCase {
    private func kinds(value: Int = 128) -> [CBv2LayerKind] {
        [.init(attention: .full, hasSinks: false, headDim: 192, valueHeadDim: value,
               kvHeads: 4, queryHeads: 64, modelLayerIndex: 0),
         .init(attention: .slidingWindow(128), hasSinks: true, headDim: 192, valueHeadDim: value,
               kvHeads: 8, queryHeads: 64, modelLayerIndex: 1)]
    }

    func testAsymmetricHistoricalIdentityPreservesBothWidthsAndWindow() throws {
        let a = try XCTUnwrap(CompleteCheckpointStorageIdentity(kind: .contiguous,
            layerDTypes: [.bfloat16, .bfloat16], pagedConfig: nil, target: .historicalAttention(kinds())))
        let b = try XCTUnwrap(CompleteCheckpointStorageIdentity(kind: .contiguous,
            layerDTypes: [.bfloat16, .bfloat16], pagedConfig: nil, target: .historicalAttention(kinds(value: 64))))
        XCTAssertEqual(a.backendLayout, CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout)
        XCTAssertEqual(a.fingerprintFields["storage.attention.0.headDim"], "192")
        XCTAssertEqual(a.fingerprintFields["storage.attention.0.valueHeadDim"], "128")
        XCTAssertEqual(a.fingerprintFields["storage.attention.1.window"], "128")
        XCTAssertNotEqual(a.fingerprintFields, b.fingerprintFields)
        XCTAssertNil(CompleteCheckpointStorageIdentity(kind: .contiguous,
            layerDTypes: [.bfloat16, .bfloat16], pagedConfig: nil,
            target: .historicalAttention(kinds(value: 192))))
    }

    func testNoPersistentAssistantOrDeclaredOnlyDtypeCanEnterTargetOnlyStore() {
        func storage(_ assistant: EngineV2SlotFactory.CompleteCheckpointAssistant,
                     _ observed: [DType]?, _ declared: [DType]? = [.bfloat16, .bfloat16]) -> CompleteCheckpointStorageIdentity? {
            EngineV2SlotFactory.completeCheckpointStorage(kind: .contiguous, layerKinds: kinds(),
                supportsRecurrent: false, supportsHistoricalAttention: true,
                modelDTypes: declared, nativeDTypes: observed, pagedConfig: nil, assistant: assistant)
        }
        XCTAssertNotNil(storage(.none, [.bfloat16, .bfloat16]))
        XCTAssertNil(storage(.none, nil))
        XCTAssertNil(storage(.none, [.float32, .float32]))
        XCTAssertNil(storage(.none, [.bfloat16]))
        for assistant in [EngineV2SlotFactory.CompleteCheckpointAssistant.stateless,
                          .persistentCodec, .unsupportedPersistent] {
            XCTAssertNil(storage(assistant, [.bfloat16, .bfloat16]))
        }
    }

    func testMiMoNumericalFlagsInvalidateOnlyExplicitMiMoIdentity() throws {
        func identity(_ model: String?, _ value: String) throws -> CBv2CompleteCheckpointIdentity {
            try XCTUnwrap(PrefixCachePolicy.completeCheckpointIdentity(
                modelAggregateHash: String(repeating: "a", count: 64),
                promptContractID: String(repeating: "b", count: 64),
                binaryHash: String(repeating: "c", count: 64),
                loadedMetallibHash: String(repeating: "d", count: 64), osVersion: "test-os",
                mtpConfig: .init(), assistantCodecID: nil, environment: [:],
                processEnvironment: ["DARKBLOOM_MIMO_BLOCK_BATCH_PREFILL": value], nativeModelType: model))
        }
        XCTAssertNotEqual(try identity("mimo_v2", "0").numericsFingerprint,
                          try identity("mimo_v2", "1").numericsFingerprint)
        XCTAssertEqual(try identity(nil, "0").numericsFingerprint, try identity(nil, "1").numericsFingerprint)
        XCTAssertEqual(try identity("qwen4_exp", "0").numericsFingerprint,
                       try identity("qwen4_exp", "1").numericsFingerprint)
    }
}
