import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Chat session history and presentation")
@MainActor
struct ChatSessionTests {
    @Test("New Chat preserves the transcript and an unsent draft, and history can swap sessions")
    func historyPreservesWork() throws {
        let store = ChatStore()
        let firstID = store.conversationID
        let prompt = try #require(store.beginResponse(to: "First experiment"))
        store.completeResponse(to: prompt)
        let firstMessages = store.messages
        store.draft = "A follow-up\nwith detail"
        store.selectedModelID = "local-model-a"
        store.reset()

        #expect(store.messages.isEmpty)
        #expect(store.draft.isEmpty)
        #expect(store.history.count == 1)
        #expect(store.history[0].messages == firstMessages)
        #expect(store.history[0].draft == "A follow-up\nwith detail")
        #expect(store.conversationID != firstID)
        #expect(store.selectedModelID == "local-model-a")

        store.draft = "Another unsent experiment"
        let secondID = store.conversationID
        store.selectedModelID = "local-model-b"
        store.restoreConversation(firstID)
        #expect(store.messages == firstMessages)
        #expect(store.draft == "A follow-up\nwith detail")
        #expect(store.selectedModelID == "local-model-a")
        #expect(store.history.map(\.id) == [secondID])

        store.restoreConversation(secondID)
        #expect(store.messages.isEmpty)
        #expect(store.draft == "Another unsent experiment")
        #expect(store.selectedModelID == "local-model-b")
    }

    @Test("New Chat does not add empty sessions to history")
    func emptyHistory() {
        let store = ChatStore()
        store.reset()
        store.reset()
        #expect(store.history.isEmpty)
        store.draft = "Draft only"
        store.reset()
        #expect(store.history.count == 1)
        #expect(store.history.first?.title == "Draft only")
    }

    @Test("Fenced code preserves indentation and stays readable before its closing fence arrives")
    func codeFences() {
        #expect(ChatTextBlock.parse("Try **this**:\n```swift\nlet answer = 42\n    print(answer)") == [
            .text("Try **this**:"),
            .code(language: "swift", content: "let answer = 42\n    print(answer)"),
        ])
        #expect(ChatTextBlock.parse("~~~python\nprint('ok')\n~~~\nDone.") == [
            .code(language: "python", content: "print('ok')"), .text("Done."),
        ])
        #expect(ChatTextBlock.parse("````text\n```\n````") == [
            .code(language: "text", content: "```"),
        ])
    }

    @Test("HTTP failures distinguish authentication, busy, and endpoint errors without echoing server content")
    func actionableErrors() {
        let denied = ChatFailure.from(.httpError(statusCode: 401, detail: "private prompt"))
        #expect(denied.recovery == .localAPI)
        #expect(denied.title.contains("401"))
        #expect(!denied.detail.contains("private prompt"))
        let busy = ChatFailure.from(.httpError(statusCode: 503, detail: nil))
        #expect(busy.recovery == nil)
        #expect(busy.title.contains("busy"))
        #expect(ChatFailure.noModels.recovery == .models)
    }
}
