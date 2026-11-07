import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import NIOCore
import Testing
@testable import ProviderCore

/// The local `/v1/models` says what each model takes, from the engine: images for a model this Mac serves with vision
/// (`ModelInfo.isVision`, which the coordinator routes images on) or a pair whose slot takes media, catalog or not.
/// Before, the list carried no capability, so OpenCode and Hermes took image input from the catalog alone: MiMo V2.6,
/// listed text-only there, got none, and offline no model did.
@Suite("This Mac's /v1/models says what each model takes")
struct LocalModelInputTests {
    private static func list(_ fixture: RouterFixture) async throws -> (entries: [LocalRouterModelEntry], text: String) {
        try await fixture.app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get, headers: RouterFixture.authorized) { response in
                #expect(response.status == .ok)
                let list = try JSONDecoder().decode(LocalRouterModelList.self, from: Data(buffer: response.body))
                return (list.data, String(buffer: response.body))
            }
        }
    }

    @Test func aVisionModelOnThisMacListsImageInputWithoutTheCatalog() async throws {
        // No account key: the list is this Mac's alone, and the catalog is never read.
        let fixture = RouterFixture(route: .myMacs, key: nil, localLimits: [
            "here": LocalModelLimits(window: 262_144, inputModalities: ["text", "image"]),
            "busy": LocalModelLimits(inputModalities: ["text"]),
        ])
        let (entries, text) = try await Self.list(fixture)
        #expect(entries.first { $0.id == "here" }?.inputModalities == ["text", "image"])
        #expect(text.contains(#""input_modalities":["text","image"]"#), "\(text)")
        #expect(entries.first { $0.id == "busy" }?.inputModalities == ["text"])
        #expect(entries.first { $0.id == "cut" }?.inputModalities == nil, "an engine that says nothing lists nothing")
        #expect(fixture.upstream.requests.isEmpty)
    }

    @Test func yourMacsModelsKeepTheInputTheCoordinatorLists() async throws {
        let mine = #"{"object":"list","data":[{"id":"mimo","object":"model","owned_by":"self","input_modalities":["text","image","video","audio"],"metadata":{"provider_count":1}}]}"#
        let fixture = RouterFixture(route: .myMacs, localLimits: ["here": LocalModelLimits(inputModalities: ["text"])]) {
            request in
            switch (request.url.path, request.route) {
            case ("/v1/models", "self"?): return .json(200, mine)
            default: return .json(404, "{}")
            }
        }
        let (entries, _) = try await Self.list(fixture)
        #expect(entries.first { $0.id == "mimo" }?.inputModalities == ["text", "image", "video", "audio"])
        #expect(entries.first { $0.id == "mimo" }?.ownedBy == "my-macs")
        #expect(entries.first { $0.id == "here" }?.inputModalities == ["text"])
    }

    @Test func oneMacTakesImagesForAModelThatAdvertisesVision() {
        let vision = ModelInfo(id: "org/vision", modelType: "mimo_v2", sizeBytes: 1, estimatedMemoryGb: 1, isVision: true)
        let text = ModelInfo(id: "org/text", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
        #expect(LocalModelLimits.inputModalities(of: vision) == ["text", "image"])
        #expect(LocalModelLimits.inputModalities(of: text) == ["text"])
        #expect(LocalModelLimits.inputModalities(image: true, video: true) == ["text", "image", "video"])
        #expect(LocalModelLimits.inputModalities(image: false, video: true) == ["text"])
        #expect(LocalModelLimits(window: 8, inputModalities: []) == LocalModelLimits(window: 8))
    }

    /// A pair's slot takes media only when its ranks serve a media contract (GLM and Qwen tensor parallel); every
    /// other pair (a pipeline, Gemma and MiMo) takes text alone, whatever the model takes on one Mac.
    @Test func aPairSlotWithoutAMediaContractTakesText() async {
        let bridge = EngineV2Bridge(engine: PrefillGateEngine(), modelId: "pair/model",
            tokenizer: TokenizerHandle(InputTokenizer()), eosTokenIds: [], defaultMaxTokens: 32_768,
            maxConcurrentRequests: 1, kvBudget: GlobalKVCacheBudget(memorySnapshot: {
                .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
            }))
        #expect(bridge.pairInputModalities == ["text"])
        await bridge.shutdown()
    }
}

private struct InputTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [1] }
}
