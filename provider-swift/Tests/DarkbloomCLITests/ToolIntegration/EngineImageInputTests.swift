import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

private typealias F = ToolIntegrationFixtures

/// The tools take image input from this Mac's engine as well as the catalog: a model the endpoint lists with `image`
/// among its `input_modalities` gets image input in OpenCode and Hermes, offline too, and when the catalog lists it
/// text only (MiMo V2.6 today). Reasoning still comes from the catalog alone.
@Suite("Image input from the engine")
struct EngineImageInputTests {
    /// What this Mac's `/v1/models` lists for MiMo V2.6 and GPT-OSS.
    private static let listed = """
    {"object":"list","data":[
      {"id":"mimo-v2.6-flash-mopd","object":"model","owned_by":"this-mac","context_length":1048576,
       "max_model_len":1048576,"max_output_length":1048576,"input_modalities":["text","image"]},
      {"id":"gpt-oss-20b","object":"model","owned_by":"this-mac","context_length":131072,"input_modalities":["text"]},
      {"id":"odd","object":"model","owned_by":"this-mac","context_length":65536,"input_modalities":"image"}
    ]}
    """

    /// The production catalog's MiMo row: text only, with reasoning and tools.
    private static let catalog = CatalogSnapshot(models: [
        CatalogModel(id: "mimo-v2.6-flash-mopd", s3Name: "mimo-v2.6-flash-mopd", displayName: "MiMo V2.6 Flash",
                     modelType: "text", sizeGb: 1, maxContextLength: 1_048_576, maxOutputLength: 131_072,
                     capabilities: ["chat", "reasoning", "tools"]),
    ], aliases: [])

    private static func fetched() async throws -> [EndpointModel] {
        let directory = try TemporaryDirectory()
        let keyFile = try directory.write(F.freshToken(), to: "local_token", mode: 0o600)
        let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile)
        return try await IntegrationModels.fetch(endpoint) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (Data(listed.utf8), response as URLResponse)
        }
    }

    @Test func theEndpointsInputModalitiesAreRead() async throws {
        let models = try await Self.fetched()
        #expect(models.map(\.inputModalities) == [["text", "image"], ["text"], nil], "a malformed list reads as none")
        #expect(models.map(\.contextLength) == [1_048_576, 131_072, 65_536])
        #expect(models.map(\.takesImages) == [true, false, false])
        #expect(EndpointModel(id: "upper", inputModalities: ["TEXT", "Image"]).takesImages, "in any case")
    }

    @Test func aModelTheEngineSaysTakesImagesGetsImageInputOfflineAndOverATextOnlyCatalog() async throws {
        let listed = try await Self.fetched()
        for catalog in [nil, Self.catalog] {
            let models = IntegrationModels.resolve(listed, catalog: catalog)
            let mimo = try #require(models.first { $0.id == "mimo-v2.6-flash-mopd" })
            #expect(mimo.imageInput, "catalog: \(catalog == nil ? "offline" : "text only")")
            // Reasoning is the catalog's word alone.
            #expect(mimo.reasoning == (catalog != nil))
            #expect(models.first { $0.id == "gpt-oss-20b" }?.imageInput == false)
            #expect(models.first { $0.id == "odd" }?.imageInput == false)
        }
        // A tool's entry written before (text only) doesn't take the engine's image input away offline.
        let offline = try #require(IntegrationModels.resolve(listed, catalog: nil).first { $0.id == "mimo-v2.6-flash-mopd" })
        let entry = IntegrationModel.Entry(displayName: "MiMo V2.6 Flash", contextLength: 1_048_576,
                                           outputLimit: 32_768, tools: true, imageInput: false, reasoning: true)
        let kept = offline.keeping(entry)
        #expect(kept.imageInput && kept.reasoning && kept.name == "MiMo V2.6 Flash (this Mac)")
        // Without the engine's word, the entry's still stands.
        let silent = IntegrationModels.resolve([EndpointModel(id: "mimo-v2.6-flash-mopd", ownedBy: "this-mac")],
                                               catalog: nil)[0]
        #expect(!silent.keeping(entry).imageInput)
    }

    /// A model's entry in an OpenCode config as the planner writes it: its key line, name, limit and capabilities.
    private static func openCodeEntry(_ id: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasSuffix("\"\(id)\": {") }) else { return nil }
        return lines[start..<min(lines.count, start + 4)].joined(separator: "\n")
    }

    @Test func openCodeAndHermesGetTheImageInput() async throws {
        let models = IntegrationModels.resolve(try await Self.fetched(), catalog: Self.catalog)
            .filter { $0.id != "odd" }
        let opencode = try #require(F.newText(OpenCodeConfigPlan.plan(existing: nil, fileName: "opencode.jsonc",
            endpoint: F.endpoint, models: models, provider: F.provider, home: F.home)))
        let mimo = try #require(Self.openCodeEntry("mimo-v2.6-flash-mopd", in: opencode))
        #expect(mimo.contains(#""input": ["text", "image"], "output": ["text"], "reasoning": { "supported": true }"#),
                "\(mimo)")
        let gpt = try #require(Self.openCodeEntry("gpt-oss-20b", in: opencode))
        #expect(gpt.contains(#""input": ["text"]"#), "\(gpt)")

        let hermes = try #require(F.newText(HermesConfigPlan.plan(existing: nil, endpoint: F.endpoint, models: models,
                                                                   provider: F.provider)))
        #expect(hermes.contains("      \"mimo-v2.6-flash-mopd\":\n        context_length: 1048576\n"
            + "        supports_vision: true\n"), "\(hermes)")
        #expect(hermes.contains("      \"gpt-oss-20b\":\n        context_length: 131072\n"))
        #expect(!hermes.contains("      \"gpt-oss-20b\":\n        context_length: 131072\n        supports_vision"))
    }
}
