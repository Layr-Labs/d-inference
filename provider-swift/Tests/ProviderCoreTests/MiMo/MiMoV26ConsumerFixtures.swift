import CryptoKit
import Foundation
import MLXLMCommon
import MLXLMServer
import MLXVLM
import XCTest
@testable import ProviderCore

/// Actual pinned tokenizer and production consumer layers. Only the generation
/// boundary is scripted; no fixture below proves model-generated tool quality.
enum MiMoConsumerFixture {
    static let toolJSON = #"{"type":"function","function":{"name":"echo","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}}}"#
    static func body(_ controls: String = "", choice: String? = nil, stream: Bool = false) -> Data {
        let tools = choice.map { #","tools":["# + toolJSON + #"],"tool_choice":"# + $0 } ?? ""
        return Data((#"{"model":"fixture","messages":[{"role":"user","content":"hello"}],"stream":"#
            + (stream ? "true" : "false") + tools + (controls.isEmpty ? "" : "," + controls) + "}").utf8)
    }
    static func request(_ controls: String = "", choice: String? = nil) throws -> OpenAIChatCompletionRequest {
        try ProviderLoop.decodeOpenAIRequest(body(controls, choice: choice))
    }
    static func httpBody(_ controls: String, choice: String? = nil,
                         responses: Bool, streaming: Bool) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:
            body(controls, choice: choice, stream: streaming)) as? [String: Any])
        if responses { object.removeValue(forKey: "messages"); object["input"] = "hello" }
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func frame(_ value: String, name: String = "echo") -> String {
        "<tool_call><function=" + name + "><parameter=text>" + value + "</parameter></function></tool_call>"
    }
    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    struct Corpus: Decodable {
        struct Row: Decodable { let id: String; let request_json: String; let token_ids: [Int] }
        let cases: [Row]
        let metadata_sha256: [String: String]
        let original31_sha256: String
    }
    static func load() async throws -> (TokenizerHandle, Corpus) {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try XCTUnwrap(env["MIMO_PROMPT_ARTIFACT_DIRECTORY"]))
        let vectors = URL(fileURLWithPath: try XCTUnwrap(env["MIMO_PROMPT_REFERENCE_VECTORS"]))
        let bytes = try Data(contentsOf: vectors)
        XCTAssertEqual(sha(bytes), "66e6a49a23509fbc99e5389fa4687f2b6175f96d05d7a8be0f323bf4986049bb")
        let corpus = try JSONDecoder().decode(Corpus.self, from: bytes)
        XCTAssertEqual(corpus.cases.count, 20)
        XCTAssertEqual(corpus.original31_sha256, "c11b2d3a9400bbe935c33f86b1ec6dc0ed91ea6e8b85030d355a4b66d35c2e8e")
        for (name, expected) in corpus.metadata_sha256 {
            XCTAssertEqual(sha(try Data(contentsOf: directory.appendingPathComponent(name))), expected, name)
        }
        return (TokenizerHandle(try await LocalTokenizerLoader().load(from: directory)), corpus)
    }
    static func frames(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var result = ""
        for try await frame in stream { result += frame }
        return result
    }
    static func literalSources() throws -> [String] {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["MIMO_PROMPT_ARTIFACT_DIRECTORY"])
        let root = URL(fileURLWithPath: path)
        let standalone = try String(contentsOf: root.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("tokenizer_config.json"))) as? [String: Any])
        return [standalone, try XCTUnwrap(config["chat_template"] as? String)]
    }
    static func nativeProcessor(tokenizer: TokenizerHandle, source: String) throws -> MiMoV26TextProcessor {
        struct Bounds: Decodable { let vocab_size: Int; let max_position_embeddings: Int }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["MIMO_PROMPT_ARTIFACT_DIRECTORY"])
        let bounds = try JSONDecoder().decode(Bounds.self,
            from: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("config.json")))
        return try .init(tokenizer: tokenizer.inner, chatTemplate: source,
            vocabularySize: bounds.vocab_size, maximumSequenceLength: bounds.max_position_embeddings)
    }
    static func sseObjects(_ frames: String) throws -> [[String: Any]] {
        try frames.components(separatedBy: "\n").filter { $0.hasPrefix("data: {") }.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any])
        }
    }
    static func chatText(_ frames: String) throws -> (content: String, reasoning: String) {
        var content = "", reasoning = ""
        for object in try sseObjects(frames) {
            for choice in object["choices"] as? [[String: Any]] ?? [] {
                let delta = choice["delta"] as? [String: Any] ?? [:]
                content += delta["content"] as? String ?? ""
                reasoning += delta["reasoning_content"] as? String ?? ""
            }
        }
        return (content, reasoning)
    }
    static func responseText(_ frames: String) throws -> (content: String, reasoning: String) {
        var content = "", reasoning = ""
        for object in try sseObjects(frames) {
            if object["type"] as? String == "response.output_text.delta" { content += object["delta"] as? String ?? "" }
            if object["type"] as? String == "response.reasoning_summary_text.delta" { reasoning += object["delta"] as? String ?? "" }
        }
        return (content, reasoning)
    }
}

final class MiMoConsumerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class MiMoConsumerResponseID: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ value: String) { lock.withLock { stored = value } }
    var value: String? { lock.withLock { stored } }
}

final class MiMoConsumerEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var submitted: [[Int]] = []
    private var pending: [CBv2RequestID: AsyncStream<CBv2Event>.Continuation] = [:]
    private var cancelled = 0
    let chunks: [String]
    let holdOpen: Bool
    init(output: String = "Ready", width: Int = 1, holdOpen: Bool = false) {
        let scalars = Array(output.unicodeScalars)
        self.chunks = stride(from: 0, to: scalars.count, by: width).map {
            String(String.UnicodeScalarView(scalars[$0..<min($0 + width, scalars.count)]))
        }
        self.holdOpen = holdOpen
    }
    var prompts: [[Int]] { lock.withLock { submitted } }
    var cancelCount: Int { lock.withLock { cancelled } }
    var outstanding: Int { lock.withLock { pending.count } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { submitted.append(request.promptTokens) }
        return AsyncStream { continuation in
            if holdOpen { lock.withLock { pending[request.id] = continuation }; return }
            for chunk in chunks { continuation.yield(.delta(text: chunk, tokens: [9], logprobs: nil)) }
            continuation.yield(.finished(reason: .stop,
                usage: .init(promptTokens: request.promptTokens.count, completionTokens: chunks.count)))
            continuation.finish()
        }
    }
    func cancel(_ id: CBv2RequestID) {
        let stream = lock.withLock {
            let stream = pending.removeValue(forKey: id)
            if stream != nil { cancelled += 1 }
            return stream
        }
        stream?.yield(.finished(reason: .cancelled, usage: .init(promptTokens: 0, completionTokens: 0)))
        stream?.finish()
    }
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: outstanding, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {
        let ids = lock.withLock { Array(pending.keys) }
        for id in ids { cancel(id) }
    }
}

/// Real scheduler/bridge/service with scripted CBv2 deltas and exact native
/// tokenizer. No replacement renderer or parser can manufacture a test pass.
struct MiMoConsumerServing: Sendable {
    let tokenizer: TokenizerHandle
    let backend: MiMoConsumerEngine
    let bridge: EngineV2Bridge
    let acquireCount = MiMoConsumerCounter()
    let lookupCount = MiMoConsumerCounter()
    let releases = MiMoConsumerCounter()
    let modelType: String
    init(tokenizer: TokenizerHandle, output: String = "Ready", width: Int = 1,
         holdOpen: Bool = false, modelType: String = "mimo_v2") {
        self.tokenizer = tokenizer; self.modelType = modelType
        backend = MiMoConsumerEngine(output: output, width: width, holdOpen: holdOpen)
        bridge = EngineV2Bridge(engine: backend, modelId: "fixture", tokenizer: tokenizer, eosTokenIds: [])
    }
    func engine(_ controls: ChatTemplateControls = .init()) -> MultiModelBatchSchedulerEngine {
        MultiModelBatchSchedulerEngine(
            acquire: { _ in
                acquireCount.increment()
                return .init(tokenizer: tokenizer,
                    releaseToken: OneShotRelease(release: { _ in releases.increment() }, modelId: "fixture"),
                    modelType: modelType, engineV2Bridge: bridge)
            },
            tokenizerProvider: { _ in
                lookupCount.increment()
                return .init(tokenizer: tokenizer, modelType: modelType)
            },
            availableModels: { ["fixture"] }, templateControls: controls)
    }
    func service(_ controls: ChatTemplateControls = .init(),
                 store: InMemoryResponseStore = .init()) -> MLXOpenAIService {
        .init(engine: engine(controls), responseStore: store)
    }
}
