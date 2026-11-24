import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Inkling 2 Mini under the reasoning-loop guard, on the same policy as the
/// other families: guarded by default (its card warns of long reasoning
/// loops), off for constrained, forced and JSON outputs, disarmed at a call
/// message; the exit from a repeating thought has its markers and stays off
/// until its A/B, as Nemotron Super's does.
@Suite("Inkling 2 loop guard")
struct Inkling2LoopGuardTests {
    static let type = "inkling2_loop"
    static let tools = """
        [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
          "properties":{"location":{"type":"string"}},"required":["location"]}}}]
        """

    /// `choice`: the body's `tool_choice` JSON, as a client sends it.
    static func prepared(tools: Bool, choice: Any? = nil, json: Bool = false) throws
        -> (OpenAIChatCompletionRequest, ToolChoicePromptPolicy.Prepared)
    {
        var body: [String: Any] = [
            "model": "thinkingmachines/Inkling-2-Mini", "messages": [["role": "user", "content": "Solve it."]],
        ]
        if tools { body["tools"] = try JSONSerialization.jsonObject(with: Data(Self.tools.utf8)) }
        if json { body["response_format"] = ["type": "json_object"] }
        if let choice { body["tool_choice"] = choice }
        let request = try ProviderLoop.decodeOpenAIRequest(
            JSONSerialization.data(withJSONObject: body), modelType: type)
        return (request, try ToolChoicePromptPolicy.prepare(request, modelType: type))
    }

    static func guardFor(tools: Bool, choice: Any? = nil, json: Bool = false) throws
        -> GenerationLoopGuard?
    {
        let (request, prepared) = try Self.prepared(tools: tools, choice: choice, json: json)
        return GenerationLoopGuardPolicy.resolve(
            modelType: type, request: request, prepared: prepared, tokenConstraint: nil,
            setting: .modelTypes(GenerationLoopGuardPolicy.defaultModelTypes))
    }

    @Test func guardedByDefaultWithAndWithoutTools() throws {
        #expect(GenerationLoopGuardPolicy.defaultModelTypes.contains(Self.type))
        #expect(try Self.guardFor(tools: false) != nil)
        // No text tool parser decides Inkling's markers, so tools keep the guard.
        #expect(try Self.guardFor(tools: true) != nil)
    }

    @Test func constrainedOutputsHaveNoGuard() throws {
        #expect(try Self.guardFor(tools: true, choice: "required") == nil)
        #expect(try Self.guardFor(
            tools: true, choice: ["type": "function", "function": ["name": "get_weather"]]) == nil)
        #expect(try Self.guardFor(tools: false, json: true) == nil)
        #expect(GenerationLoopGuardPolicy.resolve(
            modelType: Self.type, request: try Self.prepared(tools: false).0,
            prepared: try Self.prepared(tools: false).1, tokenConstraint: nil, setting: .off) == nil)
    }

    /// A call message turns the guard off for the rest of the row, so a call's
    /// repeated arguments are never cut; a repeating thought still stops.
    @Test func callMessageDisarmsAndALoopStops() throws {
        let thresholds = GenerationLoopDetector.Thresholds(
            minPeriod: 2, maxPeriod: 8, minRepeats: 4, minSpan: 16, checkEvery: 1, minTokens: 16)
        var call = GenerationLoopGuard(
            modelType: Self.type, toolCallMarkers: Inkling2PromptContract.toolCallMarkers, thresholds: thresholds)
        _ = call.observe(text: "<|message_model|>get_weather<|content_invoke", tokens: [200001, 1, 2])
        #expect(!call.disarmed)
        _ = call.observe(text: "_tool_json|>{\"location\":", tokens: [200049, 3])
        #expect(call.disarmed)
        for _ in 0..<64 { #expect(call.observe(text: "ab", tokens: [7, 8]) == nil) }

        var thought = GenerationLoopGuard(
            modelType: Self.type, toolCallMarkers: Inkling2PromptContract.toolCallMarkers, thresholds: thresholds)
        var detection: GenerationLoopDetector.Detection?
        for _ in 0..<64 where detection == nil {
            detection = thought.observe(text: "again ", tokens: [11, 12, 13])
        }
        #expect(detection != nil)
    }

    /// Specials as single tokens, everything else one token per character.
    final class SpecialTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
        static let specials = [
            "<|end_message|>": 200010, "<|message_model|>": 200001, "<|content_text|>": 200004,
            "<|content_thinking|>": 200008, "<|message_user|>": 200000,
        ]
        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            var ids: [Int] = []
            var rest = Substring(text)
            outer: while !rest.isEmpty {
                for (special, id) in Self.specials where rest.hasPrefix(special) {
                    ids.append(id)
                    rest = rest.dropFirst(special.count)
                    continue outer
                }
                ids.append(1_000 + Int(rest.unicodeScalars.first!.value))
                rest = rest.dropFirst()
            }
            return ids
        }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            tokenIds.map { id in
                Self.specials.first { $0.value == id }.map(\.key)
                    ?? String(UnicodeScalar(UInt32(id - 1_000)).map(Character.init) ?? "?")
            }.joined()
        }
        func convertTokenToId(_ token: String) -> Int? { Self.specials[token] }
        func convertIdToToken(_ id: Int) -> String? { Self.specials.first { $0.value == id }?.key }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
    }

    /// The exit ends the thought message and opens an answer message, fed as
    /// control tokens; on only when the list names the family.
    @Test func exitFromAThoughtIsMarkedAndOffByDefault() throws {
        #expect(GenerationLoopExitThinkingPolicy.exitMarkers(modelType: Self.type, declaresTools: false, finalExit: true)
            == GenerationLoopExitThinkingPolicy.inklingThought)
        #expect(!GenerationLoopExitThinkingPolicy.defaultModelTypes.contains(Self.type))
        let tokenizer = SpecialTokenizer()
        let prompt = tokenizer.encode(text: "<|message_user|>Solve it.<|end_message|>", addSpecialTokens: false)
        #expect(GenerationLoopExitThinkingPolicy.resolve(
            modelType: Self.type, tokenizer: tokenizer, promptTokens: prompt, logprobs: false,
            setting: GenerationLoopExitThinkingPolicy.setting(environment: [:])) == nil)
        let exit = try #require(GenerationLoopExitThinkingPolicy.resolve(
            modelType: Self.type, tokenizer: tokenizer, promptTokens: prompt, logprobs: false,
            setting: GenerationLoopExitThinkingPolicy.setting(
                environment: [GenerationLoopExitThinkingPolicy.environmentKey: "inkling2_loop"])))
        #expect(exit.exitTokens == [200010, 200001, 200004])
        #expect(exit.exitText == "<|end_message|><|message_model|><|content_text|>")
        #expect(!exit.startsInside)
        // Logprob requests keep `length`, as for every family.
        #expect(GenerationLoopExitThinkingPolicy.resolve(
            modelType: Self.type, tokenizer: tokenizer, promptTokens: prompt, logprobs: true,
            setting: .modelTypes([Self.type])) == nil)
    }

    /// What the exit feeds reads, through the output lexer, as the end of the
    /// thought and the start of the answer.
    @Test func exitTextReadsAsAnAnswer() {
        var lexer = Inkling2OutputChannels()
        let pieces = lexer.parse("<|message_model|><|content_thinking|>loop loop "
            + GenerationLoopExitThinkingPolicy.inklingThought.close
            + GenerationLoopExitThinkingPolicy.inklingThought.after + "The answer.<|end_message|>")
            + lexer.finish()
        #expect(pieces == [.reasoning("loop loop "), .content("The answer.")])
    }
}
