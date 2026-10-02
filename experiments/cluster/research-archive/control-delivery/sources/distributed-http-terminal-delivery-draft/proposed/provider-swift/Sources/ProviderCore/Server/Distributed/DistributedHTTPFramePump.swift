import Foundation

/// One pending frame plus the writer's current frame. The producer cannot take
/// another source element until the consumer takes this slot. Polling the slot
/// lets that same writer issue bounded keepalive comments without a second writer.
final class DistributedHTTPFramePump: @unchecked Sendable {
    enum Item: Sendable { case frame(String), end, failed(any Error) }
    private let lock = NSLock()
    private var slot: Item?
    private var taken: CheckedContinuation<Bool, Never>?
    private var closed = false
    private var producer: Task<Void, Never>?

    init(_ frames: AsyncThrowingStream<String, Error>, maximumFrameBytes: Int) {
        producer = Task { [weak self] in
            guard let self else { return }
            do {
                for try await frame in frames {
                    guard frame.utf8.count <= maximumFrameBytes else {
                        throw DistributedHTTPEventStream.Failure.outputLimit
                    }
                    guard await offer(.frame(frame)) else { return }
                }
                _ = await offer(.end)
            } catch { _ = await offer(.failed(error)) }
        }
    }

    private func offer(_ item: Item) async -> Bool {
        await withCheckedContinuation { continuation in
            let refused = lock.withLock { () -> Bool in
                guard !closed, slot == nil, taken == nil else { return true }
                slot = item; taken = continuation
                return false
            }
            if refused { continuation.resume(returning: false) }
        }
    }

    func take() -> Item? {
        let result = lock.withLock { () -> (Item?, CheckedContinuation<Bool, Never>?) in
            let result = (slot, taken); slot = nil; taken = nil
            return result
        }
        result.1?.resume(returning: true)
        return result.0
    }

    var pendingFrames: Int { lock.withLock { slot == nil ? 0 : 1 } }

    @discardableResult func cancel() -> Task<Void, Never>? {
        let result = lock.withLock { () -> (Task<Void, Never>?, CheckedContinuation<Bool, Never>?) in
            closed = true; slot = nil
            let result = (producer, taken); producer = nil; taken = nil
            return result
        }
        result.0?.cancel(); result.1?.resume(returning: false)
        return result.0
    }
}
