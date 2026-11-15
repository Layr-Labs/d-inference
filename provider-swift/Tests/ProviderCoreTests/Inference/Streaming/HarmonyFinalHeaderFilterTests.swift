import Foundation
import MLXLMServer
import Testing
@testable import ProviderCore

/// GPT-OSS answers under a `final` header with attributes reach the client as
/// content: the provider's filter, then the SDK's Harmony reasoning parser, as
/// `MLXOpenAIService` runs it on every coordinator stream.
struct HarmonyFinalHeaderFilterTests {
    static let analysis = "<|channel|>analysis<|message|>Need JSON.<|end|><|start|>assistant"
    static let answer = "{\"a\":1,\"b\":\"<x>\"}"

    static func chunks(_ text: String, width: Int) -> [String] {
        let characters = Array(text)
        return stride(from: 0, to: characters.count, by: width).map {
            String(characters[$0..<min(characters.count, $0 + width)])
        }
    }

    static func filtered(_ text: String, width: Int) -> String {
        var filter = HarmonyFinalHeaderFilter()
        return chunks(text, width: width).map { filter.ingest($0) }.joined() + filter.finish()
    }

    /// What a client receives: content and reasoning after the Harmony split.
    static func received(_ text: String, width: Int) -> (content: String, reasoning: String) {
        var parser = StreamingReasoningParser(format: .harmony)
        var parsed = [ParsedReasoning]()
        for chunk in chunks(filtered(text, width: width), width: width) { parsed += parser.parse(chunk) }
        parsed += parser.finish()
        return (parsed.map(\.content).joined(), parsed.compactMap(\.reasoningContent).joined())
    }

    static let widths = [1, 2, 3, 5, 11, 4096]

    @Test("an answer under `final <|constrain|>json` is content", arguments: widths)
    func constrainedAnswerIsContent(width: Int) {
        let output = Self.analysis + "<|channel|>final <|constrain|>json<|message|>" + Self.answer + "<|return|>"
        let result = Self.received(output, width: width)
        #expect(result.content == Self.answer)
        #expect(result.reasoning == "Need JSON.")
    }

    @Test("a bare content type or no space before the constraint is an answer too", arguments: widths)
    func otherAttributeSpellingsAreContent(width: Int) {
        for header in ["final json", "final<|constrain|>json", "final <|constrain|>JSON ", " final json"] {
            let output = Self.analysis + "<|channel|>\(header)<|message|>" + Self.answer
            #expect(Self.received(output, width: width).content == Self.answer, "\(header)")
        }
    }

    @Test("the non-stream Harmony parser gets the answer too")
    func nonStreamParserGetsTheAnswer() {
        let parser = ReasoningParser(format: .harmony)
        for header in ["final <|constrain|>json", "final json", " final "] {
            let output = Self.analysis + "<|channel|>\(header)<|message|>" + Self.answer
            #expect(parser.parse(Self.filtered(output, width: 4096)).content == Self.answer, "\(header)")
        }
    }

    @Test("every other header and all other text pass through byte for byte", arguments: widths)
    func otherOutputIsUnchanged(width: Int) {
        let outputs = [
            Self.analysis + "<|channel|>final<|message|>Plain answer.<|return|>",
            "<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{\"city\":\"Paris\"}<|call|>",
            "<|channel|>final to=functions.x<|message|>{}",
            "<|channel|>finalize<|message|>x",
            "<|channel|>final<|end|><|start|>assistant<|channel|>analysis<|message|>Reasoning.<|end|>",
            "No markers <|chan at all, a < and |>.",
            "Unicode é 🙂 <|channel|>analysis<|message|>Ünïcode<|end|>",
        ]
        for output in outputs {
            #expect(Self.filtered(output, width: width) == output)
        }
    }

    /// A recipientless commentary preamble is content by default (#2092,
    /// `GPTOSSCommentaryConformanceTests`); with its kill switch off it passes
    /// byte for byte, as in 0.10.12.
    @Test("a recipientless commentary passes byte for byte with its kill switch off", arguments: widths)
    func commentaryUnchangedWithSwitchOff(width: Int) {
        let output = "<|channel|>commentary<|message|>Checking the weather.<|end|>"
        var filter = HarmonyFinalHeaderFilter(environment: [HarmonyFinalHeaderFilter.commentaryEnvironmentKey: "0"])
        #expect(Self.chunks(output, width: width).map { filter.ingest($0) }.joined() + filter.finish() == output)
    }

    @Test("a padded plain final header becomes the exact one, for the non-stream parser too", arguments: widths)
    func paddedFinalHeaderIsExact(width: Int) {
        #expect(Self.filtered("<|channel|> final <|message|>Plain answer.", width: width)
            == "<|channel|>final<|message|>Plain answer.")
    }

    @Test("an unterminated or oversized header is passed on unchanged")
    func unfinishedHeadersPassThrough() {
        let unterminated = Self.analysis + "<|channel|>final <|constrain|>js"
        #expect(Self.filtered(unterminated, width: 3) == unterminated)
        let oversized = "<|channel|>final " + String(repeating: "a", count: 300) + "<|message|>{}"
        for width in Self.widths { #expect(Self.filtered(oversized, width: width) == oversized, "width \(width)") }
        // The limit is 256 header bytes at every chunking.
        let atLimit = "<|channel|>final " + String(repeating: "a", count: 250) + "<|message|>{}"
        let overLimit = "<|channel|>final " + String(repeating: "a", count: 251) + "<|message|>{}"
        for width in Self.widths {
            #expect(Self.filtered(atLimit, width: width) == "<|channel|>final<|message|>{}", "width \(width)")
            #expect(Self.filtered(overLimit, width: width) == overLimit, "width \(width)")
        }
        var partial = HarmonyFinalHeaderFilter()
        #expect(partial.ingest("text <|chan") == "text ")
        #expect(partial.finish() == "<|chan")
        // At most 256 header bytes and a partial `<|message|>` (266 bytes) are held.
        var held = HarmonyFinalHeaderFilter()
        let longHeader = String(repeating: "a", count: 266)
        #expect(held.ingest("<|channel|>" + longHeader) == "<|channel|>")
        #expect(held.ingest("a") == longHeader + "a")
    }

    @Test("only a Harmony-parsed GPT-OSS stream is filtered")
    func appliesOnlyToHarmonyParsedGPTOSS() throws {
        func request(_ parser: String?) throws -> OpenAIChatCompletionRequest {
            var body: [String: Any] = ["model": "gpt-oss-20b", "messages": [["role": "user", "content": "Hi"]],
                                       "response_format": ["type": "json_object"]]
            if let parser { body["reasoning_parser"] = parser }
            return try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
                from: JSONSerialization.data(withJSONObject: body))
        }
        #expect(HarmonyFinalHeaderFilter.applies(to: try request("harmony"), modelId: "gpt-oss-20b", modelType: "gpt_oss"))
        #expect(!HarmonyFinalHeaderFilter.applies(to: try request("none"), modelId: "gpt-oss-20b", modelType: "gpt_oss"))
        #expect(!HarmonyFinalHeaderFilter.applies(to: try request(nil), modelId: "gpt-oss-20b", modelType: "gpt_oss"))
        #expect(!HarmonyFinalHeaderFilter.applies(to: try request("qwen3"), modelId: "Qwen3.5-9B", modelType: "qwen3_5"))
    }

    #if DEBUG
    @Test("the engine stream delivers a constrained GPT-OSS answer as content", arguments: [1, 4])
    func engineStreamDeliversConstrainedAnswer(width: Int) async throws {
        let output = Self.analysis + "<|channel|>final <|constrain|>json<|message|>" + Self.answer
        let pieces = Self.chunks(output, width: width)
        let upstream = AsyncStream<GenerationEvent> { continuation in
            for piece in pieces { continuation.yield(.chunk(piece)) }
            continuation.yield(.info(promptTokens: 12, completionTokens: pieces.count, tokensPerSecond: 1,
                finishReason: "stop"))
            continuation.finish()
        }
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: JSONSerialization.data(
            withJSONObject: ["model": "gpt-oss-20b", "messages": [["role": "user", "content": "JSON please"]],
                             "response_format": ["type": "json_object"]]))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        let events = try scheduler._testMakeEventStream(upstream: upstream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"), rewriteHarmonyFinalHeaders: true)
        var parser = StreamingReasoningParser(format: .harmony)
        var content = ""
        var reasoning = ""
        for try await event in events {
            guard case .content(let text) = event else { continue }
            for parsed in parser.parse(text) {
                content += parsed.content
                reasoning += parsed.reasoningContent ?? ""
            }
        }
        for parsed in parser.finish() {
            content += parsed.content
            reasoning += parsed.reasoningContent ?? ""
        }
        #expect(content == Self.answer)
        #expect(reasoning == "Need JSON.")
    }
    #endif
}
