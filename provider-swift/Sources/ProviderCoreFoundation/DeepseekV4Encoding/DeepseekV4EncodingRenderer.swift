// Copyright © 2026 Eigen Labs.
//
// Core message-to-string rendering for the DeepSeek-V4 DSML encoder. A
// close, function-for-function port of `render_message` / `render_tools` /
// `encode_arguments_to_dsml` in `encoding_dsv4.py` — see that file (and the
// DeepSeek-V4 encoding README) for the prose spec this mirrors.

enum DeepseekV4EncodingRenderer {
    /// Render the message at `index` into its encoded string form, matching
    /// `render_message(index, messages, thinking_mode, drop_thinking,
    /// reasoning_effort)`. `messages` must already be preprocessed
    /// (`mergeToolMessages` + `sortToolResultsByCallOrder`, and optionally
    /// `dropThinkingMessages`).
    static func renderMessage(
        index: Int,
        messages: [DSV4Msg],
        thinkingMode: String,
        dropThinking: Bool,
        reasoningEffort: String?
    ) throws -> String {
        var prompt = ""
        let msg = messages[index]
        let lastUserIdx = DeepseekV4EncodingPreprocessing.findLastUserIndex(messages)

        let role = msg["role"] as? String
        let content = msg["content"] as? String
        let tools = (msg["tools"] as? [DSV4Msg]).map(DeepseekV4EncodingPreprocessing.toolsFromOpenAIFormat)
        let toolCalls = (msg["tool_calls"] as? [DSV4Msg]).map(
            DeepseekV4EncodingPreprocessing.toolCallsFromOpenAIFormat)
        let reasoningContent = msg["reasoning_content"] as? String
        let woEos = (msg["wo_eos"] as? Bool) ?? false

        if index == 0, thinkingMode == "thinking", reasoningEffort == "max" {
            prompt += DeepseekV4Tokens.reasoningEffortMaxPrefix
        }

        switch role {
        case "system":
            prompt += content ?? ""
            if let tools, !tools.isEmpty {
                prompt += "\n\n" + renderTools(tools)
            }

        case "developer":
            guard let content, !content.isEmpty else {
                throw DeepseekV4EncodingError.invalidMessage(
                    "developer message at index \(index) is missing non-empty content")
            }
            var developerContent = DeepseekV4Tokens.userPrefix + content
            if let tools, !tools.isEmpty {
                developerContent += "\n\n" + renderTools(tools)
            }
            prompt += developerContent

        case "user":
            prompt += DeepseekV4Tokens.userPrefix
            if let blocks = msg["content_blocks"] as? [DSV4Msg], !blocks.isEmpty {
                let parts = blocks.map { block -> String in
                    switch block["type"] as? String {
                    case "text":
                        return (block["text"] as? String) ?? ""
                    case "tool_result":
                        return DeepseekV4Tokens.toolResult((block["content"] as? String) ?? "")
                    case let other:
                        return "[Unsupported \(other ?? "nil")]"
                    }
                }
                prompt += parts.joined(separator: "\n\n")
            } else {
                prompt += content ?? ""
            }

        case "latest_reminder":
            prompt += DeepseekV4Tokens.latestReminderPrefix + (content ?? "")

        case "tool":
            throw DeepseekV4EncodingError.unmergedToolMessage(index: index)

        case "assistant":
            var thinkingPart = ""
            var toolCallsContent = ""

            if let toolCalls, !toolCalls.isEmpty {
                let invokes = toolCalls.map { tc -> String in
                    let name = (tc["name"] as? String) ?? ""
                    let parametersBlock = encodeArgumentsToDsml(tc["arguments"])
                    return DeepseekV4Tokens.toolCallInvoke(name: name, parametersBlock: parametersBlock)
                }
                toolCallsContent += "\n\n" + DeepseekV4Tokens.toolCallsBlock(invokes: invokes.joined(separator: "\n"))
            }

            let summaryContent = content ?? ""
            let reasoning = reasoningContent ?? ""
            let prevHasTask = index - 1 >= 0 && messages[index - 1]["task"] != nil

            if thinkingMode == "thinking" && !prevHasTask {
                if !dropThinking || index > lastUserIdx {
                    thinkingPart = reasoning + DeepseekV4Tokens.thinkingEnd
                }
            }

            prompt += thinkingPart + summaryContent + toolCallsContent
            if !woEos {
                prompt += DeepseekV4Tokens.eos
            }

        default:
            throw DeepseekV4EncodingError.unsupportedRole(role ?? "<missing>", index: index)
        }

        // Transition tokens: only appended when this is the last message, or
        // the next message is an assistant/latest_reminder turn (i.e. this
        // message's trailing content directly precedes generation, another
        // reply, or a reminder — never a plain user/tool/system turn, which
        // renders its own leading tokens instead).
        if index + 1 < messages.count {
            let nextRole = messages[index + 1]["role"] as? String
            if nextRole != "assistant" && nextRole != "latest_reminder" {
                return prompt
            }
        }

        if let task = msg["task"] as? String {
            guard let taskToken = DeepseekV4Tokens.taskTokens[task] else {
                throw DeepseekV4EncodingError.invalidTask(task)
            }
            if task != "action" {
                prompt += taskToken
            } else {
                prompt += DeepseekV4Tokens.assistantPrefix
                prompt += thinkingMode == "thinking" ? DeepseekV4Tokens.thinkingStart : DeepseekV4Tokens.thinkingEnd
                prompt += taskToken
            }
        } else if role == "user" || role == "developer" {
            prompt += DeepseekV4Tokens.assistantPrefix
            if !dropThinking && thinkingMode == "thinking" {
                prompt += DeepseekV4Tokens.thinkingStart
            } else if dropThinking && thinkingMode == "thinking" && index >= lastUserIdx {
                prompt += DeepseekV4Tokens.thinkingStart
            } else {
                prompt += DeepseekV4Tokens.thinkingEnd
            }
        }

        return prompt
    }

    /// `render_tools`: build the `## Tools` system-prompt block from each
    /// tool's already-extracted `function` object (see
    /// `toolsFromOpenAIFormat`).
    static func renderTools(_ tools: [DSV4Msg]) -> String {
        let toolSchemas = tools.map { DeepseekV4JSON.toJSON($0) }.joined(separator: "\n")
        return DeepseekV4Tokens.toolsBlock(toolSchemas: toolSchemas)
    }

    /// `encode_arguments_to_dsml`: render one assistant tool call's
    /// arguments as `<｜DSML｜parameter ...>` elements. `argumentsValue` is
    /// whatever `function.arguments` is upstream: either already an object
    /// (e.g. `OpenAIChatMessage.templateMessageDict()`'s
    /// `decodeToolCallArguments` pre-decode), or the OpenAI wire's native
    /// shape — a raw JSON string — which is parsed here exactly like the
    /// reference's `json.loads(tool_call["arguments"])`, falling back to
    /// `{"arguments": <raw string>}` on parse failure (mirroring the
    /// reference's `except:` branch) or when `arguments` is absent/of an
    /// unexpected type.
    ///
    /// Parameter order is alphabetical by key — see `DeepseekV4JSON`'s doc
    /// comment for why the reference's source-JSON key order can't be
    /// reproduced from an already-decoded Swift dictionary.
    static func encodeArgumentsToDsml(_ argumentsValue: (any Sendable)?) -> String {
        let dict: DSV4Msg
        if let object = argumentsValue as? DSV4Msg {
            dict = object
        } else if let raw = argumentsValue as? String {
            if let parsed = DeepseekV4JSON.parse(raw) as? DSV4Msg {
                dict = parsed
            } else {
                dict = ["arguments": raw]
            }
        } else {
            dict = [:]
        }

        return dict.keys.sorted().map { key -> String in
            let value = dict[key]!
            let isString = value is String
            let valueText = isString ? (value as! String) : DeepseekV4JSON.toJSON(value)
            return DeepseekV4Tokens.parameter(name: key, isString: isString, value: valueText)
        }.joined(separator: "\n")
    }
}
