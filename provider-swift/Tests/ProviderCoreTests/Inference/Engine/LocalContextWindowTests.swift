import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// A single Mac slot without an advertised context (Gemma 4, Qwen 3.5/3.6/3.8,
/// GPT-OSS, Nemotron Lightning) holds every request to its model's own window:
/// a prompt that fills it is refused in words that name the window, and an
/// output that would pass it is cut to what the prompt leaves. Before, such a
/// slot enforced nothing: a 263,643-token prompt to Gemma 4 26B (window
/// 262,144) and `max_tokens` 300,000 both ran.
@Suite("A single Mac holds every request to its model window")
struct LocalContextWindowTests {
    private static let window = 262_144

    private static func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(memorySnapshot: {
            .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
        })
    }

    /// The slot factory's bridge for a model without an advertised context.
    private static func bridge(_ engine: WindowSentinelEngine, window: Int = window,
                               tokenizer: any MLXLMCommon.Tokenizer = WindowTokenizer(count: 1)) -> EngineV2Bridge {
        EngineV2Bridge(engine: engine, modelId: "window/model", tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], defaultMaxTokens: 32_768, defaultMaxTokensContextLimit: window,
            maxConcurrentRequests: 1, kvBudget: budget())
    }

    @Test(arguments: [
        // (prompt, max_tokens asked, max_tokens the engine is asked for)
        (100, Optional(300_000), 262_044),
        (100, Optional(200_000), 200_000),
        (262_143, Optional(300_000), 1),
        (100, nil, 32_768),
        (250_000, nil, 12_144),
    ])
    func anOutputThatWouldPassTheWindowIsCutToWhatThePromptLeaves(
        prompt: Int, requested: Int?, output: Int
    ) async throws {
        let engine = WindowSentinelEngine()
        let bridge = Self.bridge(engine)
        let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
            request: .init(model: "window/model", messages: [], max_tokens: requested), requestId: "window",
            firstContentDeadline: nil)
        for await _ in stream {}
        #expect(engine.submittedOutputs == [output])
        await bridge.shutdown()
    }

    @Test(arguments: [262_144, 263_643])
    func aPromptThatFillsTheWindowIsRefusedInWordsThatNameIt(prompt: Int) async throws {
        let engine = WindowSentinelEngine()
        let bridge = Self.bridge(engine)
        do {
            let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
                request: .init(model: "window/model", messages: [], max_tokens: 64), requestId: "over-window",
                firstContentDeadline: nil)
            for await _ in stream {}
            Issue.record("a \(prompt)-token prompt ran in a \(Self.window)-token window")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(error.errorDescription?.contains("context window of \(Self.window) tokens") == true)
            #expect(ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation).statusCode == 400)
            #expect(InferenceRefusalReason(promptRefusal: error) == .requestExceedsContext)
            #expect(MultiModelBatchSchedulerEngineError.fromSchedulerMessage(error.errorDescription ?? "") == error)
        }
        #expect(engine.submittedOutputs.isEmpty)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        await bridge.shutdown()
    }

    @Test func thisMacsAPIAnswersAnOverWindowPromptWithA400NamingTheWindow() async throws {
        let engine = WindowSentinelEngine()
        let tokenizer = WindowTokenizer(count: 8)
        let bridge = Self.bridge(engine, window: 8, tokenizer: tokenizer)
        let handle = TokenizerHandle(tokenizer)
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            defaultMaxTokens: StandaloneServer.slotDefaultMaxTokens,
            acquire: { id in
                .init(tokenizer: handle, releaseToken: OneShotRelease(release: { _ in }, modelId: id),
                      modelType: nil, container: nil, isVLM: false, engineV2Bridge: bridge,
                      visionGate: VisionMemoryGate(kvBudget: nil, fp16KVBytesPerToken: 0, contextLength: 0))
            },
            tokenizerProvider: { _ in .init(tokenizer: handle, modelType: nil) },
            availableModels: { ["window/model"] }, mtpSlots: { [] })
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                body: ByteBuffer(string: #"{"model":"window/model","messages":[{"role":"user","content":"hi"}]}"#)
            ) { response in
                #expect(response.status == .badRequest)
                let text = String(buffer: response.body)
                #expect(text.contains("context window of 8 tokens"), "\(text)")
                #expect(text.contains("context_length_exceeded"), "\(text)")
            }
        }
        #expect(engine.submittedOutputs.isEmpty)
        await bridge.shutdown()
    }
}

/// No tensors or token generation: records the output each admitted request asks for.
private final class WindowSentinelEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [Int] = []
    var submittedOutputs: [Int] { lock.withLock { outputs } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { outputs.append(request.maxTokens) }
        return AsyncStream { $0.finish() }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

/// Renders every conversation to `count` tokens.
private struct WindowTokenizer: MLXLMCommon.Tokenizer {
    let count: Int
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Array(repeating: 1, count: count) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { Array(repeating: 1, count: count) }
}
