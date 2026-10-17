import Foundation
import MLXLMServer

/// This process's memory of Responses conversations for `previous_response_id`, least recently used dropped
/// first. Bounded by bytes as well as by count: each entry holds its whole conversation, inline media included,
/// so a long chat's entries grow with every turn.
final class LocalResponseConversationStore: @unchecked Sendable {
    private let lock = NSLock()
    private let maxResponses: Int
    private let maxBytes: Int
    private var conversations: [String: Data] = [:]
    /// Least recently used first.
    private var recency: [String] = []
    private var bytes = 0

    init(maxResponses: Int = 256, maxBytes: Int = 64 * 1024 * 1024) {
        self.maxResponses = maxResponses
        self.maxBytes = maxBytes
    }

    /// The input items a request continuing `responseID` starts from, as a JSON array.
    func conversation(for responseID: String) -> Data? {
        lock.withLock {
            guard let items = conversations[responseID] else { return nil }
            recency.removeAll { $0 == responseID }
            recency.append(responseID)
            return items
        }
    }

    func save(responseID: String, conversation: Data) {
        lock.withLock {
            remove(responseID)
            guard conversation.count <= maxBytes else { return }
            while recency.count >= maxResponses || bytes + conversation.count > maxBytes, let oldest = recency.first {
                remove(oldest)
            }
            conversations[responseID] = conversation
            recency.append(responseID)
            bytes += conversation.count
        }
    }

    func record(responseID: String, output: [OpenAIResponseOutputItem], inputItems: Data) {
        guard let conversation = LocalResponseConversation.conversation(inputItems: inputItems, output: output)
        else { return }
        save(responseID: responseID, conversation: conversation)
    }

    /// Passes every frame through as it arrives. The terminal response is remembered before its frame is
    /// yielded, so a client that sends its follow-up on `response.completed` finds it.
    func recording(
        _ frames: AsyncThrowingStream<String, Error>, inputItems: Data
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in frames {
                        if let response = LocalResponseConversation.finalResponse(inFrame: frame) {
                            record(responseID: response.id, output: response.output, inputItems: inputItems)
                        }
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Caller holds `lock`.
    private func remove(_ responseID: String) {
        guard let removed = conversations.removeValue(forKey: responseID) else { return }
        recency.removeAll { $0 == responseID }
        bytes -= removed.count
    }
}
