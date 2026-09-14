import Foundation
import MLX
import MLXLMCommon
@testable import MLXVLM
import Testing

@testable import ProviderCore

@Suite("Owned Flash-Next VLM routing and isolated path")
struct Qwen4OwnedVLMRoutingTests {
    private let owned = ModelMediaPolicy.ownedQwen4ModelID
    private var configuration: [String: Any] {
        ["model_type":"qwen4_exp", "language_model_only":false,
         "quantization":["bits":4,"group_size":64,"mode":"affine"],
         "text_config":["model_type":"qwen4_exp_text", "hidden_size":2560,"num_hidden_layers":48],
         "vision_config":["model_type":"qwen4_exp","depth":27,"hidden_size":1152,"num_heads":16,"out_hidden_size":2560,
            "intermediate_size":4304,"num_position_embeddings":2304,"hidden_act":"gelu_pytorch_tanh",
            "patch_size":16,"spatial_merge_size":2,"temporal_patch_size":2,"deepstack_visual_indexes":[]]]
    }

    @Test func ownedFullDeclarationSelectsVisionWhileOtherContractsRemainClosed() throws {
        let full = configuration
        #expect(ModelMediaPolicy.advertisesMedia(full, modelID: owned))
        #expect(ModelContainerLoading.factorySelection(for: full, modelID: owned) == .vision)
        let vlm = try JSONDecoder().decode(Qwen4ExpVLMConfiguration.self,
            from: JSONSerialization.data(withJSONObject: full))
        #expect(vlm.servesVision)
        #expect(vlm.imageTokenId == 248056 && vlm.videoTokenId == 248057)
        #expect(vlm.visionStartTokenId == 248053 && vlm.visionEndTokenId == 248054)
        for id in [nil, "other", owned + "-extra", "prefix/" + owned] as [String?] {
            #expect(!ModelMediaPolicy.advertisesMedia(full, modelID: id))
            #expect(ModelContainerLoading.factorySelection(for: full, modelID: id) == .text)
        }
        for overlay in [nil, true] as [Bool?] {
            var candidate = full
            candidate["language_model_only"] = overlay
            #expect(!ModelMediaPolicy.advertisesMedia(candidate, modelID: owned))
        }
        for (key, value): (String, Any) in [
            ("model_type", "qwen4_exp_text"), ("vision_config", [:]),
            ("language_model_only", 0), ("language_model_only", "false"),
        ] {
            var candidate = full; candidate[key] = value
            #expect(!ModelMediaPolicy.advertisesMedia(candidate, modelID: owned))
        }
    }

    @Test func stagedPathDiscoveryAndResolverAgreeWithoutOldFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qwen4-vlm-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("isolated")
        try writeSnapshot(staged, config: configuration)
        let cache = root.appendingPathComponent("cache")
        let old = cache.appendingPathComponent("models--DarkBloom--Qwen3.8-Flash-Next-Q4-mtp/snapshots/old")
        var textOnly = configuration; textOnly["language_model_only"] = true
        try writeSnapshot(old, config: textOnly)
        let env = [Qwen4LocalModelPath.environmentKey: staged.path]
        #expect(Qwen4LocalModelPath.directory(environment: env) == staged.resolvingSymlinksInPath())
        #expect(ModelScanner.resolveLocalPath(modelID: owned, environment: env) == staged.resolvingSymlinksInPath())
        #expect(ProviderLoop.modelIsVLM(at: staged, modelID: owned))
        #expect(!ProviderLoop.modelIsVLM(at: staged, modelID: "unqualified"))
        #expect(ModelScanner.configDeclaresVision(at: staged.appendingPathComponent("config.json"), modelID: owned))
        let models = ModelScanner.scanAllModels(in: cache, environment: env)
        #expect(models.count == 1 && models[0].id == owned && models[0].isVision == true)
        let original = ModelScanner.scanAllModels(in: cache, environment: [:])
        #expect(original.count == 1 && original[0].isVision == nil)
        for path in ["", "relative/path", root.appendingPathComponent("absent").path] {
            let invalid = [Qwen4LocalModelPath.environmentKey: path]
            #expect(Qwen4LocalModelPath.directory(environment: invalid) == nil)
            #expect(ModelScanner.resolveLocalPath(modelID: owned, environment: invalid) == nil)
            #expect(ModelScanner.scanAllModels(in: cache, environment: invalid).isEmpty)
        }
        var wrong = configuration; wrong["model_type"] = "gemma4"
        try JSONSerialization.data(withJSONObject: wrong).write(to: staged.appendingPathComponent("config.json"))
        #expect(Qwen4LocalModelPath.directory(environment: env) == nil)
        #expect(ModelScanner.scanAllModels(in: cache, environment: env).isEmpty)
    }

    @Test func nativeD72TowerUsesSixteenPlanesAndPreservesBudgetRefusal() {
        let wrapper = BudgetOnlyQwen4VisionSeam()
        #expect(EngineV2VisionPrefill.qwenAttentionHeadFactor(wrapper) == 16)
        let limits = VisionTowerBudget.Limits(maxBufferBytes: 1 << 20,
            attentionElementBytes: 2, headFactor: EngineV2VisionPrefill.qwenAttentionHeadFactor(wrapper))
        #expect(VisionTowerBudget.attentionBytes(patches: 256, bytesPerSquaredPatch: limits.bytesPerSquaredPatch) == 2 << 20)
        if case .reject = VisionTowerBudget.admit(grids: [THW(1,16,16)], subject: "synthetic image", limits: limits) {}
        else { Issue.record("D72 tower must refuse before allocating the oversized attention plane") }
    }

    private func writeSnapshot(_ directory: URL, config: [String: Any]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
        try Data(#"{"weight_map":{"fixture.weight":"model.safetensors"}}"#.utf8)
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        try Data(repeating: 0, count: 8).write(to: directory.appendingPathComponent("model.safetensors"))
    }
}

/// Only metadata is exercised; invoking pixels or positions is an error.
private final class BudgetOnlyQwen4VisionSeam: QwenVisionSeamModel {
    var visionSeamConfiguration: Qwen35VisionSeamConfiguration { .init(
        imagePlaceholderTokenId:248056,videoPlaceholderTokenId:248057,
        imagePositionTokenId:248056,videoPositionTokenId:248057,
        visionStartTokenId:248053,visionEndTokenId:248054,
        spatialMergeSize:2,temporalPatchSize:2,attention:.causal) }
    var imagePlaceholderTokenId: Int { 248056 }
    var videoPlaceholderTokenId: Int { 248057 }
    var visionTowerAttentionGeometry: (hiddenSize: Int, numHeads: Int) { (1152,16) }
    func positionResult(tokens: MLXArray, imageGrids: [THW]?, videoGrids: [THW]?, attentionMask: MLXArray?) throws -> Qwen35PositionResult { throw Unexpected.invocation }
    func visionFeatures(imagePixels: MLXArray?, imageGrids: [THW]?, videoPixels: MLXArray?, videoGrids: [THW]?) throws -> Qwen35VisionFeatures { throw Unexpected.invocation }
    private enum Unexpected: Error { case invocation }
}
