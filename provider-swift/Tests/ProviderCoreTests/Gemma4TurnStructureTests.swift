import Foundation
import Testing

@testable import ProviderCore

/// E2 turn-structure normalization for the served Gemma template
/// (`Gemma4TemplateFix.normalizeMessages` → `Gemma4TurnStructure`): the
/// template's forward scan only reads the CONTIGUOUS `role:"tool"` run after
/// an assistant tool_calls message (non-contiguous results render under the
/// wrong turn / leave a dangling `<|tool_response>` opener), and a text-only
/// assistant message followed by another assistant message closes its turn
/// while the follow-up renders without an opener.
@Suite("Gemma4 turn structure (E2)")
struct Gemma4TurnStructureTests {

    private let gemmaContext = ChatTemplateFixContext(
        modelId: "gemma-4-26b-a4b-it-qat-4bit", modelType: "gemma4_text")

    private func assistant(
        text: String = "",
        callIDs: [String] = [],
        reasoning: String? = nil
    ) -> [String: any Sendable] {
        var message: [String: any Sendable] = ["role": "assistant", "content": text]
        if !callIDs.isEmpty {
            message["tool_calls"] = callIDs.map { id -> [String: any Sendable] in
                [
                    "id": id, "type": "function",
                    "function": ["name": "fn_\(id)", "arguments": [String: any Sendable]()]
                        as [String: any Sendable],
                ]
            } as [any Sendable]
        }
        if let reasoning {
            message["reasoning_content"] = reasoning
        }
        return message
    }

    private func toolResult(id: String?, text: String = "ok") -> [String: any Sendable] {
        var message: [String: any Sendable] = ["role": "tool", "content": text]
        if let id { message["tool_call_id"] = id }
        return message
    }

    private func roleAndIDs(_ messages: [[String: any Sendable]]) -> [String] {
        messages.map { message in
            let role = (message["role"] as? String) ?? "?"
            if role == "tool" {
                return "tool(\((message["tool_call_id"] as? String) ?? "-"))"
            }
            if let calls = message["tool_calls"] as? [any Sendable], !calls.isEmpty {
                let ids = calls.compactMap { ($0 as? [String: any Sendable])?["id"] as? String }
                return "\(role)[\(ids.joined(separator: ","))]"
            }
            return role
        }
    }

    // MARK: - Re-pairing

    /// Two back-to-back tool_call turns whose results arrive as one trailing
    /// run: the template's forward scan from the FIRST turn hits the second
    /// assistant and stops (dangling `<|tool_response>` opener). Results must
    /// be re-emitted contiguously after their owning turns.
    @Test func repairsResultsAcrossConsecutiveToolCallTurns() throws {
        let input = [
            assistant(callIDs: ["id1"]),
            assistant(callIDs: ["id2"]),
            toolResult(id: "id1", text: "r1"),
            toolResult(id: "id2", text: "r2"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(
            roleAndIDs(out) == [
                "assistant[id1]", "tool(id1)", "assistant[id2]", "tool(id2)",
            ])
    }

    /// Results inside one contiguous run are re-ordered to the tool_calls
    /// order (the template renders the run positionally).
    @Test func ordersResultsByToolCallsOrder() throws {
        let input = [
            assistant(callIDs: ["id1", "id2"]),
            toolResult(id: "id2", text: "r2"),
            toolResult(id: "id1", text: "r1"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(roleAndIDs(out) == ["assistant[id1,id2]", "tool(id1)", "tool(id2)"])
    }

    /// Multiple results for the same call id keep arrival order.
    @Test func keepsArrivalOrderForRepeatedResultIDs() throws {
        let input = [
            assistant(callIDs: ["id1"]),
            toolResult(id: "id1", text: "first"),
            toolResult(id: "id1", text: "second"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect((out[1]["content"] as? String) == "first")
        #expect((out[2]["content"] as? String) == "second")
    }

    /// A re-used call id (retry loops re-issue the same id every round) pairs
    /// with the MOST RECENT declaring turn.
    @Test func reusedCallIDPairsWithMostRecentTurn() throws {
        let input = [
            assistant(callIDs: ["id1"]),
            toolResult(id: "id1", text: "round1"),
            assistant(callIDs: ["id1"]),
            toolResult(id: "id1", text: "round2"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(roleAndIDs(out) == ["assistant[id1]", "tool(id1)", "assistant[id1]", "tool(id1)"])
        #expect((out[1]["content"] as? String) == "round1")
        #expect((out[3]["content"] as? String) == "round2")
    }

    /// Results without a tool_call_id stay attached, in arrival order, after
    /// the paired block of the run's tool-call turn (the template renders them
    /// via its name fallback — they must not be dropped or rejected).
    @Test func idlessResultsStayAttachedAfterPairedBlock() throws {
        let input = [
            assistant(callIDs: ["id1"]),
            toolResult(id: nil, text: "legacy"),
            toolResult(id: "id1", text: "r1"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(roleAndIDs(out) == ["assistant[id1]", "tool(id1)", "tool(-)"])
        #expect((out[2]["content"] as? String) == "legacy")
    }

    // MARK: - Orphans

    /// A result whose id matches NO preceding assistant tool_call is a clean
    /// 400 (invalidToolPayload), mirroring the Harmony splitter's orphan rule.
    @Test func orphanResultThrowsInvalidToolPayload() {
        let input = [
            assistant(callIDs: ["id1"]),
            toolResult(id: "id1"),
            toolResult(id: "ghost"),
        ]
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try Gemma4TemplateFix.normalizeMessages(input)
        }
        do {
            _ = try Gemma4TemplateFix.normalizeMessages(input)
            Issue.record("expected invalidToolPayload")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .invalidToolPayload(let message) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(message.contains("ghost"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// A result answering a call that is only declared LATER is an orphan too
    /// (results cannot precede their call).
    @Test func resultForFutureCallThrows() {
        let input = [
            assistant(callIDs: ["id1"]),
            toolResult(id: "id2"),
            assistant(callIDs: ["id2"]),
        ]
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try Gemma4TemplateFix.normalizeMessages(input)
        }
    }

    // MARK: - Assistant text merge

    /// A text-only assistant message immediately followed by another assistant
    /// message folds into it (`\n\n`-joined prefix) so the pair renders one
    /// closed model turn.
    @Test func mergesConsecutiveAssistantText() throws {
        let input: [[String: any Sendable]] = [
            ["role": "user", "content": "hi"],
            assistant(text: "part one"),
            assistant(text: "part two"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 2)
        #expect((out[1]["content"] as? String) == "part one\n\npart two")
    }

    /// A chain of text-only turns folds into the FINAL assistant message —
    /// including one that carries tool_calls.
    @Test func mergesChainIntoToolCallTurn() throws {
        let input = [
            assistant(text: "a"),
            assistant(text: "b"),
            assistant(text: "c", callIDs: ["id1"]),
            toolResult(id: "id1"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 2)
        #expect((out[0]["content"] as? String) == "a\n\nb\n\nc")
        #expect(roleAndIDs(out) == ["assistant[id1]", "tool(id1)"])
    }

    /// An EMPTY text-only assistant message contributes no prefix (no stray
    /// newlines) and disappears.
    @Test func emptyAssistantTextFoldsAway() throws {
        let input: [[String: any Sendable]] = [
            assistant(text: "  "),
            assistant(text: "answer"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 1)
        #expect((out[0]["content"] as? String) == "answer")
    }

    /// The earlier turn's reasoning is carried when the later turn has none.
    @Test func mergeCarriesReasoningWhenLaterHasNone() throws {
        let input: [[String: any Sendable]] = [
            assistant(text: "thought out loud", reasoning: "chain"),
            assistant(text: "final"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 1)
        #expect((out[0]["reasoning_content"] as? String) == "chain")
        #expect((out[0]["content"] as? String) == "thought out loud\n\nfinal")
    }

    /// A tool_calls turn followed by an assistant text turn is the template's
    /// own well-formed continuation (open turn → content → close): NOT merged.
    @Test func toolCallTurnThenTextIsNotMerged() throws {
        let input = [
            assistant(callIDs: ["id1"]),
            toolResult(id: "id1"),
            assistant(text: "the answer"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 3)
        #expect(roleAndIDs(out) == ["assistant[id1]", "tool(id1)", "assistant"])
    }

    /// Assistant messages with content-parts arrays are left alone (the merge
    /// cannot represent non-text parts as a string prefix).
    @Test func contentPartsAssistantIsNotMergedAway() throws {
        let parts: [[String: any Sendable]] = [["type": "text", "text": "see image"]]
        let input: [[String: any Sendable]] = [
            ["role": "assistant", "content": parts as [any Sendable]],
            assistant(text: "follow-up"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 2)
    }

    // MARK: - Wiring

    /// The production chokepoint (`ChatTemplateFixes.normalizeMessages`) runs
    /// the gemma repair for gemma4 contexts…
    @Test func chatTemplateFixesRoutesGemmaContexts() throws {
        let input = [
            assistant(callIDs: ["id1"]),
            assistant(callIDs: ["id2"]),
            toolResult(id: "id1"),
            toolResult(id: "id2"),
        ]
        let out = try ChatTemplateFixes.normalizeMessages(input, context: gemmaContext)
        #expect(roleAndIDs(out) == ["assistant[id1]", "tool(id1)", "assistant[id2]", "tool(id2)"])
    }

    @Test func gemmaModelIDFallbackAppliesWhenTypeIsUnavailable() throws {
        let input = [
            assistant(text: "prefix"),
            assistant(text: "answer"),
        ]
        let out = try ChatTemplateFixes.normalizeMessages(
            input,
            context: ChatTemplateFixContext(
                modelId: "gemma-4-26b-qat-4bit",
                modelType: nil))
        #expect(out.count == 1)
        #expect((out[0]["content"] as? String) == "prefix\n\nanswer")
    }

    /// …and non-gemma contexts are untouched by it (`applies(to:)` gates).
    @Test func nonGemmaContextsAreUntouched() throws {
        let input = [
            assistant(text: "a"),
            assistant(text: "b"),
        ]
        let out = try ChatTemplateFixes.normalizeMessages(
            input, context: ChatTemplateFixContext(modelId: "qwen3-8b", modelType: "qwen3"))
        #expect(out.count == 2)
    }

    /// Plain histories (no tools, no consecutive assistants) pass through
    /// value-identical.
    @Test func plainHistoriesPassThrough() throws {
        let input: [[String: any Sendable]] = [
            ["role": "system", "content": "s"],
            ["role": "user", "content": "u"],
            assistant(text: "a"),
            ["role": "user", "content": "u2"],
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 4)
        #expect(roleAndIDs(out) == ["system", "user", "assistant", "user"])
        #expect((out[2]["content"] as? String) == "a")
    }

    /// Post-push Codex P2: when BOTH merged assistant turns carry reasoning,
    /// the earlier turn's reasoning must be concatenated ahead of the later
    /// one (same "\n\n" join as content) — never silently dropped.
    @Test func mergeConcatenatesBothTurnsReasoning() throws {
        let input: [[String: any Sendable]] = [
            ["role": "user", "content": "hi"],
            assistant(text: "part one", reasoning: "earlier thoughts"),
            assistant(text: "part two", reasoning: "later thoughts"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 2)
        #expect((out[1]["content"] as? String) == "part one\n\npart two")
        #expect((out[1]["reasoning_content"] as? String) == "earlier thoughts\n\nlater thoughts")
    }

    /// Carry (not concatenate) when only the earlier turn has reasoning.
    @Test func mergeCarriesEarlierReasoningWhenLaterHasNone() throws {
        let input: [[String: any Sendable]] = [
            ["role": "user", "content": "hi"],
            assistant(text: "part one", reasoning: "earlier thoughts"),
            assistant(text: "part two"),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect((out[1]["reasoning_content"] as? String) == "earlier thoughts")
    }

    /// PR #548 round 3 (Codex P2): an unanswered assistant tool_call turn
    /// MID-HISTORY leaves the served template's forward scan answerless (the
    /// dangling tool_response shape) — fail closed as a clean 400.
    @Test func unansweredMidHistoryCallThrows() {
        let input: [[String: any Sendable]] = [
            ["role": "user", "content": "hi"],
            assistant(text: "", callIDs: ["a"]),
            ["role": "user", "content": "and then?"],
        ]
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try Gemma4TemplateFix.normalizeMessages(input)
        }
    }

    /// A partially answered turn (one of two calls resolved) followed by more
    /// history is equally broken.
    @Test func partiallyAnsweredMidHistoryCallThrows() {
        let input: [[String: any Sendable]] = [
            assistant(text: "", callIDs: ["a", "b"]),
            toolResult(id: "a"),
            ["role": "user", "content": "next"],
        ]
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try Gemma4TemplateFix.normalizeMessages(input)
        }
    }

    /// TRAILING exemption: a history that ENDS on an unanswered tool_call turn
    /// is the legitimate continuation shape and passes through unchanged.
    @Test func trailingUnansweredCallPasses() throws {
        let input: [[String: any Sendable]] = [
            ["role": "user", "content": "hi"],
            assistant(text: "", callIDs: ["a"]),
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 2)
    }

    /// An id-less result covers an otherwise-unanswered call (legacy pairing
    /// the template renders via its name fallback).
    @Test func idlessResultCoversUnansweredCallMidHistory() throws {
        let input: [[String: any Sendable]] = [
            assistant(text: "", callIDs: ["a"]),
            toolResult(id: nil),
            ["role": "user", "content": "next"],
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 3)
    }
}
