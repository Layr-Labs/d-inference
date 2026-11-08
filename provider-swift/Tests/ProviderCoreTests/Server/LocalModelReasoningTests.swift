import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import ProviderCore

/// This Mac's `/v1/models` says which of its models reason, in the coordinator's words (`supported_features`), from
/// the table that takes every reasoning effort for them (`ReasoningEffortPolicy.reasons`): `["reasoning"]` for a model
/// whose type reasons, `[]` for one whose type doesn't, nothing when its type isn't known here. Before, the list said
/// nothing of reasoning, so OpenCode took it from the catalog alone, and Qwen 3.8 27B, whose catalog row lacks
/// `reasoning`, was offered no reasoning though it takes every effort. Your other Macs' and the network's models keep
/// the coordinator's list, which is the catalog's.
@Suite("This Mac's /v1/models says which models reason")
struct LocalModelReasoningTests {
    static let qwen38 = "EigenLabs/Qwen3.8-27B-4bit-mtp"

    /// The router's list, each entry's JSON by model ID.
    static func entries(_ app: LocalInferenceApplication) async throws -> [String: [String: Any]] {
        let body = try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get, headers: RouterFixture.authorized) { response in
                #expect(response.status == .ok)
                return Data(buffer: response.body)
            }
        }
        let root = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let data = root?["data"] as? [[String: Any]] ?? []
        return Dictionary(data.compactMap { entry in (entry["id"] as? String).map { ($0, entry) } },
                          uniquingKeysWith: { first, _ in first })
    }

    static func features(_ entry: [String: Any]?) -> [String]? { entry?["supported_features"] as? [String] }

    @Test func aModelThatReasonsOnThisMacListsReasoningWithoutTheCatalog() async throws {
        // No account key: the list is this Mac's alone, and the catalog is never read.
        let fixture = RouterFixture(route: .myMacs, key: nil, localModels: [Self.qwen38, "org/instruct", "org/unknown"],
            localLimits: [Self.qwen38: LocalModelLimits(window: 262_144, inputModalities: ["text", "image"])],
            modelTypes: [Self.qwen38: "qwen3_5", "org/instruct": "qwen3_vl_moe"])
        let entries = try await Self.entries(fixture.app)
        #expect(Self.features(entries[Self.qwen38]) == ["reasoning"])
        #expect(entries[Self.qwen38]?["input_modalities"] as? [String] == ["text", "image"])
        #expect(Self.features(entries["org/instruct"]) == [], "a type that doesn't reason lists no feature")
        #expect(entries["org/unknown"]?.keys.contains("supported_features") == false, "no type, no word")
        #expect(fixture.upstream.requests.isEmpty)
    }

    /// Every family this Mac serves is listed as the effort table treats it: a model that takes `reasoning_effort` is
    /// one that lists `reasoning`, and only those.
    @Test func everyFamilyIsListedAsTheEffortTableSaysItReasons() async throws {
        let served: [(id: String, type: String, reasons: Bool)] = [
            (Self.qwen38, "qwen3_5", true),
            ("qwen3.5-9b", "qwen3_5", true),
            ("qwen3.6-35b-a3b-vl-mtp-mxfp8", "qwen3_5_moe", true),
            ("ternary-bonsai-2-27b", "prism_hadamard_qwen35", true),
            (Qwen4SupportPolicy.ownedModelID, "qwen4_exp", true),
            ("gemma-4-26b-qat-4bit", "gemma4", true),
            ("gemma-4-26b-text", "gemma4_text", true),
            ("diffusion-gemma", "diffusion_gemma", true),
            ("gpt-oss-20b", "gpt_oss", true),
            (EngineV2SupportedModels.nemotron35LightningRegistryModelID, "nemotron_h", true),
            (NemotronSuperServingPolicy.modelID, "nemotron_h_omni", true),
            ("mimo-v2.6-flash-mopd", "mimo_v2", true),
            ("glm-5.3-flash", "glm5_next", true),
            ("flint", "flint", true),
            ("org/qwen3-vl-instruct", "qwen3_vl_moe", false),
            ("org/llama", "llama", false),
        ]
        let fixture = RouterFixture(route: .myMacs, key: nil, localModels: served.map(\.id),
            modelTypes: Dictionary(uniqueKeysWithValues: served.map { ($0.id, $0.type) }))
        let entries = try await Self.entries(fixture.app)
        for model in served {
            #expect(ReasoningEffortPolicy.reasons(modelID: model.id, modelType: model.type) == model.reasons,
                    "the effort table: \(model.type)")
            #expect(Self.features(entries[model.id]) == (model.reasons ? ["reasoning"] : []), "listed: \(model.type)")
        }
    }

    /// For your other Macs' and the network's models, the coordinator's word stands: its `supported_features` are the
    /// catalog's capabilities in OpenRouter's names, and the list keeps them.
    @Test func yourMacsAndTheNetworkKeepTheCoordinatorsFeatures() async throws {
        let mine = #"{"object":"list","data":[{"id":"mimo","object":"model","owned_by":"self","supported_features":["reasoning","tools"],"metadata":{"provider_count":1}}]}"#
        let network = #"{"object":"list","data":[{"id":"gpt-oss-120b","object":"model","owned_by":"darkbloom","supported_features":["tools"]}]}"#
        let fixture = RouterFixture(route: .myMacsFirst, localModels: ["here"], modelTypes: ["here": "gpt_oss"]) {
            request in
            switch (request.url.path, request.route) {
            case ("/v1/models", "self"?): return .json(200, mine)
            case ("/v1/models", nil): return .json(200, network)
            default: return .json(404, "{}")
            }
        }
        let entries = try await Self.entries(fixture.app)
        #expect(entries["mimo"]?["owned_by"] as? String == "my-macs")
        #expect(Self.features(entries["mimo"]) == ["reasoning", "tools"])
        #expect(entries["gpt-oss-120b"]?["owned_by"] as? String == "darkbloom")
        #expect(Self.features(entries["gpt-oss-120b"]) == ["tools"])
        #expect(Self.features(entries["here"]) == ["reasoning"])
    }

    /// A model this Mac serves is listed with its engine's word: the coordinator's entry for the same model (the
    /// catalog's, which lacks `reasoning` for Qwen 3.8) doesn't replace it.
    @Test func aModelServedHereListsTheEnginesWordNotTheCoordinators() async throws {
        let mine = #"{"object":"list","data":[{"id":"\#(Self.qwen38)","object":"model","owned_by":"self","supported_features":["tools"],"metadata":{"provider_count":2}}]}"#
        let fixture = RouterFixture(route: .myMacs, localModels: [Self.qwen38], modelTypes: [Self.qwen38: "qwen3_5"]) {
            request in
            switch (request.url.path, request.route) {
            case ("/v1/models", "self"?): return .json(200, mine)
            default: return .json(404, "{}")
            }
        }
        let entries = try await Self.entries(fixture.app)
        #expect(entries.count == 1)
        #expect(entries[Self.qwen38]?["owned_by"] as? String == "this-mac")
        #expect(Self.features(entries[Self.qwen38]) == ["reasoning"])
    }

    /// `darkbloom start` on one Mac (`ProviderLoop`): each advertised model, loaded or not, is listed as its type says.
    @Test func darkbloomStartListsWhichAdvertisedModelsReason() async throws {
        let loop = try await clusterPairMemberLoop(models: [], role: .solo)
        await loop.advertiseBypassingSupportedSetForTesting(ModelInfo(id: Self.qwen38, modelType: "qwen3_5",
            sizeBytes: 1, estimatedMemoryGb: 1, isVision: true))
        await loop.advertiseBypassingSupportedSetForTesting(ModelInfo(id: "org/instruct", modelType: "qwen3_vl_moe",
            sizeBytes: 1, estimatedMemoryGb: 1))
        let app = await loop.makeLocalEndpointApplication(LocalInferenceHTTPConfig(host: "127.0.0.1", port: 0,
            authToken: RouterFixture.localKey, router: RouterFixture(route: .myMacs, key: nil).routerConfig))
        let entries = try await Self.entries(app)
        #expect(Self.features(entries[Self.qwen38]) == ["reasoning"])
        #expect(Self.features(entries["org/instruct"]) == [])
    }

    /// A pair's leader beside Darkbloom (`ProviderLoop`, a cluster member) lists the pair's model as its type says,
    /// before its slot is up and once it is: whether a model reasons doesn't depend on the pair's mode.
    @Test func thePairsLeaderListsThatItsModelReasons() async throws {
        let loop = try await clusterPairMemberLoop()
        let config = LocalInferenceHTTPConfig(host: "127.0.0.1", port: 0, authToken: RouterFixture.localKey,
            router: RouterFixture(route: .myMacs, key: nil).routerConfig)
        await loop.advertiseBypassingSupportedSetForTesting(ModelInfo(id: clusterPairFixtureModel, modelType: "qwen3_5",
            sizeBytes: 1, estimatedMemoryGb: 1))
        let before = try await Self.entries(await loop.makeLocalEndpointApplication(config))
        #expect(Self.features(before[clusterPairFixtureModel]) == ["reasoning"], "before the slot is up")
        let owner = ScriptedPairOwner()
        _ = try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        let entries = try await Self.entries(await loop.makeLocalEndpointApplication(config))
        #expect(Self.features(entries[clusterPairFixtureModel]) == ["reasoning"])
        #expect(entries[clusterPairFixtureModel]?["input_modalities"] as? [String] == ["text"])
        #expect(await loop.retireClusterPairSlot(reason: "test"))
    }

    /// The pair's own API (`darkbloom cluster local`, `DistributedLocalServer`) lists its model as its installed type
    /// says.
    @Test func thePairsOwnAPIListsThatItsModelReasons() async throws {
        let family = try #require(ParityFamily.all.first { $0.name == "qwen3.8-27b" })
        let directory = try family.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try ParityClusterSession(family: family, directory: directory)
        let host = DistributedLocalServer(session: session,
            config: .init(host: "127.0.0.1", port: 0, authToken: parityToken,
                          router: RouterFixture(route: .myMacs, key: nil).routerConfig),
            firstTokenBudgetPolicy: try .init(baseMilliseconds: 60_000, millisecondsPerInputToken: 0),
            tokenizerLoader: { _ in TokenizerHandle(family.tokenizer) })
        try await host.start()
        let port = try #require(await host.status.boundPort)
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/v1/models")))
        request.setValue("Bearer \(parityToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        _ = await host.stop(until: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entry = (root?["data"] as? [[String: Any]])?.first { $0["id"] as? String == family.modelID }
        #expect(Self.features(entry) == ["reasoning"], "\(String(decoding: data, as: UTF8.self))")
    }
}
