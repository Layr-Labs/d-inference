// Copyright © 2026 Eigen Labs.
//
// The coordinator work FIFO admits one inference request at a time. A request
// for a model that is not resident used to hold it for the whole cold load (or
// the wait on another load), so warm models' requests, cancels and attestation
// challenges queued behind seconds or minutes of weight loading.
//
// Such a request now releases the FIFO at that wait, after it was accepted and
// registered for cancellation, so admission order up to that point is
// unchanged. A coordinator cancel for it is applied when its admission ends,
// where the serial FIFO applied it. Connection, drain and model-management
// events wait for released admissions first, as they always did. So does the
// admission check of a request for another model that is not resident: the
// released load may not hold the memory or slot that check sizes yet. A request
// for the model being loaded is checked at once and, if rejected, checked again
// after that load, which may already hold the memory sized for a second copy.
//
// `DARKBLOOM_TTFT_COLD_LOAD_RELEASE=0` restores the fully serial FIFO.
//
// Coordinator cancels and attestation challenges never enter the FIFO: the
// connection reader handles them. Cancelling a request reaches its engine, and
// a pair's engine can be held by a rank reservation for up to 30 s, during
// which a cancel in the FIFO held back every later event. A cancel for a
// request whose admission has not returned is held and applied when it
// returns, exactly where the FIFO applied it; any other cancel runs at once,
// beside the FIFO. Either way a cancel never runs during its own request's
// admission, and never waits behind another request's work.

import Foundation

/// Opens a waiting work FIFO once: early at a model-load wait, or when the
/// admission returns.
final class WorkFIFOGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if isOpen { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Opens the gate; false when it was already open.
    func open() -> Bool {
        let (opened, waiting) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
            guard !isOpen else { return (false, nil) }
            isOpen = true
            defer { continuation = nil }
            return (true, continuation)
        }
        waiting?.resume()
        return opened
    }
}

/// An admission that released the work FIFO and has not returned yet.
struct ReleasedAdmission {
    /// The model whose load it waits for.
    let modelId: String
    var cancelPending = false
    var waiters: [CheckedContinuation<Void, Never>] = []
}

enum WorkFIFOPolicy {
    static let coldLoadReleaseEnvironmentKey = "DARKBLOOM_TTFT_COLD_LOAD_RELEASE"

    static func releasesColdLoadWaits(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[coldLoadReleaseEnvironmentKey]?
            .trimmingCharacters(in: .whitespaces).lowercased() else { return true }
        return !["0", "false", "off", "no"].contains(raw)
    }
}

extension CoordinatorEvent {
    /// Whether the event may run while an earlier request waits for its model
    /// load. These events neither reorder that request's admission nor depend
    /// on it; every other event waits for released admissions to return.
    var overtakesReleasedAdmissions: Bool {
        switch self {
        case .inferenceRequest, .cancel, .attestationChallenge, .codeAttestationResumeChallenge,
            .runtimeOutdated:
            true
        case .drainAck, .connected, .disconnected, .appAttestShadow, .trustStatus, .loadModel,
            .modelAutopilotControl, .modelAutopilot, .prefetchModel, .desiredModels:
            false
        }
    }
}

extension ProviderLoop {
    /// Runs one inference admission and returns when it finished or released
    /// the FIFO at a model-load wait. Its `queuedBytes`, charged by the
    /// connection reader (`queueCoordinatorAdmission`), are released when the
    /// admission returns.
    func admitInWorkFIFO(
        requestId: String, queuedBytes: Int, _ admit: @escaping @Sendable (WorkFIFOGate?) async -> Void
    ) async {
        // A duplicate id waits for its released namesake, as the serial FIFO did.
        await awaitReleasedAdmission(requestId)
        guard coldLoadReleasesWorkFIFO else {
            await admit(nil)
            coordinatorAdmissionReturned(requestId, queuedBytes: queuedBytes)
            return
        }
        let gate = WorkFIFOGate()
        Task {
            await admit(gate)
            await self.finishWorkFIFOAdmission(gate, requestId: requestId, queuedBytes: queuedBytes)
        }
        await gate.wait()
    }

    /// Called by an accepted, registered request about to wait for a model
    /// load: later events may proceed while it waits.
    func releaseWorkFIFO(_ gate: WorkFIFOGate?, requestId: String, modelId: String) {
        guard let gate, releasedAdmissions[requestId] == nil else { return }
        releasedAdmissions[requestId] = ReleasedAdmission(modelId: modelId)
        guard gate.open() else {
            releasedAdmissions.removeValue(forKey: requestId)
            return
        }
        // A cancel that arrived during the admission now waits with it.
        if cancelsAwaitingAdmission.remove(requestId) != nil {
            releasedAdmissions[requestId]?.cancelPending = true
        }
    }

    /// Called before the fast admission check of a request whose model is
    /// not resident. A released load of another model may not hold its
    /// memory or slot yet, so the check would admit against capacity that
    /// load is about to take; the request waits for it, as the serial FIFO
    /// made it wait. Requests for a resident model, or for the model being
    /// loaded, still overtake.
    func awaitReleasedLoads(otherThan modelId: String) async {
        await awaitReleasedLoads { $0 != modelId }
    }

    /// Called when the fast admission check rejected a request for a model
    /// that a released admission is loading. That load may already hold the
    /// memory the check sized for a second copy, so the request waits for it
    /// and is checked again, as the serial FIFO checked it after the load.
    /// False when no released admission loads `modelId`.
    func awaitReleasedLoads(of modelId: String) async -> Bool {
        guard releasedAdmissions.values.contains(where: { $0.modelId == modelId }) else { return false }
        await awaitReleasedLoads { $0 == modelId }
        return true
    }

    private func awaitReleasedLoads(where loadsModel: (String) -> Bool) async {
        while let requestId = releasedAdmissions.first(where: { loadsModel($0.value.modelId) })?.key {
            await awaitReleasedAdmission(requestId)
        }
    }

    /// A coordinator cancel for a released admission is held until it returns.
    func deferCancelForReleasedAdmission(_ requestId: String) -> Bool {
        guard releasedAdmissions[requestId] != nil else { return false }
        releasedAdmissions[requestId]?.cancelPending = true
        return true
    }

    /// The connection reader queues a coordinator request for admission if it
    /// fits beside those already waiting; false if not. Its ciphertext counts
    /// against the budget until its admission returns. The coordinator keeps
    /// at most a provider's width pending, so this binds only while admission
    /// is stalled (a serial model load) and expired or cancelled requests keep
    /// arriving.
    func queueCoordinatorAdmission(_ requestId: String, bytes: Int) -> Bool {
        let queued = unreturnedCoordinatorAdmissions.values.reduce(0, +)
        guard queued < coordinatorQueueBudget.requests,
              bytes <= coordinatorQueueBudget.bytes - queuedCoordinatorBytes
        else { return false }
        unreturnedCoordinatorAdmissions[requestId, default: 0] += 1
        queuedCoordinatorBytes += bytes
        return true
    }

    /// Refuses a request that does not fit, on arrival and never queued, as
    /// `CoordinatorClient.refuseInferenceBeforeDispatch` refuses: `queue_full`
    /// on a capacity 429, as the engine's own queue refuses, which the
    /// coordinator retries elsewhere, and its
    /// service reservation released at once. The connection reader keeps
    /// reading cancels and control frames.
    func refuseCoordinatorRequestPastQueueBudget(
        _ requestId: String, profile: RequestProfileBuilder, serviceReservationID: String?, send: SendHandle
    ) {
        logger.warning("Refusing inference request \(requestId): the admission queue is full")
        send.send(.inferenceError(requestId: requestId,
            failure: InferenceFailure(code: .capacity, statusCode: 429, errorReason: .queueFull), profile: profile))
        if let id = ServiceReservationLifetime.normalizedID(serviceReservationID) {
            send.send(.serviceReservationReleased(serviceReservationID: id))
        }
    }

    /// A coordinator cancel, as the connection reader reads it. A request
    /// still queued for admission, or being admitted, keeps it until that
    /// admission returns; any other request is cancelled now. Its reason
    /// waits for `handleCancellation`, which takes it on every path.
    func routeCoordinatorCancel(_ requestId: String, reason: CoordinatorCancelReason? = nil) {
        if let reason { coordinatorCancelReasons[requestId] = reason }
        if deferCancelForReleasedAdmission(requestId) { return }
        if unreturnedCoordinatorAdmissions[requestId] != nil {
            cancelsAwaitingAdmission.insert(requestId)
            return
        }
        startCoordinatorCancellation(requestId)
    }

    /// The admission of a coordinator request returned: its queued bytes are
    /// released, and a cancel held for it runs now.
    func coordinatorAdmissionReturned(_ requestId: String, queuedBytes: Int) {
        queuedCoordinatorBytes -= queuedBytes
        guard let count = unreturnedCoordinatorAdmissions[requestId] else { return }
        guard count <= 1 else {
            unreturnedCoordinatorAdmissions[requestId] = count - 1
            return
        }
        unreturnedCoordinatorAdmissions.removeValue(forKey: requestId)
        if cancelsAwaitingAdmission.remove(requestId) != nil {
            startCoordinatorCancellation(requestId)
        }
    }

    /// Cancels beside the work FIFO: neither the connection reader nor the
    /// FIFO waits for it to reach the engine.
    private func startCoordinatorCancellation(_ requestId: String) {
        Task { await handleCancellation(requestId: requestId) }
    }

    /// Waits until every released admission has returned.
    func awaitReleasedAdmissions() async {
        while let requestId = releasedAdmissions.keys.first {
            await awaitReleasedAdmission(requestId)
        }
    }

    private func awaitReleasedAdmission(_ requestId: String) async {
        guard releasedAdmissions[requestId] != nil else { return }
        await withCheckedContinuation { continuation in
            if releasedAdmissions[requestId] == nil {
                continuation.resume()
            } else {
                releasedAdmissions[requestId]?.waiters.append(continuation)
            }
        }
    }

    private func finishWorkFIFOAdmission(_ gate: WorkFIFOGate, requestId: String, queuedBytes: Int) async {
        defer { coordinatorAdmissionReturned(requestId, queuedBytes: queuedBytes) }
        // An admission that never released resumes the FIFO here.
        if gate.open() { return }
        guard releasedAdmissions[requestId] != nil else { return }
        // Apply a cancel that arrived meanwhile before anything that waits
        // for this admission, exactly where the serial FIFO applied it.
        if releasedAdmissions[requestId]?.cancelPending == true {
            await handleCancellation(requestId: requestId)
        }
        for waiter in releasedAdmissions.removeValue(forKey: requestId)?.waiters ?? [] {
            waiter.resume()
        }
    }
}

/// How many coordinator requests, and how many ciphertext bytes, may wait for
/// admission at once. Above the coordinator's pending cap (a provider's width:
/// at most 24 requests of at most 16 MiB, 384 MiB), so ordinary serving never
/// meets it.
struct CoordinatorQueueBudget: Sendable {
    let requests: Int
    let bytes: Int

    static let standard = CoordinatorQueueBudget(requests: 64, bytes: 512 << 20)
}
