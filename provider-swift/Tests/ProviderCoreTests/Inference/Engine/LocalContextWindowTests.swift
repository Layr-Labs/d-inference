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

    /// The slot factory's bridge for a model without an advertised context.
    private static func bridge(_ engine: OutputRecordingEngine, window: Int = window,
                               tokenizer: any MLXLMCommon.Tokenizer = FixedLengthTokenizer()) -> EngineV2Bridge {
        EngineV2Bridge(engine: engine, modelId: "window/model", tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], defaultMaxTokens: 32_768, defaultMaxTokensContextLimit: window,
            maxConcurrentRequests: 1, kvBudget: roomyKVBudget())
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
        let engine = OutputRecordingEngine()
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
        let engine = OutputRecordingEngine()
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

    /// A token constraint is sized for the output the bridge resolves: a JSON
    /// answer's `max_tokens` past what the prompt leaves of the window is cut,
    /// and its constraint gets the same budget, which the engine requires.
    @Test func aConstrainedAnswerIsCutWithItsConstraint() async throws {
        let request = try QwenAnswerFixture.request(format: QwenAnswerFixture.jsonObject, maxTokens: 64)
        let prompt = QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: false)).count
        let engine = OutputRecordingEngine()
        let handle = TokenizerHandle(QwenByteTestTokenizer())
        let bridge = EngineV2Bridge(engine: engine, modelId: request.model, tokenizer: handle,
            eosTokenIds: QwenAnswerFixture.stops, defaultMaxTokens: 32_768,
            defaultMaxTokensContextLimit: prompt + 40, maxConcurrentRequests: 1, kvBudget: roomyKVBudget())
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [request.model: .init(tokenizer: handle, modelType: "qwen3_5", engineV2Bridge: bridge)]
        })
        // The engine writes nothing, so the answer then fails its JSON check;
        // only what the engine was asked for matters here.
        do { for try await _ in try await scheduler.streamChatCompletion(request: request) {} } catch {}
        #expect(engine.submittedOutputs == [40])
        #expect(engine.submittedConstraintBudgets == [40])
        await bridge.shutdown()
    }

    /// A pair refuses by its own limits, so the window is never held on it: a
    /// `max_tokens` reaches it as asked, and only an omitted one is cut, to
    /// the pair's context.
    @Test func aPairKeepsItsOwnLimits() async throws {
        let profile = try distributedTestProfile()
        let bridge = EngineV2Bridge(engine: try distributedTestEngine(DistributedTestOwner()), modelId: "pair/model",
            tokenizer: TokenizerHandle(FixedLengthTokenizer()), eosTokenIds: [],
            defaultMaxTokens: profile.maxOutputTokens, defaultMaxTokensContextLimit: profile.maxContextTokens,
            maxConcurrentRequests: 1)
        let prompt = profile.maxContextTokens - 20
        #expect(bridge.modelWindowTokens == nil)
        #expect(bridge.outputTokens(requested: 300_000, promptTokens: prompt) == 300_000)
        #expect(bridge.outputTokens(requested: nil, promptTokens: prompt) == 20)
        await bridge.shutdown()
    }

    @Test func theNonthrowingStreamKeepsTheWindowRefusalTyped() async {
        let engine = OutputRecordingEngine()
        let bridge = Self.bridge(engine)
        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: Self.window),
            request: .init(model: "window/model", messages: [], max_tokens: 64))
        var errors: [String] = []
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        #expect(errors.count == 1)
        #expect(MultiModelBatchSchedulerEngineError.fromSchedulerMessage(errors.first ?? "")
            == .promptExceedsContext(EngineV2Bridge.promptExceedsContextMessage(contextTokens: Self.window)))
        #expect(engine.submittedOutputs.isEmpty)
        await bridge.shutdown()
    }

    @Test func thisMacsAPIAnswersAnOverWindowPromptWithA400NamingTheWindow() async throws {
        let engine = OutputRecordingEngine()
        let tokenizer = FixedLengthTokenizer(count: 8)
        let bridge = Self.bridge(engine, window: 8, tokenizer: tokenizer)
        let (status, error) = try await Self.answer(bridge, tokenizer: tokenizer)
        #expect(status == 400)
        #expect(error["code"] as? String == "context_length_exceeded")
        #expect((error["message"] as? String)?.contains("context window of 8 tokens") == true, "\(error)")
        #expect(engine.submittedOutputs.isEmpty)
        await bridge.shutdown()
    }

    /// A model with an advertised context (GLM, MiMo, Super, Qwen4, Flint,
    /// Bonsai 9B) refuses a prompt and `max_tokens` that together pass it; this
    /// Mac's API says so in words, as it does for the model window.
    @Test func thisMacsAPIAnswersARequestPastAnAdvertisedContextInWords() async throws {
        let engine = OutputRecordingEngine()
        let tokenizer = FixedLengthTokenizer(count: 8)
        let bridge = EngineV2Bridge(engine: engine, modelId: "window/model", tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], defaultMaxTokens: 32_768, maxConcurrentRequests: 1, kvBudget: roomyKVBudget(),
            advertisedContextTokens: 8)
        let (status, error) = try await Self.answer(bridge, tokenizer: tokenizer)
        #expect(status == 400)
        #expect(error["code"] as? String == "context_length_exceeded")
        #expect(error["message"] as? String == "The prompt and max_tokens together don't fit in this model's "
            + "context window (its context_length in /v1/models). Shorten the prompt or lower max_tokens.")
        #expect(engine.submittedOutputs.isEmpty)
        await bridge.shutdown()
    }

    /// Within the window, this Mac's memory decides: a request reserves its
    /// prompt and output when it starts, and one the memory can't hold is
    /// refused as busy (503, which the local router may pass on) in words that
    /// name the memory and what to change.
    @Test func thisMacsAPISaysWhenItsMemoryCantHoldARequest() async throws {
        let engine = OutputRecordingEngine()
        let tokenizer = FixedLengthTokenizer(count: 8)
        let exhausted = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0, memorySnapshot: {
            .init(total: 8 << 30, active: 8 << 30, cache: 0, systemAvailable: 0)
        })
        let bridge = EngineV2Bridge(engine: engine, modelId: "window/model", tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], defaultMaxTokens: 32_768, defaultMaxTokensContextLimit: Self.window,
            maxConcurrentRequests: 1, kvBytesPerToken: 4_000, kvBudget: exhausted)
        let (status, error) = try await Self.answer(bridge, tokenizer: tokenizer)
        #expect(status == 503)
        #expect(error["message"] as? String == "This Mac's memory can't hold this request right now. Lower "
            + "max_tokens or shorten the prompt (or send less media), or retry when this Mac's other requests finish.")
        #expect(engine.submittedOutputs.isEmpty)
        await bridge.shutdown()
    }

    /// This Mac's API over one bridge: the status and the error object of a chat
    /// request, without `max_tokens`, whose prompt renders to the tokenizer's count.
    private static func answer(_ bridge: EngineV2Bridge, tokenizer: FixedLengthTokenizer) async throws
        -> (status: Int, error: [String: Any]) {
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
        let (status, body) = try await app.test(.router) { client in
            let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                body: ByteBuffer(string: #"{"model":"window/model","messages":[{"role":"user","content":"hi"}]}"#))
            return (response.status.code, String(buffer: response.body))
        }
        let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        return (status, json?["error"] as? [String: Any] ?? [:])
    }

    @Test func thisMacListsItsWindowAsTheContextAndTheOutput() {
        let limits = LocalModelLimits(window: Self.window)
        #expect(limits.contextLength == Self.window && limits.maxOutputLength == Self.window)
        #expect(LocalModelLimits(window: nil) == LocalModelLimits())
    }
}
