import CryptoKit
import Foundation
import MLXLMCommon
import MLXLMServer

@testable import ProviderCore

extension ServingQualificationFixture {
    func request(targetTokens: Int, nonce: String) throws -> (OpenAIChatCompletionRequest, [Int]) {
        // Screen-only baselines retain a simple fixed shape. Independent
        // training/heldout jobs vary actual payload, schema and history bytes,
        // not merely a request ID attached to repeated alpha padding.
        var generator = QualificationPromptGenerator(seed: nonce)
        let varied = job.partition != "baseline"
        let pieces = varied ? (0..<targetTokens).map { _ in generator.piece() } : []
        let fieldCount = 4 + Int(generator.next() % 13)
        let properties = Dictionary(uniqueKeysWithValues: (0..<fieldCount).map { index in
            ("field_\(index)", MLXLMCommon.JSONValue.object([
                "type": .string("string"),
                "description": .string("Reference \(generator.next()) for \(generator.piece())")]))
        })
        let historyValue = String(generator.next())
        func make(_ padding: Int, tail: Int = 0) -> OpenAIChatCompletionRequest {
            let reference = varied ? pieces.prefix(padding).joined() : String(repeating: " alpha", count: padding)
            var request = OpenAIChatCompletionRequest(
                model: job.modelID,
                messages: [.init(role: .system, content: .text("You are a careful assistant.")),
                           .init(role: .user, content: .text("Trial \(nonce). Reference:" + reference + String(repeating: " alpha", count: tail)
                              + "\nList the integers from 1 to 1000, one per line. Do not call tools, summarize, or stop early."))],
                reasoning: .init(enabled: false), temperature: 0, topP: 1, topK: 0, minP: 0,
                maxTokens: job.outputTokens)
            request.stream = true
            request.streamOptions = .init(includeUsage: true)
            if job.toolHistory {
                request.messages.insert(contentsOf: [
                    .init(role: .user, content: .text("Retrieve reference \(historyValue).")),
                    .init(role: .assistant, content: .null, toolCalls: [
                        .init(id: "call_reference", function: .init(name: "lookup_reference",
                            arguments: "{\"field_0\":\"\(historyValue)\"}"))]),
                    .init(role: .tool, content: .text("{\"reference\":\"\(historyValue)\",\"verified\":true}"),
                        toolCallID: "call_reference")], at: 1)
                request.tools = [.init(function: .init(name: "lookup_reference", description: "Look up reference data.",
                    parameters: .object(["type": .string("object"), "properties": .object(properties),
                                         "required": .array([.string("field_0")])])))]
                request.toolChoice = .mode(.auto)
                request.toolCallParser = "qwen3_coder"
            }
            return request
        }
        func tokenize(_ request: OpenAIChatCompletionRequest) throws -> [Int] {
            try ProviderPromptContractPipeline.tokenize(
                prepared: ToolChoicePromptPolicy.prepare(request), request: request,
                tokenizer: tokenizer.inner, modelType: "qwen3_5", templateControls: .init())
        }
        var low = 0, high = targetTokens
        while low < high {
            let mid = (low + high + 1) / 2
            if try tokenize(make(mid)).count <= targetTokens { low = mid } else { high = mid - 1 }
        }
        var result = make(low)
        var tokens = try tokenize(result)
        if tokens.count < targetTokens {
            // Fill only the rendered text's small final gap, before template
            // application; never splice token IDs after tokenization.
            result = make(low, tail: targetTokens - tokens.count)
            tokens = try tokenize(result)
        }
        // No post-template token splicing: a nonexact length is reported and
        // cannot later certify an unmeasured context boundary.
        guard tokens.count == targetTokens, tokens.count + job.outputTokens <= sizing.maxContextLength else {
            throw QualificationFailure.contextExceeded
        }
        return (result, tokens)
    }

}

private struct QualificationPromptGenerator {
    private var state: UInt64
    private let family: Int
    private static let words = ["amber", "river", "matrix", "copper", "forest", "window", "signal", "orbit",
        "harbor", "thread", "integer", "velocity", "season", "quiet", "violet", "packet", "sample",
        "stable", "kernel", "branch", "cursor", "memory", "review", "balance"]

    init(seed: String) {
        let bytes = Array(SHA256.hash(data: Data(seed.utf8)))
        state = bytes.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) } | 1
        family = Int(bytes[8] % 4)
    }

    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }

    mutating func piece() -> String {
        let value = next()
        let word = Self.words[Int(value % UInt64(Self.words.count))]
        switch family {
        case 1: return " \(word)_\(value % 100_000)"
        case 2: return " {\"\(word)\":\(value % 100_000)}"
        case 3: return "\nlet \(word) = \(value % 100_000);"
        default: return " \(word)"
        }
    }
}
