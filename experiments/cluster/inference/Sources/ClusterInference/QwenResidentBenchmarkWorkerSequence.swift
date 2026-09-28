import Foundation

/// Only control progress is tracked here. The private native owner remains
/// responsible for request retirement, cancellation and actual model release.
/// An accepted run is pending until complete; acceptance performs no work.
struct QwenResidentBenchmarkWorkerSequence {
    let open: QwenResidentBenchmarkWorkerOpen
    private(set) var completedRequests = 0
    private(set) var isStopped = false
    private(set) var failed = false
    private var pending: QwenResidentBenchmarkWorkerRun?
    var requestActive: Bool { pending != nil }

    init(open: QwenResidentBenchmarkWorkerOpen) throws {
        try QwenResidentBenchmarkWorkerCommand.open(open).validate()
        self.open = open
    }

    /// Return one matched run, or nil for the exact shutdown after four results.
    /// No command is accepted after any failure, including an attempted replay.
    mutating func accept(command: QwenResidentBenchmarkWorkerCommand) throws -> QwenResidentBenchmarkWorkerRun? {
        do {
            guard !failed, !isStopped, pending == nil else {
                throw ProbeError("Resident benchmark sequence is failed, stopped or awaiting completion")
            }
            try command.validate()
            switch command {
            case .open:
                throw ProbeError("Resident benchmark open cannot be repeated")
            case .run(let request):
                guard completedRequests < QwenResidentBenchmarkWorkerCommand.requestCount,
                      request.cohortID == open.cohortID, request.sequence == completedRequests + 1 else {
                    throw ProbeError("Resident benchmark run changed cohort or replayed its sequence")
                }
                let expected = open.requests[completedRequests]
                guard request.requestID == expected.requestID, request.epoch == expected.epoch else {
                    throw ProbeError("Resident benchmark run differs from the predeclared request")
                }
                pending = request
                return request
            case .shutdown(let request):
                guard completedRequests == QwenResidentBenchmarkWorkerCommand.requestCount,
                      request.cohortID == open.cohortID else {
                    throw ProbeError("Resident benchmark shutdown preceded four completed requests or changed cohort")
                }
                isStopped = true
                return nil
            }
        } catch {
            failed = true
            throw error
        }
    }

    /// Called by the trusted owner only after the request/result path succeeds.
    /// This acknowledgment is not independent proof of native state retirement.
    mutating func complete(request: QwenResidentBenchmarkWorkerRun) throws {
        guard !failed, !isStopped, let pending, pending == request else {
            failed = true
            throw ProbeError("Resident benchmark completion has no matching pending request")
        }
        self.pending = nil
        completedRequests += 1
    }

    /// Covers decoding, output and owner errors outside accept/complete. It does
    /// not clear a pending native scope or permit another run or shutdown.
    mutating func fail() { failed = true }
}
