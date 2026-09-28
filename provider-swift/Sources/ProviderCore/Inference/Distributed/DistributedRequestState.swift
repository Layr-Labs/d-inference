import Foundation
import MLXLMCommon

/// Acknowledgement latch has no timeout: inventing retirement would release
/// provider reservations while a peer may still own arrays or execute work.
final class DistributedRetirementLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if completed { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func complete() {
        let pending = lock.withLock {
            completed = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }
}

/// Cancellation may arrive before reserve returns. Arming the exact generation
/// afterward consumes that cancellation without touching another request's ID.
final class DistributedAdmissionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (@Sendable () -> Void)?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func arm(_ action: @escaping @Sendable () -> Void) {
        let run = lock.withLock {
            self.action = action
            return cancelled
        }
        if run { action() }
    }

    func cancel() {
        let action = lock.withLock {
            cancelled = true
            return self.action
        }
        action?()
    }
}

/// All mutable fields except the acknowledgement latch belong to engine.queue.
final class DistributedRequestState: @unchecked Sendable {
    let generation = UUID()
    let request: CBv2Request
    let lease: any DistributedResidentRequestLease
    let continuation: AsyncStream<CBv2Event>.Continuation
    let detokenizer: any CBv2IncrementalDetokenizer
    let retired = DistributedRetirementLatch()
    let absoluteDeadline: ContinuousClock.Instant
    let firstTokenDeadline: ContinuousClock.Instant?
    let admissionStartedAt: ContinuousClock.Instant
    let reservedAt: ContinuousClock.Instant
    var deadlineTask: Task<Void, Never>?
    var completionTokens = 0
    var terminal: CBv2FinishReason?
    var cancelSent = false

    init(
        request: CBv2Request, lease: any DistributedResidentRequestLease,
        continuation: AsyncStream<CBv2Event>.Continuation,
        detokenizer: any CBv2IncrementalDetokenizer,
        absoluteDeadline: ContinuousClock.Instant,
        firstTokenDeadline: ContinuousClock.Instant?,
        admissionStartedAt: ContinuousClock.Instant,
        reservedAt: ContinuousClock.Instant
    ) {
        self.request = request
        self.lease = lease
        self.continuation = continuation
        self.detokenizer = detokenizer
        self.absoluteDeadline = absoluteDeadline
        self.firstTokenDeadline = firstTokenDeadline
        self.admissionStartedAt = admissionStartedAt
        self.reservedAt = reservedAt
    }

    var retirement: CBv2RequestRetirement {
        CBv2RequestRetirement { [retired] in await retired.wait() }
    }
}
