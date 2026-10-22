import Foundation

/// The streaming responses of one installed pipeline: those being generated
/// (at most its batch lanes) and those queued behind them
/// (`DistributedRequestQueue.maximumWaiting`). Each response hold is separate
/// from the model acquisition and native ownership.
final class DistributedHTTPResponses: @unchecked Sendable {
    let generationID: UUID
    /// At most this many responses at once: the most lanes a pair runs and the
    /// queue behind them.
    let limit: Int
    private let lock = NSLock()
    private var active: [UUID: DistributedHTTPResponse] = [:]
    private var accepting = true
    private var deliveryDeadline: ContinuousClock.Instant?

    init(generationID: UUID = UUID(), limit: Int = DistributedRequestQueue.maximumWaiting + DistributedRequestQueue.maximumLanes) {
        self.generationID = generationID; self.limit = max(1, limit)
    }

    func begin() throws -> DistributedHTTPResponse {
        try lock.withLock {
            guard accepting else {
                throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed response is unavailable")
            }
            // Retryable: the queue frees as requests finish (429, not 503).
            guard active.count < limit else {
                throw MultiModelBatchSchedulerEngineError.queueFull(DistributedRequestQueue.fullMessage)
            }
            let id = UUID()
            let response = DistributedHTTPResponse(generationID: generationID) { [weak self] in self?.complete(id) }
            active[id] = response
            return response
        }
    }

    private func complete(_ id: UUID) {
        lock.withLock { _ = active.removeValue(forKey: id) }
    }

    func closeAdmissions() { lock.withLock { accepting = false } }

    /// Installed once, at cancellation; repeated stop/monitor calls cannot
    /// extend this delivery-only grace or any generation/native deadline.
    func beginDeliveryGrace(now: ContinuousClock.Instant = ContinuousClock.now) {
        lock.withLock {
            accepting = false
            if deliveryDeadline == nil { deliveryDeadline = now.advanced(by: .seconds(3)) }
        }
    }

    var hasActiveResponse: Bool { lock.withLock { !active.isEmpty } }
    var activeResponseCount: Int { lock.withLock { active.count } }

    func waitForDelivery() async {
        while true {
            let waiting = lock.withLock {
                !active.isEmpty && deliveryDeadline.map { ContinuousClock.now < $0 } == true
            }
            guard waiting else { return }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return }
        }
    }

    /// Called only after the actual HTTP service task (and its child handlers)
    /// has returned. A discarded/unstarted body is then no longer deliverable.
    func listenerStopped() {
        let responses = lock.withLock { Array(active.values) }
        for response in responses { response.finish() }
    }

    func abort() {
        let responses = lock.withLock { Array(active.values) }
        for response in responses { response.disconnect() }
    }
}
