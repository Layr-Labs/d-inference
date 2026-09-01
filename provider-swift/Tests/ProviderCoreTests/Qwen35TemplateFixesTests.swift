import Testing
import MLXLMCommon
import MLXLMServer

@testable import ProviderCore

private enum QwenTemplateTestError: Error {
    case systemMessageNotFirst
}

private struct QwenSystemFirstTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 0, count: text.count)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let roles = messages.compactMap { $0["role"] as? String }
        guard roles.first == "system", !roles.dropFirst().contains("system") else {
            throw QwenTemplateTestError.systemMessageNotFirst
        }
        return [1, 2, 3]
    }
}

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
            to: .init(modelId: nil, modelType: "qwen3_5")))
        #expect(Qwen35TemplateFix.applies(
            to: .init(modelId: "mlx-community/Qwen3.6-35B", modelType: nil)))
        #expect(Qwen35TemplateFix.applies(
            to: .init(modelId: "EigenLabs/Qwen3.8-27B-4bit", modelType: nil)))
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

    @Test func typedMessagesPreserveVisionUserContent() throws {
        let imagePart = OpenAIContentPart.imageURL("data:image/png;base64,AAAA")
        let user = OpenAIChatMessage(
            role: .user,
            content: .parts([.text("describe this"), imagePart]))
        let normalized = ChatTemplateFixes.normalizeMessages(
            [user, .init(role: .system, content: .text("be concise"))],
            context: qwenContext)

        #expect(normalized.map(\.role) == [.system, .user])
        #expect(normalized[0].content == .text("be concise"))
        #expect(normalized[1].content == user.content)
    }

    @Test func applyTemplateUsesLoadedModelTypeForOpaqueID() async throws {
        let engine = MultiModelBatchSchedulerEngine(
            acquire: { modelId in
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
            },
            tokenizerProvider: { _ in
                .init(
                    tokenizer: TokenizerHandle(QwenSystemFirstTokenizer()),
                    modelType: "qwen3_5_moe")
            },
            availableModels: { ["opaque-model"] })

        let response = try await engine.applyTemplate(.init(
            model: "opaque-model",
            messages: [
                .init(role: .user, content: .text("question")),
                .init(role: .system, content: .text("late policy")),
            ]))
        #expect(response.tokens == [1, 2, 3])
    }

    @Test func promptTokenFloorUsesLoadedModelTypeForOpaqueID() {
        let request = OpenAIChatCompletionRequest(
            model: "opaque-model",
            messages: [
                .init(role: .user, content: .text("question")),
                .init(role: .system, content: .text("late policy")),
            ])

        let floor = ProviderLoop.promptTokenFloor(
            request: request,
            tokenizer: TokenizerHandle(QwenSystemFirstTokenizer()),
            modelType: "qwen3_5_moe",
            templateControls: .init())
        #expect(floor == 3)
    }

    // MARK: - Qwen3-VL multi-system regression (OpenRouter failure case)
    //
    // Qwen3-VL's chat template consumes a system message only at
    // messages[0]. A mid-conversation system turn was silently DROPPED from
    // the rendered prompt, so the model never saw the instruction it was
    // later asked about. These tests pin the applicability gate and the
    // merged prompt shape for the exact failing history.

    private let qwen3VLContext = ChatTemplateFixContext(
        modelId: "qwen3-vl-30b-a3b-instruct",
        modelType: "qwen3_vl_moe")

    @Test func appliesToQwen3VLMoeModelType() {
        #expect(Qwen35TemplateFix.applies(to: qwen3VLContext))
        #expect(Qwen35TemplateFix.applies(
            to: .init(modelId: nil, modelType: "qwen3_vl_moe")))
        #expect(Qwen35TemplateFix.applies(
            to: .init(modelId: "qwen3-vl-30b-a3b-instruct", modelType: nil)))
        #expect(Qwen35TemplateFix.applies(
            to: .init(modelId: "EigenLabs/Qwen3.5-35B-A3B-MLX-VL-4bit-g64", modelType: nil)))
    }

    @Test func qwen3VLMidConversationSystemMessageReachesPrompt() throws {
        // The exact OpenRouter failing shape: a later system turn carrying an
        // instruction the model is subsequently asked to recall.
        let normalized = try ChatTemplateFixes.normalizeMessages(
            [
                message("system", "base policy"),
                message("user", "first question"),
                message("system", "the secret word is periwinkle"),
                message("assistant", "first answer"),
                message("user", "what is the secret word?"),
            ],
            context: qwen3VLContext)

        #expect(roles(normalized) == ["system", "user", "assistant", "user"])
        let systemContent = try #require(normalized[0]["content"] as? String)
        #expect(systemContent.contains("base policy"))
        #expect(systemContent.contains("periwinkle"))
        #expect(
            systemContent == "base policy\n\nthe secret word is periwinkle",
            "merged system content must preserve history order and separator")
        #expect(normalized[1]["content"] as? String == "first question")
        #expect(normalized[2]["content"] as? String == "first answer")
        #expect(normalized[3]["content"] as? String == "what is the secret word?")
    }

    @Test func qwen3VLTypedMessagesPreserveLaterSystemInstruction() {
        // The multimodal (UserInput) path uses the typed normalizer; vision
        // requests must not lose a later system instruction either.
        let normalized = ChatTemplateFixes.normalizeMessages(
            [
                .init(role: .system, content: .text("base policy")),
                .init(role: .user, content: .text("first question")),
                .init(role: .system, content: .text("the secret word is periwinkle")),
                .init(role: .assistant, content: .text("first answer")),
                .init(role: .user, content: .text("what is the secret word?")),
            ],
            context: qwen3VLContext)

        #expect(normalized.map(\.role) == [.system, .user, .assistant, .user])
        #expect(
            normalized[0].content
                == .text("base policy\n\nthe secret word is periwinkle"))
    }

    @Test func qwen3VLNormalizedHistoryPassesLeadingSystemTemplateContract() throws {
        // End-to-end shape: the model's own Jinja template (mirrored by
        // QwenSystemFirstTokenizer) rejects a history with a non-leading
        // system message. Normalization must make the SAME history
        // acceptable to that contract, and the merged system content must
        // still carry the later instruction.
        let raw = [
            ["role": "user", "content": "question"] as [String: any Sendable],
            ["role": "system", "content": "the secret word is periwinkle"]
                as [String: any Sendable],
        ]

        let tokenizer = QwenSystemFirstTokenizer()
        #expect(throws: QwenTemplateTestError.systemMessageNotFirst) {
            _ = try tokenizer.applyChatTemplate(
                messages: raw, tools: nil, additionalContext: nil)
        }

        let normalized = try ChatTemplateFixes.normalizeMessages(raw, context: qwen3VLContext)
        let tokens = try tokenizer.applyChatTemplate(
            messages: normalized, tools: nil, additionalContext: nil)
        #expect(tokens == [1, 2, 3])
        #expect(
            (normalized[0]["content"] as? String)?.contains("periwinkle") == true,
            "later system instruction must survive normalization")
    }

}
