import Foundation

/// Invoke at the Library's explicit "Use model" boundary, before opening Chat.
/// Browsing Library or revisiting Studio must not replace a conversation's model.
@MainActor
enum ChatModelHandoff {
    @discardableResult
    static func select(_ modelID: String, in chat: ChatStore) -> Bool {
        guard !modelID.isEmpty else { return false }
        // Preserve the user's explicit Library choice even when the current
        // endpoint serves a different model. Chat's catalog validation then
        // blocks Send and explains the mismatch instead of silently using the
        // previous model. An active attempt has already captured its model in
        // ChatStore, so this changes only the next turn. No process starts or
        // stops at this boundary, and no selection is replayed after readiness.
        chat.selectedModelID = modelID
        return true
    }
}
