import Foundation

/// One active streaming response for the one-request installed pipeline. The
/// response hold is separate from the model acquisition and native ownership.
final class DistributedHTTPResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var active: (UUID, DistributedHTTPResponse)?
    private var accepting = true
    private var deliveryDeadline: ContinuousClock.Instant?

    func begin() throws -> DistributedHTTPResponse {
        try lock.withLock {
            guard accepting, active == nil else {
                throw MultiModelBatchSchedulerEngineError.requestRejected("Distributed response is unavailable")
            }
            let id = UUID()
            let response = DistributedHTTPResponse { [weak self] in self?.complete(id) }
            active = (id, response)
            return response
        }
    }

    private func complete(_ id: UUID) {
        lock.withLock { if active?.0 == id { active = nil } }
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

    var hasActiveResponse: Bool { lock.withLock { active != nil } }

    func waitForDelivery() async {
        while true {
            let waiting = lock.withLock {
                active != nil && deliveryDeadline.map { ContinuousClock.now < $0 } == true
            }
            guard waiting else { return }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return }
        }
    }

    /// Called only after the actual HTTP service task (and its child handlers)
    /// has returned. A discarded/unstarted body is then no longer deliverable.
    func listenerStopped() {
        let response = lock.withLock { active?.1 }
        response?.finish()
    }

    func abort() {
        let response = lock.withLock { active?.1 }
        response?.disconnect()
    }
}
