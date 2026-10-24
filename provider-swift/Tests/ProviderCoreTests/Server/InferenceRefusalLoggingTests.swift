#if DEBUG
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Refusals before the inference task through the production coordinator
/// handler. Each writes one fixed public `darkbloom logs` line naming its
/// reason and keeps its `inference_error` frame; none logs request text.
@Suite("Refusals before the inference task log a fixed reason", .serialized)
struct InferenceRefusalLoggingTests {
    static let modelID = "test/glm5-refusals"
    static let requestID = "refusal-request-id"
    /// Request text that must never reach a log line.
    static let secret = "zq-private-7f3a"
    static let user = #""messages":[{"role":"user","content":"zq-private-7f3a"}]"#
    static let result = #"{"role":"tool","tool_call_id":"c1","content":"zq-private-7f3a"}"#
    static let invalidRequest = InferenceFailure(code: .invalidRequest, statusCode: 400)

    /// Controls GLM refuses, and chat bodies the decoder refuses.
    static let refusals: [(fields: [String], reason: InferenceRefusalReason)] = [
        ([user, #""chat_template_kwargs":{"zq-private-7f3a":1}"#], .unsupportedReasoningControl),
        ([user, #""reasoning_effort":"default""#], .unsupportedReasoningControl),
        ([user, #""reasoning":{"mode":"pro"}"#], .unsupportedReasoningControl),
        ([user, #""thinking":{"type":"enabled","budget_tokens":0}"#], .unsupportedReasoningControl),
        ([user, #""reasoning":{"enabled":false,"effort":"high"}"#], .contradictoryReasoningControls),
        ([user, #""reasoning":{"context":"current_turn"},"clear_thinking":false"#], .contradictoryReasoningControls),
        ([user, #""tools":[{"type":"web_search","name_hint":"zq-private-7f3a"}]"#], .unsupportedToolType),
        ([user, #""tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"zq-private-7f3a":{"type":"integer","enum":[18446744073709551615]}}}}}]"#],
         .invalidToolSchema),
        ([user, #""tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":{"type":"string","x-darkbloom-original-boolean-schema":true}}}}}]"#],
         .reservedToolSchemaMetadata),
        ([#""messages":[{"role":"user","content":"zq-private-7f3a"},{"role":"assistant","content":null,"tool_calls":[{"id":"c1","function":{"name":"f","arguments":"{}"}}]},"# + result + "]"],
         .invalidToolHistory),
        ([#""messages":[{"role":"user","content":"zq-private-7f3a"},{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"f","arguments":{"zq-private-7f3a":1}}}]},"# + result + "]"],
         .invalidToolArguments),
        ([#""messages":[{"role":"critic","content":"zq-private-7f3a"}]"#], .unsupportedMessageRole),
        ([#""messages":[{"role":"user","content":[{"type":"image_url","image_url":{"detail":"zq-private-7f3a"}}]}]"#],
         .invalidMessages),
        ([user, #""tools":[{"type":"function","function":{"description":"zq-private-7f3a"}}]"#], .invalidToolDeclaration),
        ([user, #""tool_choice":{"type":"function","zq-private-7f3a":true}"#], .invalidToolChoice),
        ([user, #""response_format":{"type":"json_schema","json_schema":{"name":"zq-private-7f3a"}}"#],
         .unsupportedResponseFormat),
        ([user, #""reasoning":{"enabled":"zq-private-7f3a"}"#], .unsupportedReasoningControl),
        ([user, #""temperature":"zq-private-7f3a""#], .invalidRequestField),
        ([user, #""stop":"#], .malformedBody),
    ]

    @Test func everyRefusalLogsItsFixedReasonAndKeepsItsFrame() async throws {
        for (fields, reason) in Self.refusals {
            let logs = RefusalLogRecorder()
            let output = try await relay(fields, logs: logs)
            #expect(output.frames.isEmpty, "\(reason)")
            #expect(errors(output) == [Self.invalidRequest], "\(reason)")
            expectOneRefusalLine(logs, reason: reason, failure: Self.invalidRequest)
        }
    }

    @Test func unsupportedAudioLogsItsReasonAndKeepsItsMediaFrame() async throws {
        let logs = RefusalLogRecorder()
        let audio = #""messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"zq-private-7f3a","format":"wav"}}]}]"#
        let output = try await relay([audio], logs: logs)
        let media = InferenceFailure(code: .invalidMedia, statusCode: 400, errorReason: .clientError)
        #expect(errors(output) == [media])
        expectOneRefusalLine(logs, reason: .unsupportedAudio, failure: media)
    }

    @Test func sealedRequestRefusalsLogTheirReason() async throws {
        let cases: [(key: Data?, reason: InferenceRefusalReason)] = [
            (nil, .missingSenderKey), (Data(repeating: 7, count: 32), .undecryptableRequest),
        ]
        for (key, reason) in cases {
            let logs = RefusalLogRecorder()
            let messages = RefusalMessageRecorder()
            let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
                hardware: Self.hardware, models: [], config: .init(provider: .init(name: "refusals"),
                    backend: .init(), coordinator: .init(heartbeatIntervalSecs: 60))),
                attestationSigner: nil, logSinkForTesting: { logs.append($0, $1, $2) })
            await loop.handleInferenceRequest(requestId: Self.requestID, ciphertext: Data(Self.secret.utf8),
                senderPublicKey: key, cacheReceiptNonce: nil, authenticatedCacheScope: nil,
                send: SendHandle(messages.record))
            let failures = messages.snapshot.compactMap { message -> InferenceFailure? in
                if case .inferenceError(_, let failure, _) = message { return failure }
                return nil
            }
            #expect(failures == [Self.invalidRequest], "\(reason)")
            expectOneRefusalLine(logs, reason: reason, failure: Self.invalidRequest)
        }
    }

    /// A served request logs no refusal.
    @Test func servedRequestLogsNoRefusal() async throws {
        let logs = RefusalLogRecorder()
        let output = try await relay([Self.user], logs: logs) { continuation, _ in
            for chunk in ["Weigh.", "</think>", "Answer."] {
                continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil))
            }
            continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 1, completionTokens: 3)))
            continuation.finish()
        }
        #expect(errors(output).isEmpty && !output.frames.isEmpty)
        #expect(!logs.entries.contains { $0.message.hasPrefix("Inference failure") || $0.message.contains("refusal=") })
    }

    /// The published text of every reason, spelled out.
    static let publicLine: [InferenceRefusalReason: String] = [
        .missingSenderKey: "Inference failure: invalid request (missing sender key)",
        .undecryptableRequest: "Inference failure: invalid request (undecryptable request)",
        .reservedToolSchemaMetadata: "Inference failure: invalid request (reserved tool schema metadata)",
        .malformedBody: "Inference failure: invalid request (malformed body)",
        .invalidMessages: "Inference failure: invalid request (invalid messages)",
        .unsupportedMessageRole: "Inference failure: invalid request (unsupported message role)",
        .invalidToolHistory: "Inference failure: invalid request (invalid tool history)",
        .invalidToolArguments: "Inference failure: invalid request (invalid tool arguments)",
        .invalidToolDeclaration: "Inference failure: invalid request (invalid tool declaration)",
        .invalidToolChoice: "Inference failure: invalid request (invalid tool choice)",
        .unsupportedResponseFormat: "Inference failure: invalid request (unsupported response format)",
        .invalidRequestField: "Inference failure: invalid request (invalid request field)",
        .unsupportedReasoningControl: "Inference failure: invalid request (unsupported reasoning control)",
        .contradictoryReasoningControls: "Inference failure: invalid request (contradictory reasoning controls)",
        .unsupportedToolType: "Inference failure: invalid request (unsupported tool type)",
        .invalidToolSchema: "Inference failure: invalid request (invalid tool schema)",
        .unsupportedAudio: "Inference failure: invalid media (unsupported audio)",
    ]

    @Test func everyReasonHasItsOwnPublicLine() {
        #expect(Set(Self.publicLine.keys) == Set(InferenceRefusalReason.allCases))
        #expect(Set(Self.publicLine.values).count == InferenceRefusalReason.allCases.count)
        let published = Set(ProviderOperationalMessage.allCases.map(\.rawValue))
        #expect(Set(Self.publicLine.values).isSubset(of: published))
    }

    // MARK: - Helpers

    static let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max",
        chipFamily: .m4, chipTier: .max, memoryGb: 64, memoryAvailableGb: 64,
        cpuCores: .init(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)

    func relay(
        _ fields: [String], logs: RefusalLogRecorder,
        script: (AsyncStream<CBv2Event>.Continuation, ScriptedCoordinatorRelay.Progress) async throws -> Void
            = { _, _ in Issue.record("a refused request reached the engine") }
    ) async throws -> ScriptedCoordinatorRelay.Output {
        try await ScriptedCoordinatorRelay.run(modelID: Self.modelID, modelType: "glm5_next",
            tokenizer: TokenizerHandle(try GLM5NextThinkingTokenizer(base: GLMVisibilityTokenizer())),
            containerTokenizer: GLMVisibilityTokenizer(), eosTokenIds: [154_820, 154_827, 154_829],
            requestID: Self.requestID,
            fields: [#""model":"\#(Self.modelID)""#, #""max_tokens":64"#, #""stream":true"#] + fields,
            logSink: { logs.append($0, $1, $2) }, script: script)
    }

    func errors(_ output: ScriptedCoordinatorRelay.Output) -> [InferenceFailure] {
        output.terminals.compactMap { message in
            if case .inferenceError(_, let failure, _) = message { return failure }
            return nil
        }
    }

    /// Exactly one public line, the reason's, and its private twin with the
    /// request ID and wire classification; no line carries request text.
    func expectOneRefusalLine(_ logs: RefusalLogRecorder, reason: InferenceRefusalReason, failure: InferenceFailure) {
        let entries = logs.entries
        let published = entries.filter { $0.visibility == .public && $0.message.hasPrefix("Inference failure") }
        #expect(published.map(\.message) == [Self.publicLine[reason]], "\(reason)")
        #expect(published.allSatisfy { $0.level == .error && !$0.message.contains(Self.requestID) }, "\(reason)")
        let classification = failure.errorReason.map { " reason=\($0.rawValue)" } ?? ""
        let details = entries.filter { $0.visibility == .private && $0.message.contains("refusal=") }
        #expect(details.map(\.message) == [
            "[\(Self.requestID)] inference failure code=\(failure.code.rawValue) status=\(failure.statusCode)"
                + classification + " refusal=\(reason.rawValue)",
        ], "\(reason)")
        #expect(!entries.contains { $0.message.contains(Self.secret) }, "\(reason)")
    }
}

final class RefusalLogRecorder: @unchecked Sendable {
    struct Entry {
        let level: ProviderLogLevel
        let visibility: ProviderLogVisibility
        let message: String
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []

    func append(_ level: ProviderLogLevel, _ visibility: ProviderLogVisibility, _ message: String) {
        lock.withLock { recorded.append(Entry(level: level, visibility: visibility, message: message)) }
    }

    var entries: [Entry] { lock.withLock { recorded } }
}

final class RefusalMessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var snapshot: [OutboundMessage] { lock.withLock { messages } }
}
#endif
