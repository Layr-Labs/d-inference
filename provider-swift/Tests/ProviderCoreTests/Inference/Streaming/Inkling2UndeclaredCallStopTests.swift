import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Client stop strings once a call frame is answer text (#200): they apply to
/// that text as to any answer, never to the thought, and the text the stop
/// leaves is what the client receives. The model's own scope
/// (`answerStopScope`) opens only at `<|content_text|>`, so it would skip the
/// frame: the control below.
@Suite("Inkling 2 stops in call text without declared tools")
struct Inkling2UndeclaredCallStopTests {
    typealias Serve = Inkling2UndeclaredCallTextTests

    static let thought = "<|message_model|><|content_thinking|>Plan: call it with Paris STOP now.<|end_message|>"
    static let frame = #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":{"city":"Paris STOP here"}}<|end_message|>"#

    /// The engine's stop holdback over generated text (`StopHoldback`, the
    /// CBv2 detokenizer's matcher), fed in chunks.
    static func released(_ text: String, stops: [String], scope: CBv2StopStringScope?, width: Int)
        -> (text: String, stopped: Bool)
    {
        let holdback = StopHoldback(stopStrings: stops, scope: scope)
        var out = ""
        let characters = Array(text)
        for start in stride(from: 0, to: characters.count, by: width) {
            let scan = holdback.ingest(String(characters[start..<min(start + width, characters.count)]))
            out += scan.text
            if scan.stopped { return (out, true) }
        }
        return (out + holdback.flush(), false)
    }

    static func prepared(tools: [OpenAITool]? = nil, choice: OpenAIToolChoice? = nil) throws
        -> ToolChoicePromptPolicy.Prepared
    {
        try ToolChoicePromptPolicy.prepare(Serve.request(clientStreams: true, choice: choice, tools: tools),
            modelType: Serve.type)
    }

    @Test func scopeOnlyForAutoWithoutTools() throws {
        #expect(Inkling2PromptContract.stopStringScope(modelType: Serve.type, prepared: try Self.prepared())
            == Inkling2PromptContract.undeclaredCallTextStopScope)
        #expect(Inkling2PromptContract.stopStringScope(modelType: Serve.type,
            prepared: try Self.prepared(tools: Serve.declared())) == nil)
        #expect(Inkling2PromptContract.stopStringScope(modelType: Serve.type,
            prepared: try Self.prepared(choice: .mode(.none))) == nil)
        #expect(Inkling2PromptContract.stopStringScope(modelType: Serve.type, prepared: try Self.prepared(),
            enabled: false) == nil)
        #expect(Inkling2PromptContract.stopStringScope(modelType: "qwen3_5", prepared: try Self.prepared()) == nil)
    }

    /// A stop inside the frame's text ends the answer there; the same stop in
    /// the thought does not. The client gets the text before the stop.
    @Test func stopInCallTextEndsTheAnswer() throws {
        for width in [1, 3, 4096] {
            let scan = Self.released(Self.thought + Self.frame + Serve.eos, stops: ["STOP"],
                scope: Inkling2PromptContract.undeclaredCallTextStopScope, width: width)
            #expect(scan.stopped, "width \(width)")
            let outcome = try Serve.serve(scan.text, request: Serve.request(clientStreams: true), width: width)
            #expect(outcome.refusal == nil, "\(outcome.refusal ?? "")")
            #expect(outcome.content == #"{"name":"get_weather","args":{"city":"Paris "#, "width \(width)")
            #expect(outcome.reasoning == "Plan: call it with Paris STOP now.")
            #expect(outcome.calls.isEmpty)
        }
    }

    /// Control: the model's scope (D2 `19b0784d69` for every request) never
    /// matches inside the frame, so the stop string would reach the client.
    @Test func modelScopeSkipsCallText() {
        let scan = Self.released(Self.thought + Self.frame + Serve.eos, stops: ["STOP"],
            scope: Inkling2PromptContract.answerStopScope, width: 4096)
        #expect(!scan.stopped)
    }

    /// Ordinary answer text stops under both scopes; a thought never does.
    @Test func answerAndThoughtAreUnchanged() {
        let answer = Self.thought + "<|message_model|><|content_text|>It is sunny STOP here.<|end_message|>"
        for scope in [Inkling2PromptContract.answerStopScope, Inkling2PromptContract.undeclaredCallTextStopScope] {
            let scan = Self.released(answer, stops: ["STOP"], scope: scope, width: 2)
            #expect(scan.stopped)
            #expect(scan.text.hasSuffix("It is sunny "))
            #expect(!Self.released(Self.thought + Serve.eos, stops: ["STOP"], scope: scope, width: 2).stopped)
        }
    }

    /// Text as the engine streams it: each `<|…|>` control token whole (a
    /// special token), other text one character at a time.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let first = rest.first {
            if rest.hasPrefix("<|"), let close = rest.range(of: "|>") {
                out.append(String(rest[..<close.upperBound]))
                rest = rest[close.upperBound...]
            } else {
                out.append(String(first))
                rest = rest.dropFirst()
            }
        }
        return out
    }

    /// A client stop that is part of a control token never matches inside it:
    /// the plain answer reaches the client whole.
    @Test(arguments: ["end", "model", "text", "message", "<|", "|>"])
    func stopsInsideControlTokensNeverMatch(stop: String) throws {
        let answer = Self.thought + "<|message_model|><|content_text|>It is sunny here.<|end_message|>" + Serve.eos
        let holdback = StopHoldback(stopStrings: [stop], scope: Inkling2PromptContract.undeclaredCallTextStopScope)
        var out = ""
        for token in Self.tokens(answer) {
            let scan = holdback.ingest(token)
            out += scan.text
            #expect(!scan.stopped, "\(stop) matched at \(token)")
            if scan.stopped { return }
        }
        out += holdback.flush()
        #expect(out == answer)
        let outcome = try Serve.serve(out, request: Serve.request(clientStreams: true), width: 4096)
        #expect(outcome.refusal == nil, "\(outcome.refusal ?? "")")
        #expect(outcome.content == "It is sunny here.")
        #expect(outcome.reasoning == "Plan: call it with Paris STOP now.")
    }

    /// The engine's reported stop agrees with the holdback for this scope.
    @Test func reportedStopAgrees() {
        #expect(EngineV2Bridge.matchedStopSequence(candidates: ["STOP"], generatedText: Self.thought + Self.frame,
            scope: Inkling2PromptContract.undeclaredCallTextStopScope) == "STOP")
        #expect(EngineV2Bridge.matchedStopSequence(candidates: ["STOP"], generatedText: Self.thought + Self.frame,
            scope: Inkling2PromptContract.answerStopScope) == nil)
    }
}
