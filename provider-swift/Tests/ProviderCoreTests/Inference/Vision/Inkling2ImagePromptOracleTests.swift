import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Testing

@testable import ProviderCore
@testable import ProviderCoreFoundation

/// Inkling 2 Mini image requests through the provider's own media path
/// against reference Transformers renders (template fixtures 10 and
/// 11): an OpenAI request with inline images is ingested
/// (`MediaIngest.buildUserInput`, with the native template path the vision
/// prefill selects for this model), rendered by the provider's tokenizer
/// bridge (`LocalTokenizerLoader`, with the family's template filters) and
/// processed by the checkpoint's own processor. Input ids must be identical
/// and pixel values bit-identical.
///
/// Needs `INKLING2_ORACLE_TEMPLATE_DIR` (the fixtures) and `INKLING2_MODEL_DIR`
/// (a verified checkpoint directory; only its tokenizer and processor files
/// are read, no weights). Without both the test is skipped, never passed.
/// Arrays run on the CPU device: the processor's arithmetic is table lookups
/// and integer compositing, the same on either device, and the test then
/// needs no Metal library.
@Suite("Inkling 2 image prompt through the provider", .serialized)
struct Inkling2ImagePromptOracleTests {
    static let environment = ProcessInfo.processInfo.environment
    static let fixtures = environment["INKLING2_ORACLE_TEMPLATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let checkpoint = environment["INKLING2_MODEL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// The fixture's messages as an OpenAI request body: image parts become
    /// inline PNG data URIs, text parts stay text, in the fixture's order.
    static func requestBody(_ fixture: [String: Any], images: URL) throws -> Data {
        let messages = try #require(fixture["messages"] as? [[String: Any]])
        let wire: [[String: Any]] = try messages.map { message in
            guard let parts = message["content"] as? [[String: Any]] else { return message }
            var converted = message
            converted["content"] = try parts.map { part -> [String: Any] in
                guard part["type"] as? String == "image" else { return part }
                let file = try #require(part["image"] as? String)
                let png = try Data(contentsOf: images.appending(component: file))
                return ["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]]
            }
            return converted
        }
        var body: [String: Any] = ["model": Inkling2ModelIdentity.upstreamModelID, "messages": wire]
        for (key, value) in fixture["kwargs"] as? [String: Any] ?? [:] { body[key] = value }
        return try JSONSerialization.data(withJSONObject: body)
    }

    @Test(
        .enabled(if: Inkling2ImagePromptOracleTests.fixtures != nil && Inkling2ImagePromptOracleTests.checkpoint != nil,
                 "INKLING2_ORACLE_TEMPLATE_DIR and INKLING2_MODEL_DIR are required"),
        arguments: ["10_image_single", "11_image_two_padded_rgba"])
    func providerPathMatchesTheReference(_ name: String) async throws {
        try await Self.check(name) { fixture, _, images in try Self.requestBody(fixture, images: images) }
    }

    /// The reference fixture with an image inside a tool result
    /// (`*tool_result_image*.json`), once it lands in the fixture directory:
    /// the tool message's image runs through the tower in its place.
    /// Skipped, never passed, until then.
    static let toolResultImageFixture: String? = fixtures.flatMap { directory in
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".json") && $0.contains("tool_result_image") }
            .sorted().first.map { String($0.dropLast(".json".count)) }
    }

    @Test(.enabled(if: Inkling2ImagePromptOracleTests.toolResultImageFixture != nil
                    && Inkling2ImagePromptOracleTests.checkpoint != nil,
                   "the reference tool-result image fixture and INKLING2_MODEL_DIR are required"))
    func toolResultImageMatchesTheReference() async throws {
        let name = try #require(Self.toolResultImageFixture)
        try await Self.check(name) { fixture, data, images in
            let messages = try #require(fixture["messages"] as? [[String: Any]])
            #expect(messages.contains { message in
                message["role"] as? String == "tool"
                    && (message["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "image" }
            }, "\(name) has no image in a tool message")
            // History calls carry their arguments as the JSON string a client sends.
            return try Inkling2PromptContractTests.oracleBody(data, images: images).body
        }
    }

    /// One fixture through the provider's media path: the request decoded as
    /// served, its image roles checked, ingested with the native template
    /// path, rendered by the tokenizer bridge and processed by the
    /// checkpoint's processor. Input ids identical, pixel values bit-identical.
    static func check(
        _ name: String, body makeBody: ([String: Any], Data, URL) throws -> Data
    ) async throws {
        let fixtures = try #require(Self.fixtures)
        let checkpoint = try #require(Self.checkpoint)
        let data = try Data(contentsOf: fixtures.appending(component: name + ".json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try makeBody(fixture, data, fixtures.appending(component: "images"))
        let type = Inkling2ModelIdentity.modelType
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        let request = inbound.request
        try EngineV2VisionPrefill.validateInkling2ImageRoles(request)
        // As `EngineV2VisionPrefill.prepare` binds the loaded Inkling wrapper.
        let input = try await MediaIngest.buildUserInput(
            from: request, templateControls: inbound.extensions.templateControls,
            tools: request.tools?.map { $0.toolSpec() }, preserveTemplateFields: true,
            keepNonUserMedia: MediaIngest.placesNonUserMedia(request), modelType: type)
        let tokenizer = try await LocalTokenizerLoader().load(from: checkpoint)
        let configuration = try JSONDecoder().decode(
            Inkling2ProcessorConfiguration.self,
            from: Data(contentsOf: checkpoint.appending(component: "processor_config.json")))
        let pixelFile = try #require(fixture["pixel_values_file"] as? String)
        let expectedArrays = try loadArrays(url: fixtures.appending(component: pixelFile))
        let expectedPixels = try #require(expectedArrays["pixel_values"])
        try await Device.withDefaultDevice(.cpu) {
            let processor = Inkling2Processor(configuration, tokenizer: tokenizer)
            let prepared = try await processor.prepare(input: input)
            #expect(prepared.text.tokens.asArray(Int32.self).map(Int.init) == fixture["input_ids"] as? [Int], "\(name)")
            #expect(prepared.image?.frames?.map { [$0.t, $0.h, $0.w] } == fixture["image_grid_thw"] as? [[Int]],
                    "\(name)")
            let pixels = try #require(prepared.image?.pixels)
            #expect(pixels.shape == expectedPixels.shape, "\(name)")
            #expect(pixels.asType(.float32).asArray(Float.self).map(\.bitPattern)
                == expectedPixels.asType(.float32).asArray(Float.self).map(\.bitPattern), "\(name)")
        }
    }
}
