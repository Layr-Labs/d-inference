import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

private func catalogModel(
    _ id: String, display: String, type: String = "text", context: Int? = nil, output: Int? = nil,
    capabilities: [String]? = nil
) -> CatalogModel {
    CatalogModel(id: id, s3Name: id, displayName: display, modelType: type, sizeGb: 1,
                 maxContextLength: context, maxOutputLength: output, capabilities: capabilities)
}

private func catalog(_ models: [CatalogModel], aliases: [CatalogAlias] = []) -> CatalogSnapshot {
    CatalogSnapshot(models: models, aliases: aliases)
}

private func alias(_ id: String, display: String, build: String) -> CatalogAlias {
    CatalogAlias(id: id, displayName: display, desiredBuild: build, previousBuild: nil, retiredBuilds: nil,
                 primaryBuild: nil)
}

/// Records the one request and answers with `status` and `body`.
private final class RecordingTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let status: Int
    let body: String

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    var transport: IntegrationModels.Transport {
        { request in
            self.lock.withLock { self.recorded.append(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (Data(self.body.utf8), response as URLResponse)
        }
    }
}

@Suite("Integration models")
struct IntegrationModelsTests {
    @Test("offline: the endpoint's ID and context, tools on, text only, no reasoning claim")
    func offlineFallback() {
        let models = IntegrationModels.resolve(
            [EndpointModel(id: "qwen3.8-27b", ownedBy: "local", contextLength: 131_072)], catalog: nil)
        #expect(models == [IntegrationModel(
            id: "qwen3.8-27b", name: "qwen3.8-27b (this Mac)", location: .thisMac, contextLength: 131_072,
            outputLimit: 32_768, tools: true, imageInput: false, reasoning: false, fallback: .init())])
    }

    @Test("without the catalog, a tool's entry keeps its name, capabilities, context and output; the endpoint's win")
    func keepingAToolsEntry() {
        let listed = [EndpointModel(id: "qwen3.8-27b", ownedBy: "this-mac", contextLength: 131_072)]
        let online = catalog([catalogModel("qwen3.8-27b", display: "Qwen 3.8 27B", context: 262_144, output: 8_192,
                                           capabilities: ["tools", "vision", "thinking"])])
        let described = IntegrationModels.resolve(listed, catalog: online)[0]
        let entry = IntegrationModel.Entry(displayName: "Qwen 3.8 27B", contextLength: 131_072, outputLimit: 8_192,
                                           tools: true, imageInput: true, reasoning: true)
        #expect(described.fallback == nil && described.keeping(entry) == described, "the catalog's word stands")
        // Offline, and a catalog that doesn't list the model.
        for snapshot in [nil, catalog([])] {
            let guessed = IntegrationModels.resolve(listed, catalog: snapshot)[0]
            #expect(guessed.name == "qwen3.8-27b (this Mac)" && !guessed.imageInput && guessed.outputLimit == 32_768)
            #expect(guessed.keeping(nil) == guessed, "with no entry, what is known")
            let kept = guessed.keeping(entry)
            #expect(kept.name == described.name && kept.tools && kept.imageInput && kept.reasoning)
            #expect(kept.contextLength == 131_072 && kept.outputLimit == 8_192)
        }
        // Where the model runs comes from the endpoint; a context it doesn't give, from the entry.
        let moved = IntegrationModels.resolve([EndpointModel(id: "qwen3.8-27b", ownedBy: "my-macs")], catalog: nil)[0]
            .keeping(entry)
        #expect(moved.name == "Qwen 3.8 27B (your Macs)")
        #expect(moved.contextLength == 131_072 && moved.outputLimit == 8_192)
        // The endpoint's context and output cap win over the entry's; for another context, the output is worked out
        // again.
        let capped = IntegrationModels.resolve(
            [EndpointModel(id: "qwen3.8-27b", contextLength: 16_384, maxOutputLength: 2_048)], catalog: nil)[0]
        #expect(capped.keeping(entry).contextLength == 16_384 && capped.keeping(entry).outputLimit == 2_048)
        let smaller = IntegrationModels.resolve([EndpointModel(id: "qwen3.8-27b", contextLength: 16_384)], catalog: nil)
        #expect(smaller[0].keeping(entry).outputLimit == 4_096)
        #expect(IntegrationModel.displayName(in: "GLM (Darkbloom network, billed)") == "GLM")
        #expect(IntegrationModel.displayName(in: "My own name") == "My own name")
    }

    @Test("the catalog names the model and sets its capabilities and output cap; the endpoint's context wins")
    func catalogEnrichment() {
        let snapshot = catalog([catalogModel("qwen3.8-27b", display: "Qwen 3.8 27B", context: 262_144, output: 16_384,
                                             capabilities: ["Tools", "vision", "thinking"])])
        let models = IntegrationModels.resolve(
            [EndpointModel(id: "qwen3.8-27b", ownedBy: "local", contextLength: 131_072)], catalog: snapshot)
        #expect(models == [IntegrationModel(
            id: "qwen3.8-27b", name: "Qwen 3.8 27B (this Mac)", location: .thisMac, contextLength: 131_072,
            outputLimit: 16_384, tools: true, imageInput: true, reasoning: true)])
    }

    @Test("limits: output is min(cap, context / 4); the router's cap beats the catalog's; no context means none")
    func limits() {
        let snapshot = catalog([
            catalogModel("a", display: "A", context: 8_192, output: 100_000),
            catalogModel("b", display: "B", output: 4_096),
            catalogModel("c", display: "C"),
        ])
        let models = IntegrationModels.resolve([
            EndpointModel(id: "a", ownedBy: "local"),
            EndpointModel(id: "b", ownedBy: "local", contextLength: 65_536, maxOutputLength: 12_000),
            EndpointModel(id: "c", ownedBy: "local"),
        ], catalog: snapshot)
        #expect(models.map(\.contextLength) == [8_192, 65_536, nil])
        #expect(models.map(\.outputLimit) == [2_048, 12_000, nil])
        for model in models {
            if let context = model.contextLength, let output = model.outputLimit { #expect(output < context) }
        }
    }

    @Test("capability aliases are the coordinator's; a catalog list without a tool alias means no tools")
    func capabilityAliases() {
        let cases: [([String], Bool, Bool, Bool)] = [
            (["tools"], true, false, false), (["tool_use"], true, false, false),
            (["tool_calling"], true, false, false), (["function_calling"], true, false, false),
            (["functions"], true, false, false),
            (["vision", "tools"], true, true, false), (["image"], false, true, false),
            (["image_input"], false, true, false), (["multimodal"], false, true, false),
            (["reasoning"], false, false, true), (["thinking"], false, false, true),
            (["reasoning_parser"], false, false, true),
            (["chat"], false, false, false),
        ]
        for (capabilities, tools, image, reasoning) in cases {
            let snapshot = catalog([catalogModel("m", display: "M", context: 65_536, capabilities: capabilities)])
            let model = IntegrationModels.resolve([EndpointModel(id: "m")], catalog: snapshot).first
            #expect(model?.tools == tools, "\(capabilities)")
            #expect(model?.imageInput == image, "\(capabilities)")
            #expect(model?.reasoning == reasoning, "\(capabilities)")
        }
        let unlisted = catalog([catalogModel("m", display: "M", capabilities: [])])
        #expect(IntegrationModels.resolve([EndpointModel(id: "m")], catalog: unlisted).first?.tools == true)
    }

    @Test("where a model runs orders the list and names it; a model listed twice keeps the nearest place")
    func locations() {
        let models = IntegrationModels.resolve([
            EndpointModel(id: "z-net", ownedBy: "darkbloom"),
            EndpointModel(id: "b-mine", ownedBy: "my-macs"),
            EndpointModel(id: "c-here", ownedBy: "this-mac"),
            EndpointModel(id: "a-here", ownedBy: "local"),
            EndpointModel(id: "c-here", ownedBy: "darkbloom"),
            EndpointModel(id: "y-unknown", ownedBy: "someone"),
        ], catalog: nil)
        #expect(models.map(\.name) == [
            "a-here (this Mac)", "c-here (this Mac)", "y-unknown (this Mac)", "b-mine (your Macs)",
            "z-net (Darkbloom network, billed)",
        ])
    }

    @Test("a pair's API: its own models are named (your pair); the others keep where they run")
    func aPairsOwnModels() {
        let models = IntegrationModels.resolve([
            EndpointModel(id: "z-net", ownedBy: "darkbloom"),
            EndpointModel(id: "b-mine", ownedBy: "my-macs"),
            EndpointModel(id: "q-pair", ownedBy: "this-mac"),
        ], catalog: nil, here: .yourPair)
        #expect(models.map(\.name) == ["q-pair (your pair)", "b-mine (your Macs)", "z-net (Darkbloom network, billed)"])
        #expect(models.first?.location == .yourPair)
        // Read back from a tool's file without where it runs, so a run without the catalog keeps the name.
        #expect(IntegrationModel.displayName(in: "Qwen 3.8 27B (your pair)") == "Qwen 3.8 27B")
        #expect(IntegrationModel.Location.allCases.map(\.label)
            == ["this Mac", "your pair", "your Macs", "Darkbloom network, billed"])
    }

    @Test("a pair's API serves its models here: the same limits and capabilities as this Mac's, online and offline")
    func aPairsModelsAreServedHere() throws {
        // Decoded as the endpoint lists them, so whatever the list says of a model served here (its engine's input
        // modalities too) counts for the pair's as for this Mac's.
        let listed = try JSONDecoder().decode([EndpointModel].self, from: Data("""
            [{"id": "q", "owned_by": "this-mac", "context_length": 262144, "max_output_length": 65536,
              "input_modalities": ["text"]},
             {"id": "u", "owned_by": "this-mac", "input_modalities": ["text", "image"]},
             {"id": "m", "owned_by": "my-macs", "input_modalities": ["text", "image"]}]
            """.utf8))
        func served(_ model: IntegrationModel) -> String {
            "\(model.id) \(String(describing: model.contextLength)) \(String(describing: model.outputLimit)) "
                + "\(model.tools) \(model.imageInput) \(model.reasoning) \(String(describing: model.fallback))"
        }
        let online = catalog([catalogModel("q", display: "Q", context: 131_072, capabilities: ["tools", "vision"])])
        for snapshot in [online, nil] as [CatalogSnapshot?] {
            let here = IntegrationModels.resolve(listed, catalog: snapshot)
            let pair = IntegrationModels.resolve(listed, catalog: snapshot, here: .yourPair)
            #expect(pair.map(served) == here.map(served))
            #expect(pair.map(\.location) == [.yourPair, .yourPair, .yourMacs])
        }
    }

    @Test("the endpoint's own process serves this Mac's models and its pair's, not your Macs' or the network's")
    func whereAModelIsServedHere() {
        #expect(IntegrationModel.Location.allCases.filter(\.servedHere) == [.thisMac, .yourPair])
    }

    @Test("non-chat catalog models are left out; an alias ID takes the alias's name and its build's limits")
    func catalogKindsAndAliases() {
        let snapshot = catalog([
            catalogModel("flux-2", display: "FLUX.2", type: "image"),
            catalogModel("glm-5.3-flash-nvfp4-b7", display: "GLM-5.3-Flash NVFP4 b7", context: 202_752, output: 65_536,
                         capabilities: ["tools", "reasoning"]),
        ], aliases: [alias("glm-5.3-flash", display: "GLM-5.3-Flash", build: "glm-5.3-flash-nvfp4-b7")])
        let models = IntegrationModels.resolve([
            EndpointModel(id: "flux-2", ownedBy: "local"),
            EndpointModel(id: "glm-5.3-flash", ownedBy: "my-macs"),
            EndpointModel(id: "glm-5.3-flash-nvfp4-b7", ownedBy: "local", contextLength: 131_072),
        ], catalog: snapshot)
        #expect(models == [
            IntegrationModel(id: "glm-5.3-flash-nvfp4-b7", name: "GLM-5.3-Flash (this Mac)", location: .thisMac,
                             contextLength: 131_072, outputLimit: 32_768, tools: true, imageInput: false,
                             reasoning: true),
            IntegrationModel(id: "glm-5.3-flash", name: "GLM-5.3-Flash (your Macs)", location: .yourMacs,
                             contextLength: 202_752, outputLimit: 50_688, tools: true, imageInput: false,
                             reasoning: true),
        ])
    }

    @Test("fetch sends the key file's key to <base URL>/models and reads both context spellings")
    func fetchModels() async throws {
        let directory = try TemporaryDirectory()
        let token = ToolIntegrationFixtures.freshToken()
        let keyFile = try directory.write(token + "\n", to: "key/local_token", mode: 0o600)
        let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1", keyFile: keyFile)
        let server = RecordingTransport(body: """
        {"object":"list","data":[
          {"id":"a","object":"model","owned_by":"local","context_length":65536,"max_model_len":65536},
          {"id":"b","object":"model","owned_by":"my-macs","max_model_len":32768,"max_output_length":8192},
          {"id":"c","object":"model"}
        ]}
        """)
        let listed = try await IntegrationModels.fetch(endpoint, transport: server.transport)
        #expect(listed == [
            EndpointModel(id: "a", ownedBy: "local", contextLength: 65_536),
            EndpointModel(id: "b", ownedBy: "my-macs", contextLength: 32_768, maxOutputLength: 8_192),
            EndpointModel(id: "c"),
        ])
        let request = try #require(server.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8123/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request.value(forHTTPHeaderField: "X-Darkbloom-Route") == nil)
    }

    @Test("fetch errors name the status or the key file, never the key")
    func fetchErrors() async throws {
        let directory = try TemporaryDirectory()
        let token = ToolIntegrationFixtures.freshToken()
        let keyFile = try directory.write(token, to: "local_token", mode: 0o600)
        let endpoint = IntegrationEndpoint(baseURL: "http://127.0.0.1:8123/v1/", keyFile: keyFile)
        let refused = RecordingTransport(status: 401, body: "{\"error\":\"bad key \(token)\"}")
        await #expect(throws: IntegrationModelsError.http(status: 401)) {
            try await IntegrationModels.fetch(endpoint, transport: refused.transport)
        }
        #expect(refused.requests.first?.url?.absoluteString == "http://127.0.0.1:8123/v1/models")

        let missing = IntegrationEndpoint(baseURL: endpoint.baseURL, keyFile: directory.file("absent"))
        let unused = RecordingTransport(body: "{}")
        await #expect(throws: IntegrationModelsError.keyUnreadable(path: directory.file("absent").path)) {
            try await IntegrationModels.fetch(missing, transport: unused.transport)
        }
        #expect(unused.requests.isEmpty)

        let garbage = RecordingTransport(body: "not json")
        await #expect(throws: IntegrationModelsError.undecodable) {
            try await IntegrationModels.fetch(endpoint, transport: garbage.transport)
        }
        let description = String(describing: IntegrationModelsError.http(status: 401))
        #expect(!description.contains(token))
    }
}
