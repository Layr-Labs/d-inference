import Foundation

/// One pending frame plus the writer's current frame. One consumer continuation
/// is notified immediately on arrival; its single timer only schedules an idle
/// probe. No stream-read task is raced or abandoned on timeout.
final class DistributedHTTPFramePump: @unchecked Sendable {
    enum Item: Sendable { case frame(String), end, failed(any Error) }
    enum Read: Sendable { case item(Item), probe, closed }
    private struct Resolution: Sendable {
        let read: Read
        let timer: Task<Void, Never>?
    }
    private struct Consumer {
        let id: UUID
        let continuation: CheckedContinuation<Resolution, Never>
    }
    private let lock = NSLock()
    private var slot: Item?
    private var taken: CheckedContinuation<Bool, Never>?
    private var consumer: Consumer?
    private var consumerActive = false
    private var wakeTimer: Task<Void, Never>?
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
            let result = lock.withLock { () -> (Bool?, Consumer?, Task<Void, Never>?) in
                guard !closed, slot == nil, taken == nil else { return (false, nil, nil) }
                if let waiting = consumer {
                    let timer = wakeTimer; consumer = nil; wakeTimer = nil
                    return (true, waiting, timer)
                }
                slot = item; taken = continuation
                return (nil, nil, nil)
            }
            result.2?.cancel()
            result.1?.continuation.resume(returning: .init(read: .item(item), timer: result.2))
            if let accepted = result.0 { continuation.resume(returning: accepted) }
        }
    }

    /// The writer is the only consumer. Keeping its active bit through timer
    /// join prevents a second waiter/timer while an old timer is still exiting.
    func next(until deadline: ContinuousClock.Instant) async -> Read {
        let accepted = lock.withLock { () -> Bool in
            guard !consumerActive else { return false }; consumerActive = true; return true
        }
        guard accepted else { return .closed }
        defer { lock.withLock { consumerActive = false } }
        let resolution = await withTaskCancellationHandler {
            let result = await wait(until: deadline)
            result.timer?.cancel()
            await result.timer?.value
            return result
        } onCancel: { _ = self.cancel() }
        if Task.isCancelled || lock.withLock({ closed }) {
            let task = cancel(); await task?.value
            return .closed
        }
        return resolution.read
    }

    private func wait(until deadline: ContinuousClock.Instant) async -> Resolution {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> (Read?, CheckedContinuation<Bool, Never>?) in
                guard !closed else { return (.closed, nil) }
                if let item = slot {
                    let producer = taken; slot = nil; taken = nil
                    return (.item(item), producer)
                }
                guard ContinuousClock.now < deadline else { return (.probe, nil) }
                let id = UUID()
                consumer = .init(id: id, continuation: continuation)
                wakeTimer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    self?.timeout(id)
                }
                return (nil, nil)
            }
            immediate.1?.resume(returning: true)
            if let read = immediate.0 { continuation.resume(returning: .init(read: read, timer: nil)) }
        }
    }

    private func timeout(_ id: UUID) {
        let result = lock.withLock { () -> (Consumer?, Task<Void, Never>?) in
            guard consumer?.id == id else { return (nil, nil) }
            let result = (consumer, wakeTimer); consumer = nil; wakeTimer = nil
            return result
        }
        result.0?.continuation.resume(returning: .init(read: .probe, timer: result.1))
    }

    /// Nonblocking inspection retained for the original bounded-backlog fixture.
    /// It cannot steal a frame from an active consumer.
    func take() -> Item? {
        let result = lock.withLock { () -> (Item?, CheckedContinuation<Bool, Never>?) in
            guard !consumerActive else { return (nil, nil) }
            let result = (slot, taken); slot = nil; taken = nil
            return result
        }
        result.1?.resume(returning: true)
        return result.0
    }

    var pendingFrames: Int { lock.withLock { slot == nil ? 0 : 1 } }
    var waitingConsumer: Bool { lock.withLock { consumer != nil } }

    /// Wake both sides outside the lock. The returned task permits the caller
    /// to join the producer; the resumed consumer joins its own cancelled timer.
    @discardableResult func cancel() -> Task<Void, Never>? {
        let result = lock.withLock { () -> (Task<Void, Never>?, CheckedContinuation<Bool, Never>?, Consumer?, Task<Void, Never>?) in
            guard !closed else { return (producer, nil, nil, nil) }
            closed = true; slot = nil
            let result = (producer, taken, consumer, wakeTimer)
            taken = nil; consumer = nil; wakeTimer = nil
            return result
        }
        result.0?.cancel(); result.3?.cancel()
        result.1?.resume(returning: false)
        result.2?.continuation.resume(returning: .init(read: .closed, timer: result.3))
        return result.0
    }
}
