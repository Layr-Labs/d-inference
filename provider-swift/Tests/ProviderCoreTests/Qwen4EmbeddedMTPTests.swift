import Foundation
import Testing

@testable import ProviderCore

private actor Qwen4EmbeddedCatalog: SpecDecCatalogLooking {
    private(set) var cachedCalls = 0
    private(set) var calls = 0

    func cachedModel(id: String) -> CatalogModel? {
        cachedCalls += 1
        return nil
    }

    func model(id: String) async throws -> CatalogModel? {
        calls += 1
        return nil
    }
}

/// Header-only synthetic fixture. No MLX allocation or real model is needed
/// to prove declaration, byte accounting, and exact metadata revalidation.
private func makeNativeQwen4MTPFixture(
    prefix: String = "mtp.", includeMTP: Bool = true
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-qwen4-mtp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(#"{"model_type":"qwen4_exp","text_config":{"model_type":"qwen4_exp_text","mtp_num_hidden_layers":1}}"#.utf8)
        .write(to: root.appendingPathComponent("config.json"))

    let shard = "model-00001-of-00001.safetensors"
    let key = includeMTP ? prefix + "fc_embedding.weight" : "model.language_model.norm.weight"
    var header = try JSONSerialization.data(withJSONObject: [
        key: ["dtype": "F32", "shape": [4], "data_offsets": [0, 16]],
    ], options: .sortedKeys)
    while !header.count.isMultiple(of: 8) { header.append(0x20) }
    var headerLength = UInt64(header.count).littleEndian
    var shardData = withUnsafeBytes(of: &headerLength) { Data($0) }
    shardData.append(header)
    shardData.append(Data(repeating: 0, count: 16))
    try shardData.write(to: root.appendingPathComponent(shard))
    let index = try JSONSerialization.data(withJSONObject: [
        "metadata": ["total_size": 16, "format": "mlx"],
        "weight_map": [key: shard],
    ], options: .sortedKeys)
    try index.write(to: root.appendingPathComponent("model.safetensors.index.json"))
    return root
}

@Suite("Native Qwen4 embedded MTP artifact contract")
struct Qwen4EmbeddedMTPTests {
    private let modelID = "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp"

    @Test func declarationRequiresIntegralHeadCountAndNativeTypes() {
        for count: Any in [true, false, 0, -1, 1.5, 5, "1", Double.nan, Double.infinity] {
            #expect(!SpecDecStore.declaresNativeQwen4MTP([
                "model_type": "qwen4_exp", "mtp_num_hidden_layers": count,
            ]))
        }
        for count in 1...4 {
            for type in ["qwen4_exp", "qwen4_exp_text", " QWEN4_EXP_TEXT "] {
                #expect(SpecDecStore.declaresNativeQwen4MTP([
                    "model_type": type,
                    "text_config": ["model_type": "qwen4_exp_text", "mtp_num_hidden_layers": count],
                ]))
            }
        }
        #expect(!SpecDecStore.declaresNativeQwen4MTP([
            "model_type": "qwen3_5",
            "text_config": ["model_type": "qwen4_exp_text", "mtp_num_hidden_layers": 1],
        ]))
        #expect(!SpecDecStore.declaresNativeQwen4MTP([
            "model_type": "qwen4_exp",
            "text_config": ["model_type": "qwen3_5", "mtp_num_hidden_layers": 1],
        ]))
    }

    @Test func malformedNestedDeclarationCannotFallBackToRootCount() {
        for text: Any in ["not-an-object", NSNull(), ["model_type": 1],
            ["model_type": "qwen4_exp_text", "mtp_num_hidden_layers": "1"]]
        {
            #expect(!SpecDecStore.declaresNativeQwen4MTP([
                "model_type": "qwen4_exp", "mtp_num_hidden_layers": 1,
                "text_config": text,
            ]))
        }
    }

    @Test("native in-tree heads resolve without catalog or mtplx metadata",
          arguments: ["mtp.", "language_model.mtp."])
    func nativeInlineResolvesAndRevalidates(prefix: String) async throws {
        let directory = try makeNativeQwen4MTPFixture(prefix: prefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = Qwen4EmbeddedCatalog()
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(storeRoot: directory.appendingPathComponent("unused-store"),
                                      cdnBaseURL: "http://127.0.0.1:1"),
            catalog: catalog)
        let declaration = SpecDecStore.inlineDeclarationProbe(directory: directory)
        #expect(declaration == .declared)
        let preparation = await funnel.prepare(.init(
            modelId: modelID, modelType: "qwen4_exp",
            enabled: MTPMode.auto.enablesMTP(
                forModelType: "qwen4_exp", embeddedArtifactDeclared: declaration.mayDeclareEmbeddedArtifact,
                modelID: modelID),
            localPath: nil, modelDirectory: directory, inlineDeclaration: declaration,
            allowDownload: false, environment: [:]))
        let artifact = try #require(preparation.artifact)
        #expect(artifact.source == .inline)
        #expect(artifact.artifactBytes == 16)
        #expect(artifact.additionalWeightBytes == 0)
        #expect(preparation.status == .candidate(artifact))
        #expect(SpecDecStore.revalidateForLoad(artifact).artifact == artifact)
        #expect(await catalog.cachedCalls == 0)
        #expect(await catalog.calls == 0)
        await funnel.shutdown()
    }

    @Test func declaredHeadWithoutIndexedTensorsStaysTargetOnly() async throws {
        let directory = try makeNativeQwen4MTPFixture(includeMTP: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = Qwen4EmbeddedCatalog()
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(storeRoot: directory.appendingPathComponent("unused-store"),
                                      cdnBaseURL: "http://127.0.0.1:1"),
            catalog: catalog)
        let preparation = await funnel.prepare(.init(
            modelId: modelID, modelType: "qwen4_exp", enabled: true,
            localPath: nil, modelDirectory: directory,
            inlineDeclaration: SpecDecStore.inlineDeclarationProbe(directory: directory),
            allowDownload: false, environment: [:]))
        #expect(preparation.artifact == nil)
        #expect(preparation.status.reason == .inlineArtifactInvalid)
        #expect(await catalog.cachedCalls == 0)
        #expect(await catalog.calls == 0)
        await funnel.shutdown()
    }

    @Test("native config and mixed index metadata remain bound to admitted bytes",
          arguments: ["config.json", "model.safetensors.index.json"])
    func metadataChangeRejectsAdmittedArtifact(file: String) throws {
        let directory = try makeNativeQwen4MTPFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = try SpecDecStore.inspectInlineArtifact(directory: directory).get()
        let url = directory.appendingPathComponent(file)
        var bytes = try Data(contentsOf: url)
        // Valid JSON with identical semantics still differs from the admitted
        // metadata bytes; revalidation must preserve its exact identity.
        bytes.append(0x0A)
        try bytes.write(to: url)
        let result = SpecDecStore.revalidateForLoad(artifact)
        #expect(result.artifact == nil)
        #expect(result.reason == .inlineArtifactInvalid)
    }

    @Test func disappearingInlineShardRejectsAdmittedArtifact() throws {
        let directory = try makeNativeQwen4MTPFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = try SpecDecStore.inspectInlineArtifact(directory: directory).get()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("model-00001-of-00001.safetensors"))
        let result = SpecDecStore.revalidateForLoad(artifact)
        #expect(result.artifact == nil)
        #expect(result.reason == .inlineArtifactInvalid)
    }

    @Test func nativeTargetNamespacesRemainClosed() {
        for type in ["qwen4_exp", "qwen4_exp_text"] {
            #expect(SpecDecArtifactFunnel.isInlineQwenTarget(modelType: type))
            #expect(SpecDecArtifactFunnel.isInlineTarget(modelType: type))
        }
        for type in [nil, "qwen4_exp_mtp", "qwen4_exp_text_assistant", "qwen3_5", "nemotron_h"] as [String?] {
            #expect(!SpecDecArtifactFunnel.isQwen4ExpTarget(modelType: type))
        }
        #expect(SpecDecArtifactFunnel.isInlineTarget(modelType: "nemotron_h"))
    }

    @Test func existingNemotronDeclarationRemainsIndependent() {
        let nemotron: [String: Any] = [
            "model_type": "nemotron_h",
            "darkbloom_embedded_mtp": ["architecture": "nemotron_h_attention_moe", "version": 1],
            "num_nextn_predict_layers": 1,
            "mtp_layers_block_type": ["attention", "moe"],
        ]
        #expect(SpecDecStore.declaresNemotronLightningMTP(nemotron))
        #expect(!SpecDecStore.declaresNativeQwen4MTP(nemotron))
    }
}
