// Copyright © 2026 Eigen Labs.
//
// Message preprocessing for the DeepSeek-V4 DSML encoder: merging OpenAI
// `tool` messages into `user` turns (DeepSeek-V4 has no standalone tool
// role), sorting merged tool results by their originating `tool_calls`
// order, and dropping stale `<think>` reasoning from earlier turns. Ported
// from `merge_tool_messages` / `sort_tool_results_by_call_order` /
// `_drop_thinking_messages` in `encoding_dsv4.py`.
//
// `Msg` (`[String: any Sendable]`) mirrors the loosely-typed dict shape
// `encoding_dsv4.py` operates on, and the shape every other model family's
// `ChatTemplateFixes` hook in this codebase already uses for the same
// OpenAI wire messages — see `ChatTemplateFixes.swift`.

public typealias DSV4Msg = [String: any Sendable]

enum DeepseekV4EncodingPreprocessing {
    /// Index of the last `user`/`developer` message, or -1 if none.
    static func findLastUserIndex(_ messages: [DSV4Msg]) -> Int {
        for idx in stride(from: messages.count - 1, through: 0, by: -1) {
            if let role = messages[idx]["role"] as? String, role == "user" || role == "developer" {
                return idx
            }
        }
        return -1
    }

    /// Merge OpenAI `tool` role messages into the preceding/new `user`
    /// message as `content_blocks` (`{"type": "tool_result", ...}`), and
    /// merge consecutive plain `user` messages into a single turn the same
    /// way the reference implementation does — matching the trailing-token
    /// logic in `renderMessage`, which keys off `content_blocks` rather than
    /// message count.
    static func mergeToolMessages(_ messages: [DSV4Msg]) -> [DSV4Msg] {
        var merged: [DSV4Msg] = []

        for msg in messages {
            let role = msg["role"] as? String

            if role == "tool" {
                let toolBlock: DSV4Msg = [
                    "type": "tool_result",
                    "tool_use_id": (msg["tool_call_id"] as? String) ?? "",
                    "content": msg["content"] ?? "",
                ]
                if let last = merged.last,
                    (last["role"] as? String) == "user",
                    var blocks = last["content_blocks"] as? [DSV4Msg]
                {
                    blocks.append(toolBlock)
                    merged[merged.count - 1]["content_blocks"] = blocks
                } else {
                    merged.append(["role": "user", "content_blocks": [toolBlock]])
                }
            } else if role == "user" {
                let textBlock: DSV4Msg = ["type": "text", "text": (msg["content"] as? String) ?? ""]
                if let last = merged.last,
                    (last["role"] as? String) == "user",
                    var blocks = last["content_blocks"] as? [DSV4Msg],
                    last["task"] == nil
                {
                    blocks.append(textBlock)
                    merged[merged.count - 1]["content_blocks"] = blocks
                } else {
                    var newMsg: DSV4Msg = [
                        "role": "user",
                        "content": (msg["content"] as? String) ?? "",
                        "content_blocks": [textBlock],
                    ]
                    for key in ["task", "wo_eos", "mask"] {
                        if let value = msg[key] { newMsg[key] = value }
                    }
                    merged.append(newMsg)
                }
            } else {
                merged.append(msg)
            }
        }

        return merged
    }

    /// Sort merged `tool_result` content blocks within each `user` turn by
    /// the order the corresponding `tool_calls` appeared in the preceding
    /// assistant message (matched by `tool_call_id`, a.k.a. DSML-decoded
    /// `id`). Blocks whose id has no match keep priority 0 (front), matching
    /// the reference's `.get(..., 0)` default.
    static func sortToolResultsByCallOrder(_ messages: [DSV4Msg]) -> [DSV4Msg] {
        var result = messages
        var lastToolCallOrder: [String: Int] = [:]

        for i in result.indices {
            let role = result[i]["role"] as? String

            if role == "assistant",
                let toolCalls = result[i]["tool_calls"] as? [DSV4Msg],
                !toolCalls.isEmpty
            {
                lastToolCallOrder = [:]
                for (idx, tc) in toolCalls.enumerated() {
                    let tcId = (tc["id"] as? String)
                        ?? ((tc["function"] as? DSV4Msg)?["id"] as? String)
                        ?? ""
                    if !tcId.isEmpty { lastToolCallOrder[tcId] = idx }
                }
            } else if role == "user", let blocks = result[i]["content_blocks"] as? [DSV4Msg] {
                let toolBlocks = blocks.enumerated().filter { ($0.element["type"] as? String) == "tool_result" }
                if toolBlocks.count > 1, !lastToolCallOrder.isEmpty {
                    let sortedBlocks = toolBlocks.sorted { lhs, rhs in
                        let lhsOrder = lastToolCallOrder[(lhs.element["tool_use_id"] as? String) ?? ""] ?? 0
                        let rhsOrder = lastToolCallOrder[(rhs.element["tool_use_id"] as? String) ?? ""] ?? 0
                        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                        return lhs.offset < rhs.offset
                    }.map(\.element)

                    var sortedIdx = 0
                    var newBlocks: [DSV4Msg] = []
                    for block in blocks {
                        if (block["type"] as? String) == "tool_result" {
                            newBlocks.append(sortedBlocks[sortedIdx])
                            sortedIdx += 1
                        } else {
                            newBlocks.append(block)
                        }
                    }
                    result[i]["content_blocks"] = newBlocks
                }
            }
        }

        return result
    }

    /// Drop `reasoning_content` from assistant turns before the last
    /// user message (keeps everything at/after it, plus all
    /// user/system/tool/latest_reminder turns unconditionally). Developer
    /// messages before the last user turn are dropped entirely, matching
    /// the reference (they're single-shot search-agent context that's
    /// meaningless to replay once superseded).
    static func dropThinkingMessages(_ messages: [DSV4Msg]) -> [DSV4Msg] {
        let lastUserIdx = findLastUserIndex(messages)
        let keepRoles: Set<String> = ["user", "system", "tool", "latest_reminder", "direct_search_results"]
        var result: [DSV4Msg] = []

        for (idx, msg) in messages.enumerated() {
            let role = msg["role"] as? String
            if (role.map(keepRoles.contains) ?? false) || idx >= lastUserIdx {
                result.append(msg)
            } else if role == "assistant" {
                var copy = msg
                copy.removeValue(forKey: "reasoning_content")
                result.append(copy)
            }
            // developer (and any other role) before lastUserIdx: dropped.
        }

        return result
    }

    /// `tools_from_openai_format`: extract each tool's `function` object.
    static func toolsFromOpenAIFormat(_ tools: [DSV4Msg]) -> [DSV4Msg] {
        tools.compactMap { $0["function"] as? DSV4Msg }
    }

    /// `tool_calls_from_openai_format`: `{"name": ..., "arguments": ...}`.
    /// `arguments` is kept in whatever shape it arrives (decoded object or
    /// raw string) — `encodeArgumentsToDsml` handles both.
    static func toolCallsFromOpenAIFormat(_ toolCalls: [DSV4Msg]) -> [DSV4Msg] {
        toolCalls.compactMap { tc -> DSV4Msg? in
            guard let function = tc["function"] as? DSV4Msg,
                let name = function["name"] as? String
            else { return nil }
            var result: DSV4Msg = ["name": name]
            if let arguments = function["arguments"] {
                result["arguments"] = arguments
            }
            return result
        }
    }
}
