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
// released load has not yet taken the memory or slot that check sizes.
//
// `DARKBLOOM_TTFT_COLD_LOAD_RELEASE=0` restores the fully serial FIFO.

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
    /// the FIFO at a model-load wait.
    func admitInWorkFIFO(
        requestId: String, _ admit: @escaping @Sendable (WorkFIFOGate?) async -> Void
    ) async {
        // A duplicate id waits for its released namesake, as the serial FIFO did.
        await awaitReleasedAdmission(requestId)
        guard coldLoadReleasesWorkFIFO else {
            await admit(nil)
            return
        }
        let gate = WorkFIFOGate()
        Task {
            await admit(gate)
            await self.finishWorkFIFOAdmission(gate, requestId: requestId)
        }
        await gate.wait()
    }

    /// Called by an accepted, registered request about to wait for a model
    /// load: later events may proceed while it waits.
    func releaseWorkFIFO(_ gate: WorkFIFOGate?, requestId: String, modelId: String) {
        guard let gate, releasedAdmissions[requestId] == nil else { return }
        releasedAdmissions[requestId] = ReleasedAdmission(modelId: modelId)
        if !gate.open() { releasedAdmissions.removeValue(forKey: requestId) }
    }

    /// Called before the fast admission check of a request whose model is
    /// not resident. A released load of another model has not reserved its
    /// memory or slot yet, so the check would admit against capacity that
    /// load is about to take; the request waits for it, as the serial FIFO
    /// made it wait. Requests for a resident model, or for the model being
    /// loaded, still overtake.
    func awaitReleasedLoads(otherThan modelId: String) async {
        while let requestId = releasedAdmissions.first(where: { $0.value.modelId != modelId })?.key {
            await awaitReleasedAdmission(requestId)
        }
    }

    /// A coordinator cancel for a released admission is held until it returns.
    func deferCancelForReleasedAdmission(_ requestId: String) -> Bool {
        guard releasedAdmissions[requestId] != nil else { return false }
        releasedAdmissions[requestId]?.cancelPending = true
        return true
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

    private func finishWorkFIFOAdmission(_ gate: WorkFIFOGate, requestId: String) async {
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
