#if DEBUG
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Client refusals through the production coordinator handler, before the
/// inference task or while its prompt is prepared. Each writes one fixed public
/// `darkbloom logs` line naming its reason and sends the same reason on its
/// `inference_error` frame; none logs or sends request text.
@Suite("Client refusals log and send a fixed reason", .serialized)
struct InferenceRefusalLoggingTests {
    static let modelID = "test/glm5-refusals"
    static let requestID = "refusal-request-id"
    /// Request text that must never reach a log line or a frame.
    static let secret = "zq-private-7f3a"
    static let user = #""messages":[{"role":"user","content":"zq-private-7f3a"}]"#
    static let result = #"{"role":"tool","tool_call_id":"c1","content":"zq-private-7f3a"}"#

    /// The `invalid_request` failure a refusal before the inference task sends.
    static func invalidRequest(_ refusal: InferenceRefusalReason) -> InferenceFailure {
        InferenceFailure(code: .invalidRequest, statusCode: 400, refusal: refusal)
    }

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
        ([user, deeplyNestedTools], .malformedBody),
    ]

    /// A tool parameter nested 200 arrays deep: past `JSONNestingLimit`, and
    /// deep enough to exhaust a task's stack in the parsers it guards.
    static let deeplyNestedTools: String = {
        var schema = #"{"type":"string"}"#
        for _ in 0 ..< 200 { schema = #"{"type":"array","items":"# + schema + "}" }
        return #""tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":"#
            + schema + "}}}}]"
    }()

    @Test func everyRefusalLogsItsFixedReasonAndSendsIt() async throws {
        for (fields, reason) in Self.refusals {
            let logs = RefusalLogRecorder()
            let output = try await relay(fields, logs: logs)
            #expect(output.frames.isEmpty, "\(reason)")
            #expect(errors(output) == [Self.invalidRequest(reason)], "\(reason)")
            expectOneRefusalLine(logs, reason: reason, failure: Self.invalidRequest(reason))
            try expectReasonOnTheWire(output, reason)
        }
    }

    /// A user turn, an assistant turn carrying `calls`, then `rest`: by default
    /// the result for `c1`, empty for none.
    static func history(_ calls: String, then rest: String = result) -> String {
        #""messages":[{"role":"user","content":"zq-private-7f3a"},{"role":"assistant","content":null,"tool_calls":["#
            + calls + "]}" + (rest.isEmpty ? "" : "," + rest) + "]"
    }

    /// A call of `f` with `id` and its JSON `arguments`.
    static func call(_ id: String = "c1", arguments: String = #""{}""#) -> String {
        #"{"id":"\#(id)","type":"function","function":{"name":"f","arguments":\#(arguments)}}"#
    }

    static let declared = #""tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}]"#

    /// Request shapes the GLM prompt policy and tool-choice preparation refuse
    /// once the inference task runs. Before, each logged only the bare
    /// `Inference failure: invalid request`.
    static let promptRefusals: [(fields: [String], reason: InferenceRefusalReason)] = [
        ([history(call(), then: "")], .unansweredToolCall),
        ([history(call(), then: #"{"role":"user","content":"zq-private-7f3a"}"#)], .unansweredToolCall),
        ([history(call(), then: #"{"role":"tool","tool_call_id":"c2","content":"zq-private-7f3a"}"#)],
         .unmatchedToolResult),
        ([history(call(), then: result + "," + result)], .unmatchedToolResult),
        ([history(call() + "," + call())], .invalidToolHistory),
        ([history(call(arguments: #""{\"zq-private-7f3a\":1,\"zq-private-7f3a\":2}""#))], .invalidToolArguments),
        ([history(call(arguments: #""{\"a\":\"zq-private-7f3a</arg_value>\"}""#))], .nativeDelimiterInHistory),
        ([user, #""tools":[{"type":"function","function":{"name":"zq-private-7f3a.f","parameters":{"type":"object"}}}]"#],
         .invalidToolDeclaration),
        ([user, declared, #""tool_choice":{"type":"function","function":{"name":"zq-private-7f3a"}}"#],
         .invalidToolChoice),
        ([user, #""tool_choice":"required","tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"zq-private-7f3a":{"anyOf":[{"type":"string"},{"type":"null"}]}}}}}]"#],
         .unsupportedForcedToolChoice),
    ]

    @Test func promptRefusalsLogTheirReasonAndSendIt() async throws {
        for (fields, reason) in Self.promptRefusals {
            let refused = InferenceFailure(
                code: .invalidRequest, statusCode: 400, errorReason: .clientError, refusal: reason)
            let logs = RefusalLogRecorder()
            let output = try await relay(fields, logs: logs)
            #expect(output.frames.isEmpty, "\(reason)")
            #expect(errors(output) == [refused], "\(reason)")
            expectOneRefusalLine(logs, reason: reason, failure: refused)
            try expectReasonOnTheWire(output, reason)
        }
    }

    /// Typed engine refusals name their reason; others keep the bare line, and
    /// only an `invalid_request` failure is given one.
    @Test func promptRefusalReasonsComeFromTheTypedError() {
        let typed: [(MultiModelBatchSchedulerEngineError, InferenceRefusalReason?)] = [
            (.advertisedContextExceeded, .requestExceedsContext),
            (.unsupportedOutputControl("unsupported_output_control: this model's engine does not return logprobs"),
             .unsupportedOutputControl),
            (.invalidRole("critic"), .unsupportedMessageRole),
            (.unsupportedReasoningEffort(.reasoningEffort), .unsupportedReasoningControl),
            (.unsupportedReasoningEffort(.reasoningObject), .unsupportedReasoningControl),
            (.conflictingReasoningEfforts, .contradictoryReasoningControls),
            (.invalidToolPayload("GLM5: history is missing a tool result", refusal: .unansweredToolCall),
             .unansweredToolCall),
            (.invalidToolPayload("tool message has no preceding assistant tool_calls"), nil),
            (.toolChoiceViolation("model did not emit the required tool call"), nil),
            (.missingUserQuery, .missingUserQuery),
        ]
        for (error, reason) in typed {
            #expect(InferenceRefusalReason(promptRefusal: error) == reason, "\(error)")
            let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .streamStart)
            #expect(failure.refusal == (failure.code == .invalidRequest ? reason : nil), "\(error)")
        }
        #expect(InferenceRefusalReason(promptRefusal: CancellationError()) == nil)
        let invalid = ProviderLoop.sanitizedInferenceFailure(from: MultiModelBatchSchedulerEngineError
            .advertisedContextExceeded, phase: .streamStart)
        #expect(invalid.code == .invalidRequest && invalid.refusal == .requestExceedsContext)
        let capacity = ProviderLoop.sanitizedInferenceFailure(from: MultiModelBatchSchedulerEngineError
            .tokenBudgetExhausted("token_budget_exhausted: context length exceeded"), phase: .streamStart)
        #expect(capacity.code == .capacity && capacity.refusal == nil)
    }

    /// Qwen 3.5/3.6/3.8's message checks refuse a tool conversation before the
    /// template renders (OR-REFUSALS §1); each names which check refused it.
    @Test func qwenToolConversationRefusalsNameTheirCheck() throws {
        let call: [String: any Sendable] = ["id": "c1", "type": "function",
            "function": ["name": "f", "arguments": "{}"] as [String: any Sendable]]
        let unnamed: [String: any Sendable] = ["id": "c1", "type": "function",
            "function": ["arguments": "{}"] as [String: any Sendable]]
        let cases: [(messages: [[String: any Sendable]], reason: InferenceRefusalReason)] = [
            ([["role": "system", "content": Self.secret]], .missingUserQuery),
            ([["role": "system", "content": Self.secret],
              ["role": "user", "content": "<tool_response>\(Self.secret)</tool_response>"]], .missingUserQuery),
            ([["role": "user", "content": Self.secret],
              ["role": "tool", "tool_call_id": "c1", "content": Self.secret]], .unmatchedToolResult),
            ([["role": "user", "content": Self.secret],
              ["role": "assistant", "content": "", "tool_calls": [call] as [any Sendable]],
              ["role": "user", "content": Self.secret],
              ["role": "tool", "tool_call_id": "c1", "content": Self.secret]], .unmatchedToolResult),
            ([["role": "user", "content": Self.secret],
              ["role": "assistant", "content": "", "tool_calls": [unnamed] as [any Sendable]]], .invalidToolHistory),
        ]
        let context = ChatTemplateFixContext(modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8", modelType: "qwen3_5_moe")
        for (messages, reason) in cases {
            let error = try #require(throws: MultiModelBatchSchedulerEngineError.self) {
                try ChatTemplateFixes.normalizeMessages(messages, context: context)
            }
            #expect(InferenceRefusalReason(promptRefusal: error) == reason, "\(reason)")
            let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .streamStart)
            #expect(failure == InferenceFailure(
                code: .invalidRequest, statusCode: 400, errorReason: .clientError, refusal: reason), "\(reason)")
            let frame = try Self.wireFrame(failure)
            #expect(frame["error"] as? String == "Invalid inference request.", "the client-facing text is unchanged")
            #expect(frame["refusal_reason"] as? String == reason.rawValue)
            #expect(frame["refusal_message"] as? String == reason.clientMessage)
        }
    }

    /// The other model families' history checks name theirs too.
    @Test func otherHistoryChecksNameTheirCheck() throws {
        func call(_ id: String) -> [String: any Sendable] {
            ["id": id, "type": "function", "function": ["name": "f", "arguments": "{}"] as [String: any Sendable]]
        }
        let user: [String: any Sendable] = ["role": "user", "content": Self.secret]
        let twoCalls: [String: any Sendable] = ["role": "assistant", "content": "",
                                                "tool_calls": [call("c1"), call("c2")] as [any Sendable]]
        let cases: [(context: ChatTemplateFixContext, messages: [[String: any Sendable]], reason: InferenceRefusalReason)] = [
            (.init(modelType: "gpt_oss"), [user, ["role": "assistant", "content": "",
                "tool_calls": [call("c1"), call("c1")] as [any Sendable]]], .invalidToolHistory),
            (.init(modelType: "gpt_oss"), [user, twoCalls, ["role": "tool", "content": Self.secret]],
             .unmatchedToolResult),
            (.init(modelType: "gpt_oss"), [user, twoCalls, ["role": "tool", "tool_call_id": "c1", "content": "a"],
                ["role": "tool", "tool_call_id": "c1", "content": "b"]], .unmatchedToolResult),
            (.init(modelType: "gpt_oss"), [user, twoCalls, ["role": "tool", "tool_call_id": "c9", "content": "a"]],
             .unmatchedToolResult),
        ]
        for (context, messages, reason) in cases {
            let error = try #require(throws: MultiModelBatchSchedulerEngineError.self) {
                try ChatTemplateFixes.normalizeMessages(messages, context: context)
            }
            #expect(InferenceRefusalReason(promptRefusal: error) == reason, "\(error)")
        }
    }

    /// The reason rides the frame only when a refusal names one: every other
    /// frame keeps its legacy bytes, and an unknown reason decodes to nil.
    @Test func theReasonRidesTheFrameOnlyWhenNamed() throws {
        let named = try Self.wireFrame(Self.invalidRequest(.missingUserQuery))
        #expect(named["refusal_reason"] as? String == "missing_user_query")
        #expect(named["refusal_message"] as? String
            == "The conversation needs a user message that is more than a tool result.")
        #expect(named["error"] as? String == "Invalid inference request.")
        let bare = try Self.wireFrame(InferenceFailure(code: .invalidRequest, statusCode: 400))
        #expect(bare["refusal_reason"] == nil && bare["refusal_message"] == nil)

        let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: try ProviderProtocolCodec
            .encodeProviderMessage(.inferenceError(.init(requestId: "r", failure: Self.invalidRequest(.unmatchedToolResult)))))
        guard case .inferenceError(let error) = decoded else { Issue.record("not an inference_error"); return }
        #expect(error.refusalReason == .unmatchedToolResult)
        var unknown = named
        unknown["refusal_reason"] = "a_newer_reason"
        let fromNewer = try ProviderProtocolCodec.decodeProviderMessage(
            from: try JSONSerialization.data(withJSONObject: unknown))
        guard case .inferenceError(let newer) = fromNewer else { Issue.record("not an inference_error"); return }
        #expect(newer.refusalReason == nil)
    }

    /// Every message is one fixed sentence, distinct per reason.
    @Test func everyReasonHasItsOwnClientMessage() {
        let messages = InferenceRefusalReason.allCases.map(\.clientMessage)
        #expect(Set(messages).count == messages.count)
        #expect(messages.allSatisfy { !$0.isEmpty && $0.utf8.count <= 96 && $0.hasSuffix(".") })
    }

    @Test func unsupportedAudioLogsItsReasonAndSendsIt() async throws {
        let logs = RefusalLogRecorder()
        let audio = #""messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"zq-private-7f3a","format":"wav"}}]}]"#
        let output = try await relay([audio], logs: logs)
        let media = InferenceFailure(code: .invalidMedia, statusCode: 400, errorReason: .clientError,
                                     refusal: .unsupportedAudio)
        #expect(errors(output) == [media])
        expectOneRefusalLine(logs, reason: .unsupportedAudio, failure: media)
        try expectReasonOnTheWire(output, .unsupportedAudio)
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
            #expect(failures == [Self.invalidRequest(reason)], "\(reason)")
            expectOneRefusalLine(logs, reason: reason, failure: Self.invalidRequest(reason))
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
        .unansweredToolCall: "Inference failure: invalid request (unanswered tool call)",
        .unmatchedToolResult: "Inference failure: invalid request (unmatched tool result)",
        .nativeDelimiterInHistory: "Inference failure: invalid request (native delimiter in history)",
        .nonTextContent: "Inference failure: invalid request (non-text content)",
        .unsupportedForcedToolChoice: "Inference failure: invalid request (unsupported forced tool choice)",
        .requestExceedsContext: "Inference failure: invalid request (request exceeds context)",
        .unsupportedOutputControl: "Inference failure: invalid request (unsupported output control)",
        .missingUserQuery: "Inference failure: invalid request (missing user query)",
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

    /// The encoded `inference_error` frame of a failure.
    static func wireFrame(_ failure: InferenceFailure) throws -> [String: Any] {
        let data = try ProviderProtocolCodec.encodeProviderMessage(
            .inferenceError(.init(requestId: requestID, failure: failure)))
        #expect(!String(decoding: data, as: UTF8.self).contains(secret))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The one refusal frame names `reason` and its fixed message, and keeps
    /// the legacy `error` text.
    func expectReasonOnTheWire(_ output: ScriptedCoordinatorRelay.Output, _ reason: InferenceRefusalReason) throws {
        let failures = errors(output)
        #expect(failures.count == 1, "\(reason)")
        guard let failure = failures.first else { return }
        let frame = try Self.wireFrame(failure)
        #expect(frame["refusal_reason"] as? String == reason.rawValue, "\(reason)")
        #expect(frame["refusal_message"] as? String == reason.clientMessage, "\(reason)")
        #expect(frame["error"] as? String == failure.code.message, "\(reason)")
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
