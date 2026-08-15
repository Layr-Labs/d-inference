import Testing

@testable import ProviderCore

@Suite("Qwen 3.5/3.6 template compatibility")
struct Qwen35TemplateFixesTests {
    private let qwenContext = ChatTemplateFixContext(
        modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8",
        modelType: "qwen3_5_moe")

    private func message(
        _ role: String,
        _ content: String
    ) -> [String: any Sendable] {
        ["role": role, "content": content]
    }

    private func roles(_ messages: [[String: any Sendable]]) -> [String] {
        messages.compactMap { $0["role"] as? String }
    }

    @Test func appliesOnlyToQwen35Family() {
        #expect(Qwen35TemplateFix.applies(to: qwenContext))
        #expect(Qwen35TemplateFix.applies(
            to: .init(modelId: nil, modelType: "qwen3_5_moe")))
        #expect(Qwen35TemplateFix.applies(
            to: .init(modelId: "mlx-community/Qwen3.6-35B", modelType: nil)))
        #expect(!Qwen35TemplateFix.applies(
            to: .init(modelId: "qwen3-8b", modelType: "qwen3")))
        #expect(!Qwen35TemplateFix.applies(
            to: .init(modelId: "gemma-4-26b", modelType: "gemma4_text")))
    }

    @Test func movesSingleLateSystemMessageToBeginning() throws {
        let normalized = try ChatTemplateFixes.normalizeMessages(
            [
                message("user", "first question"),
                message("assistant", "first answer"),
                message("system", "follow the updated policy"),
                message("user", "next question"),
            ],
            context: qwenContext)

        #expect(roles(normalized) == ["system", "user", "assistant", "user"])
        #expect(normalized[0]["content"] as? String == "follow the updated policy")
    }

    @Test func mergesMultipleSystemMessagesInHistoryOrder() throws {
        let normalized = try ChatTemplateFixes.normalizeMessages(
            [
                message("system", "base policy"),
                message("user", "first question"),
                message("system", "new restriction"),
                message("assistant", "answer"),
                message("system", "final reminder"),
                message("user", "next question"),
            ],
            context: qwenContext)

        #expect(roles(normalized) == ["system", "user", "assistant", "user"])
        #expect(
            normalized[0]["content"] as? String
                == "base policy\n\nnew restriction\n\nfinal reminder")
    }

    @Test func normalizesBeforeGenericToolHistoryValidation() throws {
        let toolCall: [String: any Sendable] = [
            "id": "call-1",
            "type": "function",
            "function": [
                "name": "lookup",
                "arguments": [String: any Sendable](),
            ] as [String: any Sendable],
        ]
        let assistant: [String: any Sendable] = [
            "role": "assistant",
            "content": "",
            "tool_calls": [toolCall] as [any Sendable],
        ]
        let toolResult: [String: any Sendable] = [
            "role": "tool",
            "content": "result",
            "tool_call_id": "call-1",
        ]

        let normalized = try ChatTemplateFixes.normalizeMessages(
            [
                message("user", "look this up"),
                assistant,
                message("system", "use trusted sources"),
                toolResult,
            ],
            context: qwenContext)

        #expect(roles(normalized) == ["system", "user", "assistant", "tool"])
    }

    @Test func leavesVisionUserContentUntouched() throws {
        let userContent: [any Sendable] = [
            ["type": "text", "text": "describe this"] as [String: any Sendable],
            [
                "type": "image_url",
                "image_url": ["url": "https://example.invalid/image.png"]
                    as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        let user: [String: any Sendable] = ["role": "user", "content": userContent]

        let normalized = try ChatTemplateFixes.normalizeMessages(
            [user, message("system", "be concise")],
            context: qwenContext)

        #expect(roles(normalized) == ["system", "user"])
        let normalizedContent = try #require(normalized[1]["content"] as? [any Sendable])
        #expect(normalizedContent.count == 2)
        #expect((normalizedContent[1] as? [String: any Sendable])?["type"] as? String == "image_url")
    }

    @Test func mergesTextPartSystemContent() throws {
        let systemParts: [any Sendable] = [
            ["type": "text", "text": "base "] as [String: any Sendable],
            ["type": "text", "text": "policy"] as [String: any Sendable],
        ]
        let system: [String: any Sendable] = ["role": "system", "content": systemParts]

        let normalized = try ChatTemplateFixes.normalizeMessages(
            [system, message("user", "question"), message("system", "late reminder")],
            context: qwenContext)

        #expect(roles(normalized) == ["system", "user"])
        #expect(normalized[0]["content"] as? String == "base policy\n\nlate reminder")
    }

    @Test func doesNotCoerceMediaSystemContent() throws {
        let mediaContent: [any Sendable] = [
            [
                "type": "image_url",
                "image_url": ["url": "https://example.invalid/system.png"]
                    as [String: any Sendable],
            ] as [String: any Sendable]
        ]
        let mediaSystem: [String: any Sendable] = [
            "role": "system", "content": mediaContent,
        ]

        let normalized = try ChatTemplateFixes.normalizeMessages(
            [message("system", "base"), message("user", "question"), mediaSystem],
            context: qwenContext)

        #expect(roles(normalized) == ["system", "user", "system"])
    }

    @Test func nonQwenHistoryIsNotReordered() throws {
        let normalized = try ChatTemplateFixes.normalizeMessages(
            [message("user", "question"), message("system", "late policy")],
            context: .init(modelId: "gemma-4-26b", modelType: "gemma4_text"))

        #expect(roles(normalized) == ["user", "system"])
    }
}
