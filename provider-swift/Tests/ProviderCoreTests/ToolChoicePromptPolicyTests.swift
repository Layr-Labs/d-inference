// Copyright © 2026 Eigen Labs.

import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("OpenAI tool_choice prompt policy")
struct ToolChoicePromptPolicyTests {
    @Test("none hides tool declarations and forbids calls")
    func noneHidesTools() throws {
        let prepared = try ToolChoicePromptPolicy.prepare(request(choice: .mode(.none)))

        #expect(prepared.tools == nil)
        #expect(prepared.messages.first?.role == .system)
        #expect(prepared.messages.first?.textContent.contains("Do not call any tool") == true)
    }

    @Test("required keeps declarations and requires a call")
    func requiredKeepsTools() throws {
        let prepared = try ToolChoicePromptPolicy.prepare(request(choice: .mode(.required)))

        #expect(prepared.tools?.map(\.function.name) == ["get_current_weather", "calculate"])
        #expect(prepared.messages.first?.textContent.contains("Call one") == true)
        #expect(prepared.messages.last?.textContent.contains("Call one") == true)
    }

    @Test("named choice exposes only the selected declaration")
    func namedChoiceFiltersTools() throws {
        let prepared = try ToolChoicePromptPolicy.prepare(
            request(choice: .function(name: "calculate")))

        #expect(prepared.tools?.map(\.function.name) == ["calculate"])
        #expect(prepared.messages.first?.textContent.contains("'calculate'") == true)
        #expect(prepared.messages.last?.textContent.contains("'calculate'") == true)
    }

    @Test("instruction augments an existing system message")
    func existingSystemMessageIsAugmented() throws {
        var input = request(choice: .mode(.required))
        input.messages.insert(
            OpenAIChatMessage(role: .system, content: .text("Original policy.")), at: 0)

        let prepared = try ToolChoicePromptPolicy.prepare(input)

        #expect(prepared.messages.count == input.messages.count)
        #expect(prepared.messages[0].textContent.hasPrefix("Original policy."))
        #expect(prepared.messages[0].textContent.contains("Call one") == true)
    }

    @Test("named choice rejects undeclared functions")
    func namedChoiceRejectsUndeclaredFunction() {
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            try ToolChoicePromptPolicy.prepare(request(choice: .function(name: "missing")))
        }
    }

    private func request(choice: OpenAIToolChoice) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: "gemma-4",
            messages: [OpenAIChatMessage(role: .user, content: .text("hello"))],
            tools: [tool("get_current_weather"), tool("calculate")],
            toolChoice: choice)
    }

    private func tool(_ name: String) -> OpenAITool {
        OpenAITool(function: OpenAIFunctionDefinition(name: name))
    }
}
