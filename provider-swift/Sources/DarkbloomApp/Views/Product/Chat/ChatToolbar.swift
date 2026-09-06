import SwiftUI

struct ChatToolbar: CustomizableToolbarContent {
    let canStartNewChat: Bool
    let onNewChat: () -> Void

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "new-chat", placement: .primaryAction) {
            Button("New Chat", systemImage: "square.and.pencil", action: onNewChat)
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!canStartNewChat)
                .help("New Chat (⌘N). Keep this conversation and draft in History.")
        }
    }
}
