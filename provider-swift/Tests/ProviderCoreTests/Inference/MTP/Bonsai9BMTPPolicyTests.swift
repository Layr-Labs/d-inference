import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

private actor BonsaiMTPTestCatalog: SpecDecCatalogLooking {
    private(set) var calls = 0
    func cachedModel(id: String) -> CatalogModel? { calls += 1; return nil }
    func model(id: String) async throws -> CatalogModel? { calls += 1; return nil }
}

@Suite("Bonsai 9B automatic MTP policy")
struct Bonsai9BMTPPolicyTests {
    @Test("the 9B candidate defaults to exact acceptance", arguments: [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID])
    func defaultAcceptancePreservesTargetSampling(modelID: String) {
        #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:],
            modelID: modelID).acceptance == .exact)
        #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:],
            modelID: "prism-ml/bonsai-27b").acceptance
            == .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta))
        #expect(MTPAcceptancePolicy.resolve(global: "typical",
            byModel: [modelID: "exact"],
            modelID: modelID).acceptance == .exact)
    }

    @Test("exact 9B defaults inspect local overrides or the validated catalog", arguments: [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID])
    func localCandidatePreservesScopeAndFallbacks(modelID: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonsai9b-mtp-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Artifact funnel fixture only; the native loader separately verifies
        // all F16/Q4 head tensors, geometry and target binding before activation.
        try Data(#"{"model_type":"qwen3_5_mtp","text_config":{"mtp_num_hidden_layers":1}}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        try Data(repeating: 0x5a, count: 128)
            .write(to: directory.appendingPathComponent("model.safetensors"))
        let catalog = BonsaiMTPTestCatalog()
        let funnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(storeRoot: directory.appendingPathComponent("store"),
                                     cdnBaseURL: "http://127.0.0.1:1"), catalog: catalog)
        let cases: [(String, String, Bool, String?, [String: String], MTPFallbackReason?)] = [
            (modelID, "prism_hadamard_qwen35", true, directory.path, [:], nil),
            (modelID, "prism_hadamard_qwen35", true, nil, [:], .artifactNotCached),
            (modelID, "prism_hadamard_qwen35", true, " ", [:], .artifactNotCached),
            (modelID, "prism_hadamard_qwen35", true, "/missing-bonsai-head", [:], .localArtifactInvalid),
            (modelID, "prism_hadamard_qwen35", false, directory.path, [:], .configDisabled),
            (modelID, "prism_hadamard_qwen35", true, directory.path, ["DARKBLOOM_CBV2_MTP": "0"], .killSwitchDisabled),
            ("prism-ml/Ternary-Bonsai-2-4B-mlx-2bit", "prism_hadamard_qwen35", true, directory.path, [:], .configDisabled),
            ("prism-ml/bonsai-27b", "prism_hadamard_qwen35", true, directory.path, [:], .configDisabled),
            (modelID.uppercased(), "prism_hadamard_qwen35", true, directory.path, [:], .configDisabled),
        ]
        for (id, type, enabled, path, environment, reason) in cases {
            let result = await funnel.prepare(.init(modelId: id, modelType: type, enabled: enabled && MTPMode.auto.enablesMTP(
                forModelType: type, embeddedArtifactDeclared: false, modelID: id),
                localPath: path, allowDownload: false, environment: environment))
            #expect(result.status.reason == reason)
            #expect((result.artifact != nil) == (reason == nil))
            if reason == nil { #expect(result.artifact?.source == .local) }
        }
        #expect(await catalog.calls == 2)
        await funnel.shutdown()
    }

    @Test("9B uses fixed depth two only with a request-stateful drafter", arguments: [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID])
    func depthIsBoundedAndExactIdentityScoped(modelID: String) {
        let candidate = MTPAutomaticVerificationPolicy.draftDepthPolicy(
            usesRequestStatefulDrafter: true, modelID: modelID)
        #expect(candidate.maximum == 2 && candidate.fixed == 2)
        for id in ["prism-ml/bonsai-27b", "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit",
                   modelID.uppercased()] {
            let other = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                usesRequestStatefulDrafter: true, modelID: id)
            #expect(other.maximum == CBv2MTPConfig.testedMaxDraftTokens && other.fixed == nil)
        }
        let stateless = MTPAutomaticVerificationPolicy.draftDepthPolicy(
            usesRequestStatefulDrafter: false, modelID: modelID)
        #expect(stateless.fixed == MTPAutomaticVerificationPolicy.initialDraftTokens)
    }
}
