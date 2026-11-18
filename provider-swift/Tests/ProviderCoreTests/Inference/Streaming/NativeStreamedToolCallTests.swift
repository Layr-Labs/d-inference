import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// MiMo V2.6 and Nemotron 3.5 Lightning, the served native-channel families
/// on the scheduler's text path: their tool calls must reach a client that
/// streams while they are generated, as Gemma's and Qwen's do, under the
/// same rules (`StreamedToolCallTests`).
@Suite("Streamed native tool calls")
struct NativeStreamedToolCallTests {
    /// One served family: its serving identity, its native channel set-up as
    /// the scheduler's text path makes it, and its call frame.
    struct Family: CustomTestStringConvertible, Sendable {
        let model: String
        let modelType: String
        /// `nativeReasoningPrefix` as the text path seeds it.
        let nativePrefix: String
        let nativeMiMoChannels: Bool
        let absorbStrayThinkClose: Bool
        /// `<tool_call>` frame of one call; values are written as the
        /// family's template writes them.
        let frame: @Sendable (_ name: String, _ parameters: [(String, String)]) -> String

        var testDescription: String { modelType }

        static let mimo = Family(model: "mimo-v2.6-flash-mopd", modelType: "mimo_v2", nativePrefix: "",
            nativeMiMoChannels: true, absorbStrayThinkClose: false) { name, parameters in
                "<tool_call><function=\(name)>"
                    + parameters.map { "<parameter=\($0.0)>\($0.1)</parameter>" }.joined()
                    + "</function></tool_call>"
            }
        static let lightning = Family(model: "nvidia-nemotron-3.5-lightning", modelType: "nemotron_h",
            nativePrefix: "<think></think>", nativeMiMoChannels: false, absorbStrayThinkClose: true) { name, parameters in
                "<tool_call>\n<function=\(name)>\n"
                    + parameters.map { "<parameter=\($0.0)>\n\($0.1)\n</parameter>\n" }.joined()
                    + "</function>\n</tool_call>"
            }
        static let all = [mimo, lightning]
    }

    private static let tools = """
        [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
          "properties":{"location":{"type":"string"},"days":{"type":"integer"}},"required":["location"]}}},
         {"type":"function","function":{"name":"write_file","parameters":{"type":"object",
          "properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}]
        """

    static func request(_ family: Family, _ choice: OpenAIToolChoice? = nil, parallel: Bool? = nil,
                        clientStreams: Bool = true) throws -> OpenAIChatCompletionRequest {
        var request = OpenAIChatCompletionRequest(
            model: family.model,
            messages: [.init(role: .user, content: .text("Write the file."))],
            tools: try JSONDecoder().decode([OpenAITool].self, from: Data(tools.utf8)),
            toolChoice: choice, parallelToolCalls: parallel, stream: clientStreams,
            streamOptions: clientStreams ? .init(includeUsage: true) : nil)
        request.streamToolCallDeltas = false // set by the service itself
        return request
    }

    private static func characters(_ text: String) -> [String] { text.map(String.init) }

    private static func streamedCall(_ chunks: [ProviderLoop.StreamChunkExtract]) -> (name: String?, arguments: String) {
        let deltas = chunks.flatMap { $0.toolCallsDelta ?? [] }
        return (deltas.compactMap { $0.function?.name }.first,
                deltas.compactMap { $0.function?.arguments }.joined())
    }

    private static func decoded(_ arguments: String) throws -> [String: MLXLMCommon.JSONValue] {
        try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(arguments.utf8))
    }

    /// A long tool answer from either family held back every byte until
    /// generation ended, so the coordinator's first-content deadline cut it
    /// off. Its name must reach the wire while the arguments are still being
    /// generated, and the call a client rebuilds from the fragments is the
    /// one the complete-call path returned.
    @Test(arguments: Family.all, [OpenAIToolChoice.mode(.auto), .mode(.required), .function(name: "write_file")])
    func longNativeToolAnswersReachTheWireBeforeTheirFrameCloses(family: Family, choice: OpenAIToolChoice)
        async throws
    {
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        let service = MLXOpenAIService(engine: NativeRoutedEngine(upstream: upstream.stream, family: family))
        let log = NativeFrameLog()
        let frames = try await service.streamChatCompletionFrames(request: try Self.request(family, choice))
        let reader = Task {
            for try await frame in frames { await log.append(frame) }
        }
        let content = String(repeating: "print('long answer')\n", count: 40)
        let text = family.frame("write_file", [("path", "long.py"), ("content", content)])
        let head = Self.characters(String(text.prefix(text.count - content.count - 40)))
        for chunk in head { upstream.continuation.yield(.chunk(chunk)) }
        // Most of the answer has not been generated yet.
        #expect(await log.waitForToolFrame(), "the call's first content must leave before its frame closes")
        for chunk in Self.characters(text).dropFirst(head.count) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 40, completionTokens: 300, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        try await reader.value

        let parsed = await log.frames.compactMap(ProviderLoop.parseStreamChunk)
        let call = Self.streamedCall(parsed)
        #expect(call.name == "write_file")
        #expect(try Self.decoded(call.arguments) == ["path": .string("long.py"), "content": .string(content)])
        #expect(parsed.contains { $0.finishReason == "tool_calls" })
        #expect(!parsed.contains { $0.contentDelta?.isEmpty == false }, "the answer is the call alone")
    }
}

/// The scheduler's event stream with a family's native channel set-up, as
/// `MultiModelBatchSchedulerEngine`'s text path makes it.
struct NativeRoutedEngine: MLXServerEngine {
    let upstream: AsyncStream<GenerationEvent>
    let family: NativeStreamedToolCallTests.Family
    var streamToolCalls = true

    func availableModels() async throws -> [MLXServerModel] { [] }

    func streamChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: family.modelType)
        let handler = try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: family.modelType, streamToolCalls: streamToolCalls)
        return try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
            toolHandler: handler, nativeReasoningPrefix: family.nativePrefix,
            absorbStrayThinkClose: family.absorbStrayThinkClose, nativeMiMoChannels: family.nativeMiMoChannels)
    }

    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: []) }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "") }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: []) }
}

actor NativeFrameLog {
    private(set) var frames: [String] = []

    func append(_ frame: String) { frames.append(frame) }

    /// Polls for a frame carrying `tool_calls`; false after about two seconds.
    func waitForToolFrame() async -> Bool {
        for _ in 0..<400 {
            if frames.contains(where: { $0.contains("\"tool_calls\"") }) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}
