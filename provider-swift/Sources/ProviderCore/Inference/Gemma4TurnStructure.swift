// Copyright © 2026 Eigen Labs.
//
// Gemma4 turn-structure normalization (E2, 2026-07-15 platform errors deep
// dive). The served Gemma template (sha 94899c0f…) has two history-shape
// landmines that Google's 2026-07-09 canonical template fixes upstream; the
// artifact is NOT repinned, so the equivalent repairs ship here in code:
//
//   1. After an assistant `tool_calls` message the template FORWARD-SCANS
//      only the CONTIGUOUS run of `role:"tool"` messages that immediately
//      follow it. Results that are not contiguous (e.g. answered under a
//      later assistant's run, or ordered across two back-to-back tool_call
//      turns) are rendered under the wrong turn — and when the scan finds
//      nothing at all the turn emits a dangling `<|tool_response>` opener
//      (`ns_tr_out.flag` unset) instead of a closed turn. Repair: re-emit
//      each assistant's answering tool results as one contiguous block
//      immediately after it, ordered by its tool_calls order.
//
//   2. Consecutive assistant messages render as one "continued" model turn
//      (`continue_same_model_turn` suppresses the second `<|turn>model`
//      opener) — but a TEXT-only assistant message has already CLOSED the
//      turn (`<turn|>`), so the follow-up text floats outside any opener.
//      Repair: merge a text-only assistant message into an immediately
//      following assistant message (its content becomes a `\n\n`-joined
//      prefix), so consecutive assistant turns render one closed turn.
//
// A `role:"tool"` message whose `tool_call_id` answers NO preceding assistant
// tool_call cannot be placed anywhere — that is a malformed history and
// throws `invalidToolPayload` (clean 400), mirroring the Harmony splitter's
// orphan rule (`GPTOSSHarmonyTemplateFixes.splitParallelToolCalls`).
//
// Runs AFTER `ChatTemplateFixes.validateGenericToolHistory`, which guarantees
// every tool message sits in a run headed by an assistant `tool_calls`
// message — so "nearest preceding tool-call turn" always exists here.

import Foundation

enum Gemma4TurnStructure {

    static func normalizeMessages(
        _ messages: [[String: any Sendable]]
    ) throws -> [[String: any Sendable]] {
        let repaired = try repairToolResultPlacement(messages)
        return mergeDanglingAssistantText(repaired)
    }

    // MARK: - Tool-result re-pairing

    private static func toolCalls(of message: [String: any Sendable]) -> [[String: any Sendable]] {
        guard (message["role"] as? String) == "assistant",
            let calls = message["tool_calls"] as? [any Sendable], !calls.isEmpty
        else { return [] }
        return calls.compactMap { $0 as? [String: any Sendable] }
    }

    private static func callID(_ call: [String: any Sendable]) -> String? {
        guard let id = call["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Re-emit every `role:"tool"` result as part of one contiguous block
    /// immediately after its OWNING assistant `tool_calls` message, ordered by
    /// that message's tool_calls order. A result's owner is the most recent
    /// preceding assistant that declared its `tool_call_id` (repeat-id clients
    /// re-issue the same id each round; most-recent is the only sane pairing).
    /// Results carrying no `tool_call_id` stay attached, in arrival order,
    /// after the id-paired block of the nearest preceding tool-call turn (they
    /// render today via the template's name fallback; dropping or rejecting
    /// them would regress working histories). An id that matches NO preceding
    /// declaration is an orphan → 400.
    private static func repairToolResultPlacement(
        _ messages: [[String: any Sendable]]
    ) throws -> [[String: any Sendable]] {
        // Owner index (into `messages`) for every declared call id, updated in
        // scan order so a re-declared id re-binds to the most recent turn.
        var ownerByCallID: [String: Int] = [:]
        var lastToolCallTurn: Int? = nil
        // Per-owner collected results: call id → results (arrival order), plus
        // the id-less tail.
        var pairedResults: [Int: [String: [[String: any Sendable]]]] = [:]
        var idlessResults: [Int: [[String: any Sendable]]] = [:]

        for (index, message) in messages.enumerated() {
            let role = message["role"] as? String
            if role == "tool" {
                if let id = message["tool_call_id"] as? String, !id.isEmpty {
                    guard let owner = ownerByCallID[id] else {
                        throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                            "tool result for tool_call_id \(id) has no matching assistant tool_call"
                        )
                    }
                    pairedResults[owner, default: [:]][id, default: []].append(message)
                } else {
                    guard let owner = lastToolCallTurn else {
                        // validateGenericToolHistory already rejects this; keep
                        // the same clean 400 if reached through another path.
                        throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                            "tool message has no preceding assistant tool_calls")
                    }
                    idlessResults[owner, default: []].append(message)
                }
                continue
            }
            let calls = toolCalls(of: message)
            if !calls.isEmpty {
                lastToolCallTurn = index
                for call in calls {
                    if let id = callID(call) {
                        ownerByCallID[id] = index
                    }
                }
            }
        }

        var out: [[String: any Sendable]] = []
        out.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            if (message["role"] as? String) == "tool" {
                continue  // re-emitted below, next to its owner
            }
            out.append(message)
            let calls = toolCalls(of: message)
            guard !calls.isEmpty else { continue }
            var byID = pairedResults[index] ?? [:]
            // The template's forward scan reads results in listed order; the
            // tool_calls order is the canonical one.
            for call in calls {
                guard let id = callID(call), let results = byID.removeValue(forKey: id)
                else { continue }
                out.append(contentsOf: results)
            }
            // Results whose id was declared by this turn but is not in its
            // tool_calls order slot anymore (defensive; unreachable today).
            for id in byID.keys.sorted() {
                out.append(contentsOf: byID[id] ?? [])
            }
            out.append(contentsOf: idlessResults[index] ?? [])
        }
        return out
    }

    // MARK: - Consecutive assistant text merge

    private static func isTextOnlyAssistant(_ message: [String: any Sendable]) -> Bool {
        guard (message["role"] as? String) == "assistant" else { return false }
        if let calls = message["tool_calls"] as? [any Sendable], !calls.isEmpty {
            return false
        }
        if let responses = message["tool_responses"] as? [any Sendable], !responses.isEmpty {
            return false
        }
        // Content-parts arrays are left alone: they carry non-text items the
        // merge cannot represent as a string prefix.
        return message["content"] is String || message["content"] == nil
    }

    /// Fold a text-only assistant message into an immediately FOLLOWING
    /// assistant message so the pair renders as one closed model turn (the
    /// template suppresses the second turn opener but the first message has
    /// already emitted a turn CLOSE — the follow-up otherwise floats outside
    /// any opener). Left-to-right, so a chain of assistant texts folds into
    /// the final one.
    private static func mergeDanglingAssistantText(
        _ messages: [[String: any Sendable]]
    ) -> [[String: any Sendable]] {
        var working = messages
        var out: [[String: any Sendable]] = []
        out.reserveCapacity(working.count)
        var i = 0
        while i < working.count {
            let message = working[i]
            if i + 1 < working.count, isTextOnlyAssistant(message),
                (working[i + 1]["role"] as? String) == "assistant" {
                working[i + 1] = merged(message, into: working[i + 1])
                i += 1
                continue
            }
            out.append(message)
            i += 1
        }
        return out
    }

    private static func merged(
        _ earlier: [String: any Sendable],
        into later: [String: any Sendable]
    ) -> [String: any Sendable] {
        var output = later
        let prefix = (earlier["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prefix.isEmpty {
            if let existing = output["content"] as? String {
                output["content"] = existing.isEmpty ? prefix : prefix + "\n\n" + existing
            } else if var parts = output["content"] as? [any Sendable] {
                parts.insert(["type": "text", "text": prefix] as [String: any Sendable], at: 0)
                output["content"] = parts
            } else {
                output["content"] = prefix
            }
        }
        // Never lose the earlier turn's reasoning: carry it when the later
        // turn has none, and concatenate (earlier first, the same "\n\n" join
        // the content path uses) when both turns carry the same key. The
        // served template only renders reasoning on tool_call-bearing turns,
        // so this is render-neutral today — but the repair contract is that
        // normalization never drops history data.
        for key in ["thinking", "reasoning", "reasoning_content"] {
            guard let carried = earlier[key] as? String,
                !carried.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            if let existing = output[key] as? String, !existing.isEmpty {
                output[key] = carried + "\n\n" + existing
            } else {
                output[key] = carried
            }
        }
        return output
    }
}
