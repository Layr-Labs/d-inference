import DarkbloomClusterProtocol
import Foundation
import Hummingbird
import Logging
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import MLXVLM
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

/// One Mac and a cluster pair answer GLM-5.3-Flash requests alike. Each body is
/// decoded as the local API decodes it and served, collected and streamed, by
/// the actual OpenAI service and scheduler over the same scripted output twice:
/// on a single-Mac slot (a local engine; images through the product's request
/// normalization and processor) and on a tensor-parallel pair slot that serves
/// media (the distributed engine and the leader's media ingress; the peers'
/// tokens are scripted). Both give the same answer, or the same error, which the
/// local API renders with the same status and message. No model weights.
@Suite("GLM single-Mac and pair parity", .serialized, .timeLimit(.minutes(1)))
struct GLMSlotParityTests {
    static let model = "fixture/glm-parity"

    /// What the local API's client sees.
    enum Seen: Equatable, Sendable, CustomStringConvertible {
        /// Calls are `name arguments`, the arguments' keys sorted.
        case answer(content: String, reasoning: String, calls: [String], finish: String)
        /// Refused before any answer: the local API's status and message, and
        /// the coordinator path's failure (`status code reason`) for the error.
        case refusal(status: Int, message: String, coordinator: String)
        /// A streamed answer whose generation failed after what it streamed.
        case failedStream(reasoning: String, content: String, error: String)

        var description: String {
            switch self {
            case .answer(let content, let reasoning, let calls, let finish):
                "answer content=\(content.debugDescription) reasoning=\(reasoning.debugDescription) calls=\(calls) finish=\(finish)"
            case .refusal(let status, let message, let coordinator):
                "refusal \(status) \(message.debugDescription) coordinator=\(coordinator)"
            case .failedStream(let reasoning, let content, let error):
                "failed stream reasoning=\(reasoning.debugDescription) content=\(content.debugDescription) error=\(error)"
            }
        }

        var isAnswer: Bool { if case .answer = self { true } else { false } }

        /// A refusal is expected by what the local API shows; its coordinator
        /// failure is compared between the slots.
        func matches(_ expected: Seen) -> Bool {
            if case .refusal(let status, let message, _) = self,
               case .refusal(let expectedStatus, let expectedMessage, _) = expected {
                return status == expectedStatus && message == expectedMessage
            }
            return self == expected
        }
    }

    enum Image: Sendable { case onePixel, sixteenPixels }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        /// `IMAGE` stands for the image's data URI.
        let body: String
        var image: Image?
        var tokens: [Int] = []
        var finish: CBv2FinishReason = .stop
        let collected: Seen
        /// When a stream shows the outcome differently.
        var streamed: Seen?
        var testDescription: String { name }
    }

    static func body(_ content: String, _ extra: String = "", maxTokens: Int = 32) -> String {
        #"{"model":"\#(model)","max_tokens":\#(maxTokens),"messages":[{"role":"user","content":\#(content)}]\#(extra)}"#
    }

    static let text = #""What is the weather in Paris?""#
    static let picture =
        #"[{"type":"text","text":"What is the weather in this picture?"},{"type":"image_url","image_url":{"url":"IMAGE"}}]"#
    static let excluded = #","reasoning":{"exclude":true}"#
    static let schema = #","response_format":{"type":"json_schema","json_schema":{"name":"city","strict":true,"#
        + #""schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}}}"#
    static let required = #","tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","#
        + #""properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"required""#
    static let sunny = [10, GLMSlotPieces.endThink, 14]
    static func unservedPart(_ type: String) -> Seen {
        .refusal(status: 400, message: "Content part type \"\(type)\" is not supported. "
            + "Send text, image_url, video_url or input_audio parts.", coordinator: "")
    }
    static let mediaOutputRefusal = Seen.refusal(status: 400, message: InferenceFailureCode.invalidRequest.message,
        coordinator: "")

    static let cases: [Case] = [
        Case(name: "text, reasoning.exclude", body: body(text, excluded), tokens: sunny,
             collected: .answer(content: "It is sunny.", reasoning: "", calls: [], finish: "stop")),
        Case(name: "text, json_schema", body: body(text, schema), tokens: [10, GLMSlotPieces.endThink, 15],
             collected: .answer(content: #"{"city": "Paris"}"#, reasoning: "Need the weather.", calls: [], finish: "stop")),
        Case(name: "text, tool_choice required", body: body(text, required), tokens: [10, GLMSlotPieces.endThink, 13],
             collected: .answer(content: "", reasoning: "Need the weather.", calls: [#"get_weather {"city":"Paris"}"#],
                                finish: "tool_calls")),
        Case(name: "image, reasoning.exclude", body: body(picture, excluded), image: .onePixel, tokens: sunny,
             collected: .answer(content: "It is sunny.", reasoning: "", calls: [], finish: "stop")),
        Case(name: "image, json_schema", body: body(picture, schema), image: .onePixel, tokens: sunny,
             collected: mediaOutputRefusal),
        Case(name: "image, tool_choice required", body: body(picture, required), image: .onePixel, tokens: sunny,
             collected: mediaOutputRefusal),
        Case(name: "16x16 image", body: body(picture), image: .sixteenPixels, tokens: sunny,
             collected: .answer(content: "It is sunny.", reasoning: "Need the weather.", calls: [], finish: "stop")),
        Case(name: "json_schema answer cut off by max_tokens", body: body(text, schema, maxTokens: 3),
             tokens: [10, GLMSlotPieces.endThink, 16], finish: .length,
             collected: .refusal(status: 422, message: InferenceFailureCode.internalFailure.message, coordinator: ""),
             streamed: .failedStream(reasoning: "Need the weather.", content: "",
                                     error: "server_error Response generation failed")),
        Case(name: "input_file part",
             body: body(#"[{"type":"text","text":"Summarize it."},{"type":"input_file","file_id":"file-fixture"}]"#),
             collected: unservedPart("input_file")),
        Case(name: "input_video part",
             body: body(#"[{"type":"text","text":"Describe it."},{"type":"input_video","video_url":"data:video/mp4;base64,AAAA"}]"#),
             collected: unservedPart("input_video")),
    ]

    @Test(arguments: GLMSlotParityTests.cases)
    func oneMacAndThePairAnswerAlike(_ testCase: Case) async throws {
        for streamed in [false, true] {
            let mode = "\(testCase.name), \(streamed ? "streamed" : "collected")"
            let oneMac = try await serve(testCase, pair: false, streamed: streamed)
            let pair = try await serve(testCase, pair: true, streamed: streamed)
            print("GLM parity | \(mode) | one Mac: \(oneMac.seen) | pair: \(pair.seen)")
            #expect(oneMac.seen == pair.seen, "\(mode)")
            let expected = streamed ? testCase.streamed ?? testCase.collected : testCase.collected
            #expect(oneMac.seen.matches(expected), "\(mode): \(oneMac.seen)")
            // Media reaches preparation only when it is served: a refused
            // output control never decodes it, on either slot.
            let prepares = testCase.image != nil && expected.isAnswer
            #expect(oneMac.preparedMedia == prepares && pair.preparedMedia == prepares, "\(mode)")
        }
    }

    private func serve(_ testCase: Case, pair: Bool, streamed: Bool) async throws -> (seen: Seen, preparedMedia: Bool) {
        var body = testCase.body
        if let image = testCase.image {
            let png = switch image {
            case .onePixel: GLMClusterTensorParallelMediaTests.png
            case .sixteenPixels: try #require(QwenIngressFixtures.redPNG(width: 16, height: 16))
            }
            body = body.replacingOccurrences(of: "IMAGE", with: "data:image/png;base64," + png)
        }
        var item = try JSONDecoder().decode(LocalChatRequest.self, from: Data(body.utf8))
        if item.request.reasoningParser == nil {
            item.request.reasoningParser = ProviderLoop.inferReasoningParser(for: "glm5_next")
        }
        item.request.stream = streamed
        let configuration = try GLMClusterTensorParallelMediaTests.configuration()
        let ingress = try DistributedGLMMediaIngress(configuration: configuration,
            processorConfiguration: GLMClusterTensorParallelMediaTests.processorConfiguration(),
            expectedSHA256: ClusterGLMMedia.sha256(configuration))
        let tokenizer = TokenizerHandle(try GLM5NextThinkingTokenizer(base: GLMSlotTokenizer()))
        let service: MLXOpenAIService
        let seen: Seen
        if pair {
            let owner = GLMSlotPairOwner(configuration: configuration)
            let profile = try DistributedResidentExecutionProfile(id: ClusterGLMImageCandidate.textProfileID,
                vocabularySize: 160000, maxPromptTokens: 2048, maxOutputTokens: 128, maxContextTokens: 4096,
                requestTimeout: .seconds(30))
            let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity, profile: profile,
                detokenizers: GLMSlotDetokenizers())
            let bridge = EngineV2Bridge(engine: engine, modelId: Self.model, tokenizer: tokenizer, eosTokenIds: [],
                defaultMaxTokens: 128, defaultMaxTokensContextLimit: 4096, clusterGLMMediaIngress: ingress)
            let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(tokenizer: tokenizer, modelType: "glm5_next",
                engineV2Bridge: bridge)
            service = MLXOpenAIService(engine: MultiModelBatchSchedulerEngine(registryProvider: { [Self.model: entry] },
                defaultMaxTokens: 128, templateControls: item.templateControls))
            let (tokens, finish) = (testCase.tokens, testCase.finish)
            let driver = Task {
                let end = ContinuousClock.now.advanced(by: .seconds(5))
                while owner.lastLease?.startCount != 1, ContinuousClock.now < end {
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard let lease = owner.lastLease else { return }
                for token in tokens where !lease.send(.token(token)) { break }
                _ = lease.send(.finished(finish))
                lease.acknowledge()
            }
            if streamed { seen = await stream(service, item.request) } else { seen = await collect(service, item.request) }
            driver.cancel()
            await engine.shutdown()
            return (seen, owner.lastRequest?.clusterGLMMedia != nil)
        }
        let prepared = GLMSlotMediaCount()
        let bridge = EngineV2Bridge(engine: GLMSlotLocalEngine(tokens: testCase.tokens, finish: testCase.finish),
            modelId: Self.model, tokenizer: tokenizer, eosTokenIds: [], defaultMaxTokens: 128,
            defaultMaxTokensContextLimit: 4096)
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(tokenizer: tokenizer, modelType: "glm5_next",
            container: glmSlotContainer(), isVLM: true, engineV2Bridge: bridge)
        service = MLXOpenAIService(engine: MultiModelBatchSchedulerEngine(registryProvider: { [Self.model: entry] },
            defaultMaxTokens: 128, templateControls: item.templateControls,
            engineV2Vision: singleMacMedia(ingress.processor, tokenizer: tokenizer, prepared: prepared)))
        if streamed { seen = await stream(service, item.request) } else { seen = await collect(service, item.request) }
        return (seen, prepared.count > 0)
    }

    /// The single-Mac product's media preparation up to its vision tower
    /// (`EngineV2VisionPrefill.prepareGLM5NextMedia`): the same request
    /// normalization, media decode and processor at the pair's budgets.
    private func singleMacMedia(_ configuration: GLM5NextProcessorConfiguration, tokenizer: TokenizerHandle,
                                prepared: GLMSlotMediaCount) -> EngineV2VisionPlumbing {
        EngineV2VisionPlumbing(prepare: { _, request, controls in
            prepared.increment()
            let input = try await EngineV2VisionPrefill.glm5NextUserInput(request: request, controls: controls)
            let processor = try GLM5NextProcessor(configuration: configuration, tokenizer: tokenizer.inner)
            return try await Device.withDefaultDevice(.cpu) {
                let output: GLM5NextPreparedInput
                do { output = try await processor.prepareDetailed(input: input) }
                catch let error as GLM5NextVisionError { throw EngineV2VisionPrefill.glm5NextInputError(error) }
                let tokens = output.input.text.tokens.asType(.int64).asArray(Int64.self).map(Int.init)
                return EngineV2VisionPrefill.PreparedSubmission(promptTokens: tokens,
                    spans: output.placements.map { .init(tokenOffset: $0.tokenRange.lowerBound, length: $0.tokenRange.count) },
                    embeddings: output.placements.map { MLXArray.zeros([1, $0.tokenRange.count, 4]) },
                    spanKinds: output.placements.map { $0.modality == .image ? .image : .video },
                    attention: .causal, positionState: nil, mediaKind: .image)
            }
        }, emitTelemetry: { _ in })
    }

    private func collect(_ service: MLXOpenAIService, _ request: OpenAIChatCompletionRequest) async -> Seen {
        do {
            let response = try await service.createChatCompletion(request: request)
            let choice = response.choices.first
            return .answer(content: choice?.message.textContent ?? "", reasoning: choice?.message.reasoningContent ?? "",
                calls: (choice?.message.toolCalls ?? []).map { Self.call($0.function.name, $0.function.arguments) },
                finish: choice?.finishReason ?? "")
        } catch {
            return await refusal(error)
        }
    }

    /// The frames as an OpenAI client reassembles them.
    private func stream(_ service: MLXOpenAIService, _ request: OpenAIChatCompletionRequest) async -> Seen {
        let frames: AsyncThrowingStream<String, Error>
        do {
            frames = try await service.streamChatCompletionFrames(request: request, frameGenerationErrors: true)
        } catch {
            return await refusal(error)
        }
        var content = "", reasoning = "", finish = "", failure: String?
        var calls: [(name: String, arguments: String)] = []
        do {
            for try await frame in frames {
                guard frame.hasPrefix("data: {"),
                      let chunk = try JSONSerialization.jsonObject(with: Data(frame.dropFirst(6).utf8)) as? [String: Any]
                else { continue }
                if let error = chunk["error"] as? [String: Any] {
                    failure = "\(error["code"] as? String ?? "") \(error["message"] as? String ?? "")"
                }
                guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                reasoning += delta["reasoning_content"] as? String ?? ""
                content += delta["content"] as? String ?? ""
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    if let name = function["name"] as? String {
                        calls.append((name, function["arguments"] as? String ?? ""))
                    } else if let fragment = function["arguments"] as? String, !calls.isEmpty {
                        calls[calls.count - 1].arguments += fragment
                    }
                }
                if let reason = choice["finish_reason"] as? String { finish = reason }
            }
        } catch {
            failure = "thrown \(type(of: error))"
        }
        if let failure { return .failedStream(reasoning: reasoning, content: content, error: failure) }
        return .answer(content: content, reasoning: reasoning, calls: calls.map { Self.call($0.name, $0.arguments) },
                       finish: finish)
    }

    /// The local API's rendering (`CORSResponder`) and the coordinator path's
    /// failure for an error the service threw.
    private func refusal(_ error: any Error) async -> Seen {
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation)
        let coordinator = "\(failure.statusCode) \(failure.code.rawValue) \(failure.errorReason?.rawValue ?? "-")"
        let context = BasicRequestContext(source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(), logger: Logger(label: "glm-parity")))
        let request = Request(head: .init(method: .post, scheme: "http", authority: "localhost", path: "/v1/chat/completions"),
                              body: .init(buffer: ByteBuffer()))
        do {
            let response = try await CORSResponder(inner: GLMSlotThrowingResponder(error: error))
                .respond(to: request, context: context)
            let body = GLMSlotCollectedBody()
            try await response.body.write(body)
            let envelope = try JSONSerialization.jsonObject(with: Data(String(buffer: body.bytes).utf8)) as? [String: Any]
            return .refusal(status: response.status.code,
                message: (envelope?["error"] as? [String: Any])?["message"] as? String ?? "", coordinator: coordinator)
        } catch {
            return .refusal(status: -1, message: "unrendered \(type(of: error))", coordinator: coordinator)
        }
    }

    static func call(_ name: String, _ arguments: String) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)),
              let sorted = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "\(name) \(arguments)" }
        return "\(name) \(String(decoding: sorted, as: UTF8.self))"
    }
}

/// Generated text by token id; the prompt ends inside GLM's open think block.
private enum GLMSlotPieces {
    static let think = 151000, endThink = 151001
    static let table: [Int: String] = [
        1: "[gMASK]<sop><|user|>fixture", 2: "<|assistant|>", think: "<think>", endThink: "</think>",
        10: "Need the weather.", 13: "<tool_call>get_weather<arg_key>city</arg_key><arg_value>Paris</arg_value></tool_call>",
        14: "It is sunny.", 15: #"{"city": "Paris"}"#, 16: #"{"city": "Pa"#,
    ]
}

/// GLM's media and think markers; renders each image or video part as the
/// shipped template does.
private struct GLMSlotTokenizer: MLXLMCommon.Tokenizer {
    static let specials = [
        "<|image|>": 154854, "<|video|>": 154855, "<|begin_of_image|>": 154830, "<|end_of_image|>": 154831,
        "<|begin_of_video|>": 154832, "<|end_of_video|>": 154833,
        "<think>": GLMSlotPieces.think, "</think>": GLMSlotPieces.endThink,
    ]
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { GLMSlotPieces.table[$0] ?? "" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { Self.specials[token] }
    func convertIdToToken(_ id: Int) -> String? { Self.specials.first { $0.value == id }?.key }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        var tokens = [1]
        for message in messages {
            guard let parts = message["content"] as? [[String: String]] else { continue }
            for part in parts where part["type"] == "image" { tokens += [154830, 154854, 154831] }
            for part in parts where part["type"] == "video" { tokens += [154832, 154855, 154833] }
        }
        return tokens + [2, GLMSlotPieces.think]
    }
}

/// The single-Mac model: the scripted tokens as one delta each, then `finish`.
private final class GLMSlotLocalEngine: CBv2Engine, @unchecked Sendable {
    let tokens: [Int]
    let finish: CBv2FinishReason
    init(tokens: [Int], finish: CBv2FinishReason) {
        self.tokens = tokens
        self.finish = finish
    }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        for token in tokens {
            continuation.yield(.delta(text: GLMSlotPieces.table[token] ?? "", tokens: [token], logprobs: nil))
        }
        continuation.yield(.finished(reason: finish,
            usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: tokens.count)))
        continuation.finish()
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0,
            activeTokens: 0)
    }
    func shutdown() async {}
}

private final class GLMSlotDetokenizers: CBv2DetokenizerFactory {
    final class Decoder: CBv2IncrementalDetokenizer {
        let holdback: StopHoldback
        private(set) var matchedStopString = false
        init(_ stops: [String]) { holdback = StopHoldback(stopStrings: stops) }
        func push(_ tokens: [Int]) -> String {
            let result = holdback.ingest(tokens.map { GLMSlotPieces.table[$0] ?? "" }.joined())
            matchedStopString = result.stopped
            return result.text
        }
        func flush() -> String { matchedStopString ? "" : holdback.flush() }
    }
    func makeDetokenizer(stopStrings: [String]) -> any CBv2IncrementalDetokenizer { Decoder(stopStrings) }
}

/// The registered GLM pair in tensor parallel with the media contract.
private final class GLMSlotPairOwner: DistributedResidentExecutionOwner, @unchecked Sendable {
    let identity: DistributedResidentIdentity
    private let lock = NSLock()
    private var lease: DistributedTestLease?
    private var request: CBv2Request?
    var lastLease: DistributedTestLease? { lock.withLock { lease } }
    var lastRequest: CBv2Request? { lock.withLock { request } }
    init(configuration: Data) {
        identity = .init(membershipEpoch: UUID(), modelID: ClusterGLMImageCandidate.runtimeModelID,
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: ClusterGLMMedia.sha256(configuration),
            peers: [.init(id: "fixture-0", buildSHA256: String(repeating: "b", count: 64)),
                    .init(id: "fixture-1", buildSHA256: String(repeating: "b", count: 64))])
    }
    func readiness() -> DistributedResidentReadiness? {
        .init(identity: identity, profileID: ClusterGLMImageCandidate.textProfileID, requestCapacityBytes: 1 << 20,
            media: ClusterGLMMedia.contract)
    }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        .unbounded(reason: nil)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        guard identity == self.identity, profileID == ClusterGLMImageCandidate.textProfileID else {
            throw DistributedEngineError.unavailable
        }
        let value = DistributedTestLease(identity: identity, requestID: request.id)
        lock.withLock { self.request = request; lease = value }
        return value
    }
    func shutdown() async {}
}

private final class GLMSlotMediaCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class GLMSlotStubModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws
        -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct GLMSlotStubProcessor: UserInputProcessor {
    struct Unused: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unused() }
}

private func glmSlotContainer() -> ModelContainer {
    ModelContainer(context: ModelContext(configuration: ModelConfiguration(id: GLMSlotParityTests.model),
        model: GLMSlotStubModel(), processor: GLMSlotStubProcessor(), tokenizer: GLMSlotTokenizer()))
}

private struct GLMSlotThrowingResponder: HTTPResponder {
    typealias Context = BasicRequestContext
    let error: any Error
    func respond(to request: Request, context: Context) async throws -> Response { throw error }
}

private final class GLMSlotCollectedBody: ResponseBodyWriter, @unchecked Sendable {
    var bytes = ByteBuffer()
    func write(_ buffer: ByteBuffer) async throws {
        var buffer = buffer
        bytes.writeBuffer(&buffer)
    }
    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}
