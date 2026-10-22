import CryptoKit
import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// GLM on a cluster pair serves `tool_choice` required/named and JSON
/// `response_format` by prompt forcing plus validation before anything is
/// exposed; the single-Mac GLM path keeps refusing them. Runs the real
/// service, scheduler, bridge and distributed engine; only the pair's
/// committed tokens are scripted. No model or GPU.
@Suite("GLM pair forced output", .serialized, .timeLimit(.minutes(1)))
struct GLMPairForcedOutputTests {
    static let weather = OpenAITool(function: .init(name: "get_weather", parameters: .object([
        "type": .string("object"), "properties": .object(["city": .object(["type": .string("string")])]),
        "required": .array([.string("city")]),
    ])))
    static let time = OpenAITool(function: .init(name: "get_time", parameters: .object([
        "type": .string("object"), "properties": .object(["city": .object(["type": .string("string")])]),
    ])))

    @Test func requiredToolChoiceIsServedAndValidatedOnThePair() async throws {
        let pair = try GLMPairFixture()
        let request = pair.request(tools: [Self.weather], choice: .mode(.required))
        let answer = try await pair.complete(request, tokens: [10, 11, 12, 13])
        let call = try #require(answer.choices.first?.message.toolCalls?.first)
        #expect(call.function.name == "get_weather")
        #expect(call.function.arguments.contains("Paris"))
        #expect(answer.choices.first?.finishReason == "tool_calls")
        #expect(answer.choices.first?.message.reasoningContent == "Need the weather.")
        #expect(answer.choices.first?.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines) == "")
        // The forcing instruction reached the prompt the pair was given.
        #expect(pair.renderedPrompts.last?.contains("You must emit") == true)
    }

    @Test func requiredToolChoiceFailsClosedWhenThePairAnswersInText() async throws {
        let pair = try GLMPairFixture()
        let request = pair.request(tools: [Self.weather], choice: .mode(.required))
        await #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try await pair.complete(request, tokens: [11, 14])
        }
    }

    @Test func namedToolChoiceRefusesAnotherFunction() async throws {
        let pair = try GLMPairFixture()
        let named = pair.request(tools: [Self.weather, Self.time], choice: .function(name: "get_time"))
        let served = try await pair.complete(named, tokens: [11, 16])
        #expect(served.choices.first?.message.toolCalls?.map(\.function.name) == ["get_time"])
        let other = try GLMPairFixture()
        await #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try await other.complete(other.request(tools: [Self.weather, Self.time],
                choice: .function(name: "get_time")), tokens: [11, 13])
        }
    }

    @Test func jsonResponseFormatIsServedAndValidatedOnThePair() async throws {
        let pair = try GLMPairFixture()
        var request = pair.request()
        request.responseFormat = .jsonObject()
        let answer = try await pair.complete(request, tokens: [11, 15])
        #expect(answer.choices.first?.message.textContent == #"{"city": "Paris"}"#)
        #expect(pair.renderedPrompts.last?.contains("single valid JSON object") == true)
        let text = try GLMPairFixture()
        var invalid = text.request()
        invalid.responseFormat = .jsonObject()
        await #expect(throws: (any Error).self) { _ = try await text.complete(invalid, tokens: [11, 14]) }
    }

    @Test func minPReachesThePairReservation() async throws {
        let pair = try GLMPairFixture()
        var request = pair.request()
        request.temperature = 0.7
        request.minP = 0.05
        request.seed = 7
        _ = try await pair.complete(request, tokens: [11, 14])
        let reserved = try #require(pair.owner.lastRequest)
        #expect(reserved.sampling.minP == 0.05)
        #expect(DistributedSampling.wire(for: reserved, vocabularySize: 200)?.minP == 0.05)
    }

    @Test func reasoningExclusionWithholdsTheReasoningOnThePair() async throws {
        var controls = ChatTemplateControls()
        controls.rawGLM5Controls.excludesReasoning = true
        #expect(throws: (any Error).self) { try controls.rawGLM5Controls.validate() }
        let pair = try GLMPairFixture(controls: controls)
        let answer = try await pair.complete(pair.request(), tokens: [10, 11, 14])
        #expect(answer.choices.first?.message.reasoningContent == nil)
        #expect(answer.choices.first?.message.textContent == "It is sunny.")
        // The withheld reasoning was generated and is still counted.
        #expect(answer.usage.completionTokens == 3)
    }

    /// The pair renders GLM with the single-Mac load's thinking-off
    /// tokenizer: thinking off closes the open think block; other models and
    /// other requests render unchanged.
    @Test func thePairTokenizerClosesThinkingAsTheSingleMacLoadDoes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let off: [String: any Sendable] = [GLM5NextPromptPolicy.thinkingOffContextKey: false]
        let glm = try TokenizerHandle.pairServing(ThinkTokenizer(), modelType: "glm5_next", modelDirectory: directory)
        #expect(try glm.inner.applyChatTemplate(messages: [], tools: nil, additionalContext: off) == [1, 7, 8])
        #expect(try glm.inner.applyChatTemplate(messages: [], tools: nil, additionalContext: [:]) == [1, 7])
        let other = try TokenizerHandle.pairServing(ThinkTokenizer(), modelType: "qwen3_5", modelDirectory: directory)
        #expect(try other.inner.applyChatTemplate(messages: [], tools: nil, additionalContext: off) == [1, 7])
    }

    @Test func theSingleMacGLMPathStillRefusesForcedOutput() throws {
        let request = OpenAIChatCompletionRequest(model: "m", messages: [.init(role: .user, content: .text("x"))],
            tools: [Self.weather], toolChoice: .mode(.required))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        #expect(!prepared.glm5PairPostValidation)
        #expect(throws: (any Error).self) {
            try GLM5NextPromptPolicy.normalizedTextInput(request: request, prepared: prepared, controls: .init())
        }
        #expect(throws: (any Error).self) {
            try ToolStreamPreparation.makeHandler(request: request, prepared: prepared, modelType: "glm5_next")
        }
        var pairPrepared = prepared
        pairPrepared.glm5PairPostValidation = true
        #expect(try ToolStreamPreparation.makeHandler(request: request, prepared: pairPrepared,
            modelType: "glm5_next")?.format == .glm5)
        #expect(throws: (any Error).self) {
            // Another family never takes the GLM pair strategy.
            try ToolChoiceEnforcementPolicy.forcedStrategy(mode: .required,
                modelContext: .init(modelId: "m", modelType: "llama"), glm5PairPostValidation: true)
        }
    }
}

/// Output pieces of the scripted pair, on a GLM-shaped prompt.
private enum GLMPairPieces {
    static let table: [Int: String] = [
        1: "[gMASK]<sop><|user|>fixture", 2: "<|assistant|><think>",
        10: "Need the weather.", 11: "</think>", 12: "\n",
        13: "<tool_call>get_weather<arg_key>city</arg_key><arg_value>Paris</arg_value></tool_call>",
        14: "It is sunny.", 15: #"{"city": "Paris"}"#,
        16: "<tool_call>get_time<arg_key>city</arg_key><arg_value>Paris</arg_value></tool_call>",
    ]
}

private final class GLMPairTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []
    var rendered: [String] { lock.withLock { prompts } }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { GLMPairPieces.table[$0] ?? "" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { token == "<|user|>" ? 3 : nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        let text = messages.map { "\($0["role"] ?? ""): \($0["content"] ?? "")" }.joined(separator: "\n")
        lock.withLock { prompts.append(text) }
        return [1, 2]
    }
}

/// A generation prompt that ends with an open think block (`<think>` = 7).
private struct ThinkTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { ["<think>": 7, "</think>": 8][token] }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 7] }
}

private final class GLMPairDetokenizers: CBv2DetokenizerFactory {
    final class Decoder: CBv2IncrementalDetokenizer {
        let holdback: StopHoldback
        private(set) var matchedStopString = false
        init(_ stops: [String]) { holdback = StopHoldback(stopStrings: stops) }
        func push(_ tokens: [Int]) -> String {
            let result = holdback.ingest(tokens.map { GLMPairPieces.table[$0] ?? "" }.joined())
            matchedStopString = result.stopped
            return result.text
        }
        func flush() -> String { matchedStopString ? "" : holdback.flush() }
    }
    func makeDetokenizer(stopStrings: [String]) -> any CBv2IncrementalDetokenizer { Decoder(stopStrings) }
}

private final class GLMPairOwner: DistributedResidentExecutionOwner, @unchecked Sendable {
    static let profileID = "fixture-glm-pair"
    let identity = DistributedResidentIdentity(membershipEpoch: UUID(), modelID: "registered_glm53_flash",
        artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "c", count: 64),
        peers: [.init(id: "fixture-0", buildSHA256: String(repeating: "b", count: 64)),
                .init(id: "fixture-1", buildSHA256: String(repeating: "b", count: 64))])
    private let lock = NSLock()
    private var lease: DistributedTestLease?
    private var request: CBv2Request?
    var lastLease: DistributedTestLease? { lock.withLock { lease } }
    var lastRequest: CBv2Request? { lock.withLock { request } }
    func readiness() -> DistributedResidentReadiness? {
        .init(identity: identity, profileID: Self.profileID, requestCapacityBytes: 1 << 20)
    }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        .unbounded(reason: nil)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        guard identity == self.identity, profileID == Self.profileID else { throw DistributedEngineError.unavailable }
        let value = DistributedTestLease(identity: identity, requestID: request.id)
        lock.withLock { self.request = request; lease = value }
        return value
    }
    func shutdown() async {}
}

private struct GLMPairFixture {
    static let model = "fixture/glm-pair"
    let owner = GLMPairOwner()
    let tokenizer = GLMPairTokenizer()
    let service: MLXOpenAIService
    let bridge: EngineV2Bridge
    var renderedPrompts: [String] { tokenizer.rendered }

    init(controls: ChatTemplateControls = .init()) throws {
        let profile = try DistributedResidentExecutionProfile(id: GLMPairOwner.profileID, vocabularySize: 200,
            maxPromptTokens: 2048, maxOutputTokens: 128, maxContextTokens: 4096, requestTimeout: .seconds(30))
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity, profile: profile,
            detokenizers: GLMPairDetokenizers())
        let handle = TokenizerHandle(tokenizer)
        bridge = EngineV2Bridge(engine: engine, modelId: Self.model, tokenizer: handle, eosTokenIds: [],
            defaultMaxTokens: 128, defaultMaxTokensContextLimit: 4096)
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(tokenizer: handle, modelType: "glm5_next",
            engineV2Bridge: bridge)
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [Self.model: entry] },
            templateControls: controls)
        service = MLXOpenAIService(engine: scheduler, responseStore: InMemoryResponseStore(), metrics: ServerMetrics())
    }

    func request(tools: [OpenAITool]? = nil, choice: OpenAIToolChoice? = nil) -> OpenAIChatCompletionRequest {
        var request = OpenAIChatCompletionRequest(model: Self.model,
            messages: [.init(role: .user, content: .text("What is the weather in Paris?"))],
            tools: tools, toolChoice: choice, stream: false, temperature: 0, maxTokens: 32)
        request.reasoningParser = .qwen3
        return request
    }

    /// Serves `request` while the scripted pair commits `tokens` and stops.
    func complete(_ request: OpenAIChatCompletionRequest, tokens: [Int],
                  telemetry: DistributedRankTelemetry? = nil) async throws -> OpenAIChatCompletionResponse {
        let owner = self.owner
        let driver = Task {
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while owner.lastLease?.startCount != 1, ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let lease = owner.lastLease else { return }
            for token in tokens where !lease.send(.token(token)) { break }
            if let telemetry { _ = lease.send(.telemetry(telemetry)) }
            _ = lease.send(.finished(.stop))
            lease.acknowledge()
        }
        defer { driver.cancel() }
        return try await service.createChatCompletion(request: request)
    }
}

extension GLMPairForcedOutputTests {
    /// `reasoning.exclude` in the body: MiMo's evidence marks it invalid,
    /// which sends the request through the scheduler's early native-control
    /// check (c35 answered 400 there). The pair still serves it, withheld.
    @Test func reasoningExcludeInTheBodyIsServedOnThePair() async throws {
        let controls = try JSONDecoder().decode(ChatTemplateControls.self,
            from: Data(#"{"reasoning":{"exclude":true}}"#.utf8))
        #expect(controls.rawMiMoControls.invalid)
        #expect(controls.rawGLM5Controls.excludesReasoning)
        let pair = try GLMPairFixture(controls: controls)
        let answer = try await pair.complete(pair.request(), tokens: [10, 11, 14])
        #expect(answer.choices.first?.message.reasoningContent == nil)
        #expect(answer.choices.first?.message.textContent == "It is sunny.")
        #expect(answer.usage.completionTokens == 3)
    }

    /// The cluster API's `/metrics`: the MTP counts rank 0 reported request by
    /// request, the requests running and waiting, the reservation ledger and
    /// a never-persisted prefix key, under the single-Mac family names.
    @Test func thePairsMetricsCarryItsMTPCountsAndLedger() async throws {
        let pair = try GLMPairFixture()
        let before = try #require(await pair.bridge.pairMetricsSample(model: GLMPairFixture.model, waitingRequests: 0))
        let idle = MTPPrometheusRenderer.render([before])
        #expect(idle.contains(#"mtp_enabled{model="fixture/glm-pair"} 0"#))
        #expect(idle.contains(#"mtp_rounds_total{model="fixture/glm-pair"} 0"#))
        #expect(idle.contains(#"kv_active_requests{model="fixture/glm-pair"} 0"#))
        _ = try await pair.complete(pair.request(), tokens: [10, 11, 14], telemetry: .init(handoffMilliseconds: nil,
            handoffBytes: nil, mtpDrafted: 6, mtpAccepted: 4, mtpRounds: 3))
        let sample = try #require(await pair.bridge.pairMetricsSample(model: GLMPairFixture.model, waitingRequests: 2))
        let text = MTPPrometheusRenderer.render([sample])
        let model = #"model="fixture/glm-pair""#
        for line in ["mtp_enabled{\(model)} 1", "mtp_active{\(model)} 1", "mtp_rounds_total{\(model)} 3",
                     "mtp_tokens_proposed_total{\(model)} 6", "mtp_tokens_accepted_total{\(model)} 4",
                     "kv_waiting_requests{\(model)} 2", "complete_prefix_key_persistent{\(model)} 0",
                     "paged_kv_page_size{\(model),ledger=\"cluster_pair\"} 0",
                     "paged_kv_reserved_bytes{\(model),ledger=\"cluster_pair\"} ",
                     "paged_kv_grant_bytes{\(model),ledger=\"cluster_pair\"} "] {
            #expect(text.contains(line), "missing \(line)")
        }
        for family in ["kv_active_requests", "paged_kv_live_bytes", "paged_kv_committed_bytes", "prefix_cache_status",
                       "kv_backend_info"] {
            #expect(text.contains("# TYPE \(family) gauge"), "missing \(family)")
        }
        // A single-Mac slot has no pair sample.
        #expect(MTPPrometheusRenderer.render([]).isEmpty)
    }
}
