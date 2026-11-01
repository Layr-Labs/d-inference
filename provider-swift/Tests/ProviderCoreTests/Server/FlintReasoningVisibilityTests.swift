import Foundation
import Hummingbird
import HummingbirdTesting
import MLX
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing

@testable import ProviderCore

/// Replays scripted Flint output through the production scheduler, native
/// router, SDK framing, local HTTP routes and coordinator relay. Scripted
/// engine output is not a model-quality or GPU assertion.
@Suite("Flint reasoning visibility", .serialized)
struct FlintReasoningVisibilityTests {
    static let modelID = "test/flint-visibility"
    static let thought = "Weigh the request."
    /// One engine token per chunk; three of the five are reasoning.
    static let chunks = ["<think>", "Weigh ", "the request.", "</think>", "Answer."]
    static let stops: Set<Int> = [150001, 150003, 150005, 150018]
    static let declining = [
        #""reasoning":{"exclude":true}"#, #""include_reasoning":false"#, #""reasoning":{"enabled":false}"#,
    ]
    /// One handle, so the native protocol vocabulary is built once.
    static let tokenizer = TokenizerHandle(FlintVisibilityTokenizer())

    @Test func reasoningLogprobsFilterDropsOnlyTheInitialThought() {
        func entries(_ tokens: [String]) -> [SSETokenLogprob] {
            tokens.map { SSETokenLogprob(token: $0, logprob: -1, bytes: Array($0.utf8).map(Int.init), topLogprobs: []) }
        }
        // Markers assembled from ordinary tokens, split across drains.
        var split = WithheldReasoningLogprobsFilter()
        #expect(split.visible(entries(["<th", "ink>", "plan"])).isEmpty)
        #expect(split.visible(entries([" </thi", "nk>"])).isEmpty)
        #expect(split.visible(entries(["Answer", "."])).map(\.token) == ["Answer", "."])
        // Dedicated marker tokens.
        var dedicated = WithheldReasoningLogprobsFilter()
        #expect(dedicated.visible(entries(["<think>", "a", "</think>", "B"])).map(\.token) == ["B"])
        // A direct answer keeps every entry, including a held "<" prefix.
        var direct = WithheldReasoningLogprobsFilter()
        #expect(direct.visible(entries(["<", "Hi"])).map(\.token) == ["<", "Hi"])
        // An undecided prefix is never released early, and an unclosed thought never.
        var pending = WithheldReasoningLogprobsFilter()
        #expect(pending.visible(entries(["<thi"])).isEmpty)
        var unclosed = WithheldReasoningLogprobsFilter()
        #expect(unclosed.visible(entries(["<think>", "</thin", "k"])).isEmpty)
    }

    @Test func localChatAndResponsesWithholdDeclinedReasoningButCountIt() async throws {
        for control in Self.declining + [nil] as [String?] {
            for responses in [false, true] {
                for stream in [false, true] {
                    let label = "\(control ?? "visible") responses=\(responses) stream=\(stream)"
                    let (status, text) = try await serve(
                        body(control, responses: responses, stream: stream), responses: responses,
                        modelType: "flint")
                    #expect(status == .ok, "\(label)")
                    #expect(text.contains("Answer."), "\(label)")
                    // Local usage has no reasoning field, so any occurrence is
                    // reasoning output: reasoning_content, reasoning deltas,
                    // reasoning items or reasoning summary events.
                    #expect(text.contains("Weigh") == (control == nil), "\(label)")
                    #expect(text.contains("reasoning") == (control == nil), "\(label)")
                    // Withheld reasoning is still generated and billed output.
                    #expect(text.range(of: #""(completion|output)_tokens"\s*:\s*5\b"#,
                        options: .regularExpression) != nil, "\(label)")
                }
            }
        }
    }

    @Test func otherFamiliesKeepReturningReasoning() async throws {
        for responses in [false, true] {
            let (status, text) = try await serve(
                body(#""reasoning":{"exclude":true},"include_reasoning":false"#,
                    responses: responses, stream: false),
                responses: responses, modelType: "qwen4_exp")
            #expect(status == .ok)
            #expect(text.contains("Answer.") && text.contains(Self.thought))
        }
    }

    func body(_ control: String?, responses: Bool, stream: Bool) -> Data {
        var fields = [#""model":"\#(Self.modelID)""#, #""stream":\#(stream)"#]
        if responses {
            fields += [#""input":"hi""#, #""max_output_tokens":64"#]
        } else {
            fields += [#""messages":[{"role":"user","content":"hi"}]"#, #""max_tokens":64"#,
                #""stream_options":{"include_usage":true}"#]
        }
        if let control { fields.append(control) }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    func serve(_ body: Data, responses: Bool, modelType: String) async throws
        -> (HTTPResponse.Status, String)
    {
        let id = Self.modelID, tokenizer = Self.tokenizer
        let bridge = EngineV2Bridge(engine: VisibilityEngine(chunks: Self.chunks), modelId: id,
            tokenizer: tokenizer, eosTokenIds: Self.stops)
        let app = makeLocalInferenceApplication(config: .init(port: 0), defaultMaxTokens: 256,
            acquire: { _ in .init(tokenizer: tokenizer,
                releaseToken: .init(release: { _ in }, modelId: id),
                modelType: modelType, engineV2Bridge: bridge) },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: modelType) },
            availableModels: { [id] }, mtpSlots: { [] })
        do {
            let result = try await app.test(.ahc()) { client in
                let response = try await client.execute(
                    uri: responses ? "/v1/responses" : "/v1/chat/completions", method: .post,
                    headers: [.contentType: "application/json"], body: ByteBuffer(data: body))
                return (response.status, String(buffer: response.body))
            }
            await bridge.shutdown()
            return result
        } catch {
            await bridge.shutdown()
            throw error
        }
    }
}

#if DEBUG
extension FlintReasoningVisibilityTests {
    @Test func coordinatorRelayWithholdsCountsAndHashesOnlyWhatItSends() async throws {
        for control in Self.declining + [nil] as [String?] {
            let label = control ?? "visible"
            let run = try await relay(control) { continuation in
                for chunk in Self.chunks {
                    continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil))
                }
                continuation.yield(.finished(reason: .stop,
                    usage: .init(promptTokens: 1, completionTokens: 20)))
                continuation.finish()
            }
            #expect(run.errors.isEmpty, "\(label)")
            #expect(run.content == "Answer.", "\(label)")
            #expect(run.reasoning == (control == nil ? Self.thought : ""), "\(label)")
            #expect(run.deltaKeys.isDisjoint(with: ["reasoning", "reasoning_content"]) == (control != nil),
                "\(label)")
            // The tokenizer counts one token per reasoning character; the
            // withheld reasoning is billed exactly like visible reasoning.
            let reasoningTokens = Self.thought.count
            #expect(run.usageFrame?.completion == 20 && run.usageFrame?.reasoning == reasoningTokens,
                "\(label)")
            let complete = try #require(run.complete, "\(label)")
            #expect(complete.usage.completionTokens == 20, "\(label)")
            #expect(complete.usage.reasoningTokens == UInt64(reasoningTokens), "\(label)")
            // TB-007: the hash commits to exactly the emitted bytes.
            let emitted = control == nil ? Self.thought + "Answer." : "Answer."
            #expect(complete.hash == computeResponseAttestation(identity: nil, requestId: Self.requestID,
                completionTokens: 20, responseBody: emitted).hash, "\(label)")
        }
    }

    /// Logprobs cover every sampled token. Visible reasoning keeps today's
    /// attachment to the first content frame; withheld reasoning never
    /// returns as entry tokens.
    @Test func coordinatorRelayLogprobsOmitWithheldReasoning() async throws {
        let ids = [150006, 5, 5, 150007, 5]
        for control in Self.declining + [nil] as [String?] {
            let label = control ?? "visible"
            let fields = [control, #""logprobs":true,"top_logprobs":1"#].compactMap { $0 }.joined(separator: ",")
            let run = try await relay(fields) { continuation in
                for (chunk, id) in zip(Self.chunks, ids) {
                    continuation.yield(.delta(text: chunk, tokens: [5],
                        logprobs: [.init(token: id, logprob: -0.5, topLogprobs: [(token: id, logprob: -0.5)])]))
                }
                continuation.yield(.finished(reason: .stop,
                    usage: .init(promptTokens: 1, completionTokens: 20)))
                continuation.finish()
            }
            #expect(run.errors.isEmpty && run.content == "Answer.", "\(label)")
            #expect(run.logprobTokens == (control == nil ? ["<think>", "x", "x", "</think>", "x"] : ["x"]),
                "\(label): \(run.logprobTokens)")
        }
    }

    /// Withheld reasoning is generated output, so a long hidden reasoning
    /// phase cannot turn the first visible answer into a pre-content refusal.
    @Test func withheldReasoningEndsThePreContentDeadline() async throws {
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 1_500)
        let run = try await relay(Self.declining[0], deadline: deadline) { continuation in
            for chunk in Self.chunks.prefix(3) {
                continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil))
            }
            let clock = ContinuousClock()
            try? await clock.sleep(until: deadline.instant.advanced(by: .milliseconds(250)))
            for chunk in Self.chunks.suffix(2) {
                continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil))
            }
            continuation.yield(.finished(reason: .stop,
                usage: .init(promptTokens: 1, completionTokens: 20)))
            continuation.finish()
        }
        #expect(run.errors.isEmpty)
        #expect(run.content == "Answer." && run.reasoning.isEmpty)
        #expect(run.complete?.usage.reasoningTokens == UInt64(Self.thought.count))
    }

    static let requestID = "flint-visibility-request"

    struct RelayRun {
        var content = ""
        var reasoning = ""
        var deltaKeys: Set<String> = []
        var logprobTokens: [String] = []
        var usageFrame: (completion: Int?, reasoning: Int?)?
        var complete: (usage: UsageInfo, hash: String?)?
        var errors: [InferenceFailure] = []
    }

    /// Drives one sealed request through the production coordinator handler.
    func relay(
        _ control: String?, deadline: FirstContentDeadline? = nil,
        script: (AsyncStream<CBv2Event>.Continuation) async -> Void
    ) async throws -> RelayRun {
        var fields = [#""model":"\#(Self.modelID)""#, #""messages":[{"role":"user","content":"hi"}]"#,
            #""max_tokens":64"#, #""stream":true"#]
        if let control { fields.append(control) }
        let output = try await ScriptedCoordinatorRelay.run(modelID: Self.modelID, modelType: "flint",
            tokenizer: Self.tokenizer, containerTokenizer: FlintVisibilityTokenizer(), eosTokenIds: Self.stops,
            requestID: Self.requestID, fields: fields, deadline: deadline) { continuation, _ in
            await script(continuation)
        }

        var run = RelayRun()
        for frame in output.frames {
            for line in frame.split(separator: "\n") where line.hasPrefix("data: ") && line != "data: [DONE]" {
                guard let object = try JSONSerialization.jsonObject(
                    with: Data(line.dropFirst(6).utf8)) as? [String: Any] else { continue }
                let entries = ((object["choices"] as? [[String: Any]])?.first?["logprobs"] as? [String: Any])?["content"]
                run.logprobTokens += (entries as? [[String: Any]] ?? []).compactMap { $0["token"] as? String }
                if let delta = (object["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] {
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
#endif

/// Replays fixed chunks, one engine token each, then reports that usage.
private final class VisibilityEngine: CBv2Engine, @unchecked Sendable {
    let chunks: [String]
    init(chunks: [String]) { self.chunks = chunks }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        AsyncStream { continuation in
            for chunk in chunks { continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil)) }
            continuation.yield(.finished(reason: .stop,
                usage: .init(promptTokens: request.promptTokens.count, completionTokens: chunks.count)))
            continuation.finish()
        }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

/// Flint's pinned protocol markers, so the native vocabulary and assistant
/// boundary validate, with one token per character elsewhere so reasoning
/// re-tokenizes to a predictable count.
struct FlintVisibilityTokenizer: MLXLMCommon.Tokenizer {
    private let markers = FlintProtocolTestTokenizer()
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        markers.convertTokenToId(text).map { [$0] } ?? Array(repeating: 5, count: text.count)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        markers.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { markers.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { markers.convertIdToToken(id) }
    var bosToken: String? { markers.bosToken }
    var eosToken: String? { markers.eosToken }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [150004] }
}
