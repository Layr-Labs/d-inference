import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

private typealias F = ToolIntegrationFixtures

/// The tools take whether a model served here reasons from the engine that serves it: a model the endpoint lists with
/// `reasoning` among its `supported_features` reasons in OpenCode, offline too, and when the catalog lists it without
/// (Qwen 3.8 27B today); one it lists without reasons nowhere, whatever the catalog says. A model served elsewhere
/// takes the catalog's word, with the `reasoning` the coordinator's list gives.
@Suite("Reasoning from the engine")
struct EngineReasoningTests {
    static let qwen38 = "EigenLabs/Qwen3.8-27B-4bit-mtp"

    /// What this Mac's `/v1/models` lists for Qwen 3.8 and an instruct-only build.
    private static let listed = """
    {"object":"list","data":[
      {"id":"\(qwen38)","object":"model","owned_by":"this-mac","context_length":262144,
       "max_model_len":262144,"max_output_length":262144,"input_modalities":["text","image"],
       "supported_features":["reasoning"]},
      {"id":"org/qwen3-vl-instruct","object":"model","owned_by":"this-mac","context_length":131072,
       "input_modalities":["text","image"],"supported_features":[]},
      {"id":"odd","object":"model","owned_by":"this-mac","context_length":65536,"supported_features":"reasoning"}
    ]}
    """

    /// The production catalog's Qwen 3.8 row (chat, tools, vision: no `reasoning`), and a row that says reasoning for
    /// the instruct build.
    private static let catalog = CatalogSnapshot(models: [
        CatalogModel(id: qwen38, s3Name: qwen38, displayName: "Qwen 3.8 27B", modelType: "text", sizeGb: 1,
                     maxContextLength: 262_144, maxOutputLength: 65_536, capabilities: ["chat", "tools", "vision"]),
        CatalogModel(id: "org/qwen3-vl-instruct", s3Name: "org/qwen3-vl-instruct", displayName: "Qwen3 VL Instruct",
                     modelType: "text", sizeGb: 1, maxContextLength: 131_072, maxOutputLength: 32_768,
                     capabilities: ["chat", "tools", "vision", "reasoning"]),
    ], aliases: [])

    private static func fetched(_ body: String = listed) async throws -> [EndpointModel] {
        let directory = try TemporaryDirectory()
        let keyFile = try directory.write(F.freshToken(), to: "local_token", mode: 0o600)
        let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile)
        return try await IntegrationModels.fetch(endpoint) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response as URLResponse)
        }
    }

    @Test func qwen38ServedHereReasonsOfflineAndOverACatalogWithoutReasoning() async throws {
        let listed = try await Self.fetched()
        for catalog in [nil, Self.catalog] {
            let models = IntegrationModels.resolve(listed, catalog: catalog)
            let qwen = try #require(models.first { $0.id == Self.qwen38 })
            #expect(qwen.reasoning, "catalog: \(catalog == nil ? "offline" : "without reasoning")")
            #expect(qwen.imageInput)
        }
    }

    /// The engine's word holds both ways for a model served here: the catalog can't add reasoning a model's type
    /// doesn't take (its effort would be ignored).
    @Test func aModelServedHereThatDoesntReasonGetsNoneWhateverTheCatalogSays() async throws {
        let listed = try await Self.fetched()
        for catalog in [nil, Self.catalog] {
            let instruct = try #require(IntegrationModels.resolve(listed, catalog: catalog)
                .first { $0.id == "org/qwen3-vl-instruct" })
            #expect(!instruct.reasoning, "catalog: \(catalog == nil ? "offline" : "with reasoning")")
        }
        // A list that isn't a list of names says nothing.
        #expect(IntegrationModels.resolve(listed, catalog: nil).first { $0.id == "odd" }?.reasoning == false)
    }

    /// Offline, a tool's entry written before (from a catalog without reasoning) doesn't take the engine's reasoning
    /// away; without the engine's word, the entry's still stands.
    @Test func anEarlierEntryDoesntTakeTheEnginesReasoningAway() async throws {
        let offline = try #require(IntegrationModels.resolve(try await Self.fetched(), catalog: nil)
            .first { $0.id == Self.qwen38 })
        let entry = IntegrationModel.Entry(displayName: "Qwen 3.8 27B", contextLength: 262_144, outputLimit: 65_536,
                                           tools: true, imageInput: true, reasoning: false)
        let kept = offline.keeping(entry)
        #expect(kept.reasoning && kept.name == "Qwen 3.8 27B (this Mac)")
        let silent = IntegrationModels.resolve([EndpointModel(id: Self.qwen38, ownedBy: "this-mac")], catalog: nil)[0]
        #expect(!silent.keeping(entry).reasoning)
        #expect(silent.keeping(IntegrationModel.Entry(reasoning: true)).reasoning)
    }

    /// Your other Macs' and the network's models: the catalog decides, and the coordinator's list, which says the
    /// catalog's word in OpenRouter's names, adds `reasoning` when the catalog can't be read.
    @Test func aModelServedElsewhereTakesTheCatalogsWord() async throws {
        let body = """
        {"object":"list","data":[
          {"id":"\(Self.qwen38)","object":"model","owned_by":"my-macs","context_length":262144,"supported_features":[]},
          {"id":"glm-5.3-flash","object":"model","owned_by":"darkbloom","context_length":262144,
           "supported_features":["reasoning","tools"]}
        ]}
        """
        let listed = try await Self.fetched(body)
        let withCatalog = IntegrationModels.resolve(listed, catalog: CatalogSnapshot(models: [
            CatalogModel(id: Self.qwen38, s3Name: Self.qwen38, displayName: "Qwen 3.8 27B", modelType: "text",
                         sizeGb: 1, maxContextLength: 262_144, maxOutputLength: 65_536,
                         capabilities: ["chat", "tools", "reasoning"]),
        ], aliases: []))
        #expect(withCatalog.first { $0.id == Self.qwen38 }?.reasoning == true, "the catalog's word, elsewhere")
        let offline = IntegrationModels.resolve(listed, catalog: nil)
        #expect(offline.first { $0.id == "glm-5.3-flash" }?.reasoning == true, "the coordinator's list adds it")
        #expect(offline.first { $0.id == Self.qwen38 }?.reasoning == false)
    }

    @Test func openCodeOffersQwen38Reasoning() async throws {
        let models = IntegrationModels.resolve(try await Self.fetched(), catalog: Self.catalog).filter { $0.id != "odd" }
        let opencode = try #require(F.newText(OpenCodeConfigPlan.plan(existing: nil, fileName: "opencode.jsonc",
            endpoint: F.endpoint, models: models, provider: F.provider, home: F.home)))
        let lines = opencode.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasSuffix("\"\(Self.qwen38)\": {") })
        let qwen = lines[start..<min(lines.count, start + 4)].joined(separator: "\n")
        #expect(qwen.contains(#""input": ["text", "image"], "output": ["text"], "reasoning": { "supported": true }"#),
                "\(qwen)")
        let other = try #require(lines.firstIndex { $0.hasSuffix("\"org/qwen3-vl-instruct\": {") })
        #expect(!lines[other..<min(lines.count, other + 4)].joined().contains("reasoning"))
    }
}
