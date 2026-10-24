import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

#if DEBUG
/// GLM-5.3-Flash logprobs on the coordinator relay, the only path that returns
/// them: scripted engine tokens through the production handler, scheduler
/// engine and frames loop. `logprobs.content` has one entry per generated token
/// in generation order, reasoning tokens included, and each entry rides the
/// chunk of its token (a marker that renders nothing rides the next chunk).
@Suite("GLM-5.3-Flash relay logprobs", .serialized)
struct GLM5NextRelayLogprobsTests {
    static let modelID = "test/glm-relay-logprobs"
    static let thinkEnd = 3, eos = 99
    /// GLM's template ends the prompt inside an open thought.
    static let vocabulary: [Int: String] = [100: "<|assistant|><think>", 1: "Plan", 2: " it.", thinkEnd: "</think>",
                                            4: "Hello", 5: " there.", 6: " More", eos: ""]
    static let tokenizer = TokenizerHandle(GLMRelayTokenizer())

    /// One relayed chat-completion chunk: its text and the entry tokens it carries.
    struct Chunk {
        var reasoning = "", content = ""
        var entries: [String] = []
    }

    @Test func mixedReplyCarriesReasoningEntriesOnReasoningChunks() async throws {
        for stream in [true, false] {
            let chunks = try await relay([1, 2, Self.thinkEnd, 4, 5, Self.eos], finish: .stop, stream: stream)
            #expect(chunks.map(\.reasoning).joined() == "Plan it." && chunks.map(\.content).joined() == "Hello there.")
            // Joined, the entries spell the reasoning, the marker and the
            // answer; the stop token that ends the turn carries none.
            #expect(chunks.flatMap(\.entries) == ["Plan", " it.", "</think>", "Hello", " there."], "stream \(stream)")
            #expect(chunks.filter { !$0.reasoning.isEmpty }.flatMap(\.entries) == ["Plan", " it."], "stream \(stream)")
            #expect(chunks.filter { !$0.content.isEmpty }.flatMap(\.entries) == ["</think>", "Hello", " there."],
                "stream \(stream)")
            #expect(chunks.allSatisfy { $0.entries.isEmpty || !($0.reasoning + $0.content).isEmpty })
        }
    }

    @Test func thinkingOnlyReplyStillCarriesEveryEntry() async throws {
        for stream in [true, false] {
            let chunks = try await relay([1, 2, 6], finish: .length, stream: stream)
            #expect(chunks.map(\.reasoning).joined() == "Plan it. More" && chunks.map(\.content).joined().isEmpty)
            #expect(chunks.flatMap(\.entries) == ["Plan", " it.", " More"], "stream \(stream)")
            #expect(chunks.allSatisfy { $0.entries.isEmpty || !$0.reasoning.isEmpty })
        }
    }

    @Test func withoutLogprobsNoChunkCarriesEntries() async throws {
        let chunks = try await relay([1, 2, Self.thinkEnd, 4, Self.eos], finish: .stop, logprobs: false)
        #expect(chunks.map(\.content).joined() == "Hello" && chunks.allSatisfy { $0.entries.isEmpty })
    }

    /// Other models keep content-chunk attachment, so their reasoning-only
    /// replies still carry no entries.
    @Test func otherModelsKeepContentAttachment() async throws {
        let thinking = try await relay([1, 2, 6], finish: .length, modelType: "qwen3")
        #expect(thinking.map(\.reasoning).joined() == "Plan it. More" && thinking.allSatisfy { $0.entries.isEmpty })
        let mixed = try await relay([1, 2, Self.thinkEnd, 4, 5, Self.eos], finish: .stop, modelType: "qwen3")
        #expect(mixed.filter { !$0.content.isEmpty }.flatMap(\.entries) == ["Plan", " it.", "</think>", "Hello", " there."])
    }

    /// Relays `tokens` as one-token deltas. Each visible token waits for the
    /// chunk carrying its text before the next is generated.
    func relay(_ tokens: [Int], finish: CBv2FinishReason, modelType: String = "glm5_next",
               logprobs: Bool = true, stream: Bool = true) async throws -> [Chunk] {
        var fields = [#""model":"\#(Self.modelID)""#, #""messages":[{"role":"user","content":"hi"}]"#,
                      #""max_tokens":64"#, #""stream":\#(stream)"#]
        if logprobs { fields += [#""logprobs":true"#, #""top_logprobs":2"#] }
        let output = try await ScriptedCoordinatorRelay.run(modelID: Self.modelID, modelType: modelType,
            tokenizer: Self.tokenizer, containerTokenizer: GLMRelayTokenizer(), eosTokenIds: [Self.eos],
            requestID: "glm-relay-logprobs-\(UUID().uuidString)", fields: fields) { continuation, progress in
            var visible = ""
            for token in tokens {
                let text = Self.vocabulary[token] ?? ""
                continuation.yield(.delta(text: token == Self.eos ? "" : text, tokens: [token],
                    logprobs: [.init(token: token, logprob: -0.5, topLogprobs: [(token: token, logprob: -0.5), (token: 6, logprob: -2)])]))
                guard token != Self.eos, token != Self.thinkEnd else { continue }
                visible += text
                try await progress.wait { frames in
                    Self.chunks(frames).map { $0.reasoning + $0.content }.joined() == visible
                }
            }
            continuation.yield(.finished(reason: finish, usage: .init(promptTokens: 1, completionTokens: tokens.count)))
            continuation.finish()
        }
        let errors = output.terminals.compactMap { message -> InferenceFailure? in
            if case .inferenceError(_, let failure, _) = message { return failure }
            return nil
        }
        #expect(errors.isEmpty, "\(errors)")
        return Self.chunks(output.frames)
    }

    static func chunks(_ frames: [String]) -> [Chunk] {
        frames.flatMap { $0.split(separator: "\n") }.compactMap { line -> Chunk? in
            guard line.hasPrefix("data: {"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                  let choice = (object["choices"] as? [[String: Any]])?.first
            else { return nil }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            let entries = (choice["logprobs"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return Chunk(reasoning: delta["reasoning_content"] as? String ?? "",
                         content: delta["content"] as? String ?? "",
                         entries: entries.compactMap { $0["token"] as? String })
        }
    }
}

/// Fixed GLM-shaped vocabulary: the prompt renders to one token whose text ends
/// in GLM's open `<think>`, and each generated id decodes to one script piece.
private struct GLMRelayTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        GLM5NextRelayLogprobsTests.vocabulary.first { $0.value == text }.map { [$0.key] }
            ?? Array(repeating: 6, count: max(1, text.count / 4))
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { GLM5NextRelayLogprobsTests.vocabulary[$0] ?? "" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? {
        GLM5NextRelayLogprobsTests.vocabulary.first { $0.value == token }?.key
    }
    func convertIdToToken(_ id: Int) -> String? { GLM5NextRelayLogprobsTests.vocabulary[id] }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [100] }
}
#endif
