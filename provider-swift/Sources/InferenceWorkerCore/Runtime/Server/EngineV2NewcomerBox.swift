import Foundation
import MLXLMCommon

/// Single-owner box that permits explicit release of newly loaded weights before
/// survivor KV grants are restored after a failed re-slice.
final class EngineV2NewcomerBox: @unchecked Sendable {
    private let lock = NSLock()
    var container: ModelContainer?

    init(_ container: ModelContainer) {
        self.container = container
    }

    func borrow() -> ModelContainer {
        lock.lock()
        defer { lock.unlock() }
        precondition(container != nil, "newcomer container was already released")
        return container!
    }

    func release() {
        lock.lock()
        container = nil
        lock.unlock()
    }
}
