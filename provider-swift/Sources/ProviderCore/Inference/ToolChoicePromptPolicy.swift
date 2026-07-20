// Copyright © 2026 Eigen Labs.

import MLXLMServer

enum ToolChoicePromptPolicy {
    struct Prepared: Sendable {
        let messages: [OpenAIChatMessage]
        let tools: [OpenAITool]?
        let mode: ToolConstraintMode
        let compiledTools: [CompiledToolSchema]?
        let allowsParallelCalls: Bool
        let allowedToolNames: Set<String>

        var requiresToolCall: Bool {
            switch mode {
            case .required, .named: true
            case .none, .auto: false
            }
        }
    }

    static func prepare(_ request: OpenAIChatCompletionRequest) throws -> Prepared {
        try validateToolNames(request.tools)
        let allowsParallelCalls = request.parallelToolCalls ?? true
        switch request.toolChoice {
        case nil, .mode(.auto):
            return Prepared(
                messages: request.messages,
                tools: request.tools,
                mode: .auto,
                compiledTools: try? ToolConstraintSchemaCompiler.compile(
                    tools: request.tools, mode: .auto),
                allowsParallelCalls: allowsParallelCalls,
                allowedToolNames: Set(request.tools?.map(\.function.name) ?? []))

        case .mode(.none):
            return Prepared(
                messages: addingInstruction(
                    "Do not call any tool. Answer the user directly without emitting a tool call.",
                    to: request.messages),
                tools: nil,
                mode: .none,
                compiledTools: nil,
                allowsParallelCalls: false,
                allowedToolNames: [])

        case .mode(.required):
            guard let tools = request.tools, !tools.isEmpty else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "tool_choice 'required' needs at least one declared tool")
            }
            let instruction: String
            if tools.count == 1, let name = tools.first?.function.name {
                instruction =
                    "Call the declared function '\(name)' now. You must emit a tool call with valid "
                    + "arguments before any final answer, even when the user's request does not require the tool. "
                    + "Your entire response must be the tool call; a text answer is forbidden. For any required "
                    + "string argument without an obvious value, use the user's request text."
            } else {
                instruction =
                    "Call one of the declared tools now. You must emit a tool call with valid arguments "
                    + "before any final answer, even when the user's request does not require a tool. "
                    + "Your entire response must be the tool call; a text answer is forbidden."
            }
            let compiled = try compileConstrainedTools(tools, mode: .required)
            return Prepared(
                messages: forcingInstruction(instruction, in: request.messages),
                tools: tools,
                mode: .required,
                compiledTools: compiled,
                allowsParallelCalls: allowsParallelCalls,
                allowedToolNames: Set(tools.map(\.function.name)))

        case .function(let name):
            guard let selected = request.tools?.first(where: { $0.function.name == name }) else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "tool_choice names an undeclared function")
            }
            let instruction =
                "Call the declared function '\(name)' now. You must emit a '\(name)' tool call with "
                + "valid arguments before any final answer, even when another function seems more relevant. "
                + "Your entire response must be that tool call; a text answer is forbidden. For any required "
                + "string argument without an obvious value, use the user's request text."
            let compiled = try compileConstrainedTools(
                [selected], mode: .named(name))
            return Prepared(
                messages: forcingInstruction(instruction, in: request.messages),
                tools: [selected],
                mode: .named(name),
                compiledTools: compiled,
                allowsParallelCalls: allowsParallelCalls,
                allowedToolNames: [name])
        }
    }

    private static func validateToolNames(_ tools: [OpenAITool]?) throws {
        var names = Set<String>()
        for tool in tools ?? [] {
            guard isValidFunctionName(tool.function.name) else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "tool function names must match ^[a-zA-Z0-9_-]{1,64}$")
            }
            guard names.insert(tool.function.name).inserted else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "tool function names must be unique")
            }
        }
    }

    static func isValidFunctionName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard (1...64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
        }
    }

    private static func compileConstrainedTools(
        _ tools: [OpenAITool],
        mode: ToolConstraintMode
    ) throws -> [CompiledToolSchema] {
        do {
            return try ToolConstraintSchemaCompiler.compile(tools: tools, mode: mode)
        } catch let error as ToolConstraintSchemaError {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                error.localizedDescription)
        }
    }

    private static func forcingInstruction(
        _ instruction: String,
        in messages: [OpenAIChatMessage]
    ) -> [OpenAIChatMessage] {
        var messages = addingInstruction(instruction, to: messages)
        guard let userIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return messages
        }
        switch messages[userIndex].content {
        case .text(let content):
            messages[userIndex].content = .text(content + "\n\n" + instruction)
        case .parts(var parts):
            parts.append(.text(instruction))
            messages[userIndex].content = .parts(parts)
        case .null:
            messages[userIndex].content = .text(instruction)
        }
        return messages
    }

    private static func addingInstruction(
        _ instruction: String,
        to messages: [OpenAIChatMessage]
    ) -> [OpenAIChatMessage] {
        var messages = messages
        if messages.first?.role == .system {
            switch messages[0].content {
            case .text(let content):
                messages[0].content = .text(content + "\n\n" + instruction)
            case .parts(var parts):
                parts.append(.text(instruction))
                messages[0].content = .parts(parts)
            case .null:
                messages[0].content = .text(instruction)
            }
        } else {
            messages.insert(
                OpenAIChatMessage(role: .system, content: .text(instruction)),
                at: 0)
        }
        return messages
    }
}
