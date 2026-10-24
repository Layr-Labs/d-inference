#if DEBUG
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Replays scripted GLM-5.3-Flash output through the production coordinator
/// handler: real bridge, scheduler engine, native reasoning router, SDK
/// framing and frames loop. Scripted engine output is not a model-quality or
/// GPU assertion.
@Suite("GLM-5.3-Flash reasoning visibility", .serialized)
struct GLM5NextReasoningVisibilityTests {
    static let modelID = "test/glm5-visibility"
    static let thought = "Weigh the request."
    /// The prompt already opened the thought: two reasoning chunks, the close,
    /// then the answer. One engine token per chunk.
    static let chunks = ["Weigh ", "the request.", "</think>", "Answer."]
    static let stops: Set<Int> = [154_820, 154_827, 154_829]
    /// OpenRouter's documented hidden-reasoning spellings, and Anthropic's
    /// through the coordinator's Messages lowering.
    static let declining = [
        #""reasoning":{"exclude":true}"#, #""include_reasoning":false"#,
        #""reasoning":{"effort":"high","exclude":true}"#,
        #""thinking":{"type":"enabled","budget_tokens":2048,"display":"omitted"}"#,
    ]
    static let requestID = "glm-visibility-request"

    @Test func coordinatorRelayWithholdsCountsAndHashesOnlyWhatItSends() async throws {
        for control in Self.declining + [nil] as [String?] {
            let label = control ?? "visible"
            let run = try await relay(control) { continuation in
                for chunk in Self.chunks {
                    continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil))
                }
                continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 1, completionTokens: 20)))
                continuation.finish()
            }
            #expect(run.errors.isEmpty, "\(label): \(run.errors)")
            #expect(run.content == "Answer.", "\(label)")
            #expect(run.reasoning == (control == nil ? Self.thought : ""), "\(label)")
            #expect(run.deltaKeys.isDisjoint(with: ["reasoning", "reasoning_content"]) == (control != nil),
                "\(label)")
            // One token per reasoning character: withheld reasoning is billed
            // exactly like visible reasoning.
            let reasoningTokens = Self.thought.count
            #expect(run.usageFrame?.completion == 20 && run.usageFrame?.reasoning == reasoningTokens, "\(label)")
            let complete = try #require(run.complete, "\(label)")
            #expect(complete.usage.completionTokens == 20, "\(label)")
            #expect(complete.usage.reasoningTokens == UInt64(reasoningTokens), "\(label)")
            // The response hash commits to exactly the emitted bytes.
            let emitted = control == nil ? Self.thought + "Answer." : "Answer."
            #expect(complete.hash == computeResponseAttestation(identity: nil, requestId: Self.requestID,
                completionTokens: 20, responseBody: emitted).hash, "\(label)")
        }
    }

    /// GLM's prompt opens the thought, so withheld reasoning starts at the
    /// first generated entry; none of it returns as logprob entry tokens.
    @Test func coordinatorRelayLogprobsOmitWithheldReasoning() async throws {
        let ids = [5, 5, 154_842, 5]
        for control in Self.declining + [nil] as [String?] {
            let label = control ?? "visible"
            let fields = [control, #""logprobs":true,"top_logprobs":1"#].compactMap { $0 }.joined(separator: ",")
            let run = try await relay(fields) { continuation in
                for (chunk, id) in zip(Self.chunks, ids) {
                    continuation.yield(.delta(text: chunk, tokens: [5],
                        logprobs: [.init(token: id, logprob: -0.5, topLogprobs: [(token: id, logprob: -0.5)])]))
                }
                continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 1, completionTokens: 20)))
                continuation.finish()
            }
            #expect(run.errors.isEmpty && run.content == "Answer.", "\(label)")
            #expect(run.logprobTokens == (control == nil ? ["x", "x", "</think>", "x"] : ["x"]),
                "\(label): \(run.logprobTokens)")
        }
    }

    /// Thinking off with the exclusion: the prompt closes the thought, the
    /// answer and its entries pass, and nothing is counted as reasoning.
    @Test func thinkingOffWithExclusionKeepsTheWholeAnswer() async throws {
        let fields = #""reasoning":{"enabled":false,"exclude":true},"logprobs":true,"top_logprobs":1"#
        let run = try await relay(fields) { continuation in
            continuation.yield(.delta(text: "Answer.", tokens: [5],
                logprobs: [.init(token: 5, logprob: -0.5, topLogprobs: [(token: 5, logprob: -0.5)])]))
            continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 1, completionTokens: 1)))
            continuation.finish()
        }
        #expect(run.errors.isEmpty && run.content == "Answer." && run.reasoning.isEmpty)
        #expect(run.logprobTokens == ["x"])
        #expect(run.complete?.usage.reasoningTokens == 0)
    }

    struct RelayRun {
        var content = ""
        var reasoning = ""
        var deltaKeys: Set<String> = []
        var logprobTokens: [String] = []
        var usageFrame: (completion: Int?, reasoning: Int?)?
        var complete: (usage: UsageInfo, hash: String?)?
        var errors: [InferenceFailure] = []
    }

    func relay(
        _ control: String?, script: (AsyncStream<CBv2Event>.Continuation) async -> Void
    ) async throws -> RelayRun {
        var fields = [#""model":"\#(Self.modelID)""#, #""messages":[{"role":"user","content":"hi"}]"#,
            #""max_tokens":64"#, #""stream":true"#]
        if let control { fields.append(control) }
        let tokenizer = TokenizerHandle(try GLM5NextThinkingTokenizer(base: GLMVisibilityTokenizer()))
        let output = try await ScriptedCoordinatorRelay.run(modelID: Self.modelID, modelType: "glm5_next",
            tokenizer: tokenizer, containerTokenizer: GLMVisibilityTokenizer(), eosTokenIds: Self.stops,
            requestID: Self.requestID, fields: fields) { continuation, _ in
            await script(continuation)
        }
        var run = RelayRun()
        for frame in output.frames {
            for line in frame.split(separator: "\n") where line.hasPrefix("data: ") && line != "data: [DONE]" {
                guard let object = try JSONSerialization.jsonObject(
                    with: Data(line.dropFirst(6).utf8)) as? [String: Any] else { continue }
                let choice = (object["choices"] as? [[String: Any]])?.first
                let entries = (choice?["logprobs"] as? [String: Any])?["content"]
                run.logprobTokens += (entries as? [[String: Any]] ?? []).compactMap { $0["token"] as? String }
                if let delta = choice?["delta"] as? [String: Any] {
                    run.deltaKeys.formUnion(delta.keys)
                    run.content += delta["content"] as? String ?? ""
                    run.reasoning += delta["reasoning_content"] as? String ?? ""
                }
                if let usage = object["usage"] as? [String: Any] {
                    let details = usage["completion_tokens_details"] as? [String: Any]
                    run.usageFrame = (usage["completion_tokens"] as? Int, details?["reasoning_tokens"] as? Int)
                }
            }
        }
        for message in output.terminals {
            switch message {
            case .inferenceComplete(_, let usage, _, _, let hash, _):
                run.complete = (usage, hash)
            case .inferenceError(_, let failure, _):
                run.errors.append(failure)
            default:
                break
            }
        }
        return run
    }
}

/// GLM's think and turn markers. The rendered prompt ends with the template's
/// open `<think>`; every other character is one token, so reasoning
/// re-tokenizes to a predictable count, and ordinary ids decode to "x".
struct GLMVisibilityTokenizer: MLXLMCommon.Tokenizer {
    private static let markers: [String: Int] = [
        "<|endoftext|>": 154_820, "<|user|>": 154_827, "<|assistant|>": 154_828,
        "<|observation|>": 154_829, "<think>": 154_841, "</think>": 154_842,
    ]
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Self.markers[text].map { [$0] } ?? Array(repeating: 5, count: text.count)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { convertIdToToken($0) ?? "x" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { Self.markers[token] }
    func convertIdToToken(_ id: Int) -> String? { Self.markers.first { $0.value == id }?.key }
    var bosToken: String? { nil }
    var eosToken: String? { "<|endoftext|>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        [154_827, 5, 154_828, 154_841]
    }
}
#endif
