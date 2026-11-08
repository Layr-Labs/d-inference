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
        #expect(LocalInputModalities.of(vision) == ["text", "image"])
        #expect(LocalInputModalities.of(text) == ["text"])
        #expect(LocalInputModalities.list(image: true, video: true) == ["text", "image", "video"])
        #expect(LocalInputModalities.list(image: false, video: true) == ["text"])
        #expect(LocalModelLimits(window: 8, inputModalities: []) == LocalModelLimits(window: 8))
    }

    /// A pair's slot takes media only when its ranks serve a media contract (GLM and Qwen tensor parallel); every
    /// other pair (a pipeline, Gemma and MiMo) takes text alone, whatever the model takes on one Mac.
    @Test func aPairSlotWithoutAMediaContractTakesText() async {
        let bridge = Self.pairBridge()
        #expect(LocalInputModalities.of(pair: bridge) == ["text"])
        await bridge.shutdown()
    }

    /// The private image candidate profiles take still images on a pair, GLM's (`prepareClusterGLMImage`) and MiMo's
    /// (`prepareNativeMiMoMedia`'s cluster images), so their slots list images, and no video.
    @Test func aPairsImageCandidateTakesImages() async {
        for (glm, mimo) in [(Data("{}".utf8), nil), (nil, Data("{}".utf8))] as [(Data?, Data?)] {
            let bridge = Self.pairBridge(glmImages: glm, mimoImages: mimo)
            #expect(LocalInputModalities.of(pair: bridge) == ["text", "image"], "\(glm == nil ? "MiMo" : "GLM")")
            await bridge.shutdown()
        }
    }

    /// `darkbloom start` on one Mac (`ProviderLoop`): each advertised model's input, loaded or not, from the model's
    /// own word. This is the path that gives MiMo V2.6 image input in OpenCode and Hermes.
    @Test func darkbloomStartListsEachAdvertisedModelsInput() async throws {
        let loop = try await clusterPairMemberLoop(models: [], role: .solo)
        await loop.advertiseBypassingSupportedSetForTesting(ModelInfo(id: "org/vision", modelType: "gemma4",
            sizeBytes: 1, estimatedMemoryGb: 1, isVision: true))
        await loop.advertiseBypassingSupportedSetForTesting(ModelInfo(id: "org/text", modelType: "gpt_oss",
            sizeBytes: 1, estimatedMemoryGb: 1))
        #expect(await loop.localModelLimits("org/vision") == LocalModelLimits(inputModalities: ["text", "image"]))
        #expect(await loop.localModelLimits("org/text") == LocalModelLimits(inputModalities: ["text"]))
        #expect(await loop.localModelLimits("org/absent") == nil)
    }

    /// A model this Mac or its pair serves is listed with what its engine takes: a coordinator list that gives the same
    /// model images (the catalog's word, for your other Macs) doesn't add them to this Mac's entry. A Gemma 4 pair
    /// serves text alone.
    @Test func aTextOnlyPairListsNoImageWhateverTheCoordinatorLists() async throws {
        let gemma = "gemma-4-26b-qat-4bit"
        let mine = #"{"object":"list","data":[{"id":"\#(gemma)","object":"model","owned_by":"self","input_modalities":["text","image","video"],"metadata":{"provider_count":2}}]}"#
        let fixture = RouterFixture(route: .myMacs, localModels: [gemma], localLimits: [
            gemma: LocalModelLimits(contextLength: 65_536, maxOutputLength: 32_768, inputModalities: ["text"]),
        ]) { request in
            switch (request.url.path, request.route) {
            case ("/v1/models", "self"?): return .json(200, mine)
            default: return .json(404, "{}")
            }
        }
        let (entries, text) = try await Self.list(fixture)
        #expect(entries.map(\.id) == [gemma])
        #expect(entries.first?.ownedBy == "this-mac" && entries.first?.inputModalities == ["text"])
        #expect(!text.contains("image"), "\(text)")
    }

    private static func pairBridge(glmImages: Data? = nil, mimoImages: Data? = nil) -> EngineV2Bridge {
        EngineV2Bridge(engine: PrefillGateEngine(), modelId: "pair/model",
            tokenizer: TokenizerHandle(InputTokenizer()), eosTokenIds: [], defaultMaxTokens: 32_768,
            maxConcurrentRequests: 1, kvBudget: GlobalKVCacheBudget(memorySnapshot: {
                .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
            }), draftMiMoImageConfiguration: mimoImages, clusterGLMImageConfiguration: glmImages)
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
