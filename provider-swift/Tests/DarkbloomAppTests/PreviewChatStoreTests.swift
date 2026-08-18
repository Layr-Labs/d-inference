import Testing
@testable import DarkbloomApp

@Test("Chat ignores blank messages and accepts trimmed prompts")
@MainActor
func previewChatValidatesDrafts() throws {
    let store = PreviewChatStore()

    #expect(store.beginResponse(to: "  \n ") == nil)
    #expect(store.messages.isEmpty)
    #expect(!store.isResponding)

    let prompt = try #require(store.beginResponse(to: "  Hello from this Mac  "))
    #expect(prompt == "Hello from this Mac")
    #expect(store.messages == [
        LocalChatMessage(
            id: store.messages[0].id,
            role: .user,
            text: "Hello from this Mac"
        ),
    ])
    #expect(store.isResponding)
}

@Test("Chat adds an explicitly labeled sample reply")
@MainActor
func previewChatCompletesSampleResponse() throws {
    let store = PreviewChatStore(route: .thisMac)
    let prompt = try #require(store.beginResponse(to: "Explain unified memory"))

    store.completeResponse(to: prompt)

    #expect(store.messages.count == 2)
    #expect(store.messages.last?.role == .assistant)
    #expect(store.messages.last?.isPreview == true)
    #expect(store.messages.last?.text.contains("no model ran") == true)
    #expect(!store.isResponding)
}

@Test("Stopping a sample reply keeps the user message and permits another send")
@MainActor
func previewChatCanStopAndContinue() throws {
    let store = PreviewChatStore()
    _ = try #require(store.beginResponse(to: "First thought"))

    #expect(store.beginResponse(to: "Blocked while replying") == nil)
    store.stopResponse()
    #expect(!store.isResponding)
    #expect(store.messages.count == 1)

    _ = try #require(store.beginResponse(to: "Second thought"))
    #expect(store.messages.count == 2)
}

@Test("New chat clears transient conversation state")
@MainActor
func previewChatResetClearsConversation() throws {
    let store = PreviewChatStore()
    _ = try #require(store.beginResponse(to: "A thought"))

    store.reset()

    #expect(store.messages.isEmpty)
    #expect(!store.isResponding)
    #expect(!store.hasConversation)
}

@Test("Network sample copy never claims that routing occurred")
func previewNetworkReplyIsTruthful() {
    let response = PreviewChatResponse.text(
        for: "Help me compare local and network inference",
        route: .privateNetwork
    )

    #expect(response.contains("Nothing was encrypted, routed, or inferred"))
}

@Test("Conversation fixture renders one complete preview exchange")
@MainActor
func previewChatConversationFixtureIsComplete() {
    let store = PreviewChatStore(fixture: .conversation)

    #expect(store.messages.count == 2)
    #expect(store.messages.first?.role == .user)
    #expect(store.messages.last?.role == .assistant)
    #expect(store.messages.last?.isPreview == true)
    #expect(!store.isResponding)
}

@Test("Product preview can request a populated chat conversation")
func productPreviewResolvesChatFixture() throws {
    let preview = try #require(ProductPreviewConfiguration.resolve(environment: [
        "DARKBLOOM_PREVIEW_PRODUCT_DESTINATION": "chat",
        "DARKBLOOM_PREVIEW_CHAT_FIXTURE": "conversation",
    ]))

    #expect(preview.destination == .chat)
    #expect(preview.chatFixture == .conversation)
}
