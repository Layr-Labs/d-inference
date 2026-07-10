import Foundation

/// Protocol v2 prepared-lease lifecycle (mirrors `darkbloom_core::lease`).
/// Pure state machine — no I/O. Emission is illegal before a durable start record.
public enum PreparedLeaseState: Sendable, Equatable {
    case idle
    case preparing(jobId: String, attemptId: String)
    case prepared(jobId: String, attemptId: String, leaseId: String, prefillRunning: Bool)
    case running(jobId: String, attemptId: String, leaseId: String, startDurable: Bool, emitting: Bool)
    case terminalJournaled(jobId: String, attemptId: String, leaseId: String)
    case acknowledged
    case aborted(leaseId: String)
}

public enum PreparedLeaseEvent: Sendable, Equatable {
    case beginPrepare(jobId: String, attemptId: String)
    case markPrepared(leaseId: String, prefillRunning: Bool)
    case start
    case startDurable
    case beginEmit
    case journalTerminal
    case ackTerminal
    case abort(leaseId: String)
    case expirePrepared
}

public enum PreparedLeaseError: Error, Sendable, Equatable {
    case invalidTransition
    case abortTombstone
    case emissionBeforeDurableStart
}

public enum PreparedLeaseReducer {
    public static func transition(
        _ state: PreparedLeaseState,
        _ event: PreparedLeaseEvent
    ) throws -> PreparedLeaseState {
        switch (state, event) {
        case (.idle, .beginPrepare(let job, let attempt)):
            return .preparing(jobId: job, attemptId: attempt)

        case (.preparing(let job, let attempt), .markPrepared(let lease, let prefill)):
            return .prepared(jobId: job, attemptId: attempt, leaseId: lease, prefillRunning: prefill)

        case (.prepared(let job, let attempt, let lease, _), .start):
            return .running(jobId: job, attemptId: attempt, leaseId: lease, startDurable: false, emitting: false)

        case (.aborted, .start):
            throw PreparedLeaseError.abortTombstone

        case (.running(let job, let attempt, let lease, _, let emitting), .startDurable):
            return .running(jobId: job, attemptId: attempt, leaseId: lease, startDurable: true, emitting: emitting)

        case (.running(_, _, _, false, _), .beginEmit):
            throw PreparedLeaseError.emissionBeforeDurableStart

        case (.running(let job, let attempt, let lease, true, _), .beginEmit):
            return .running(jobId: job, attemptId: attempt, leaseId: lease, startDurable: true, emitting: true)

        case (.running(let job, let attempt, let lease, _, _), .journalTerminal):
            return .terminalJournaled(jobId: job, attemptId: attempt, leaseId: lease)

        case (.terminalJournaled, .ackTerminal):
            return .acknowledged

        case (.preparing, .abort(let lease)), (.prepared, .abort(let lease)):
            return .aborted(leaseId: lease)

        case (.prepared(_, _, let lease, _), .expirePrepared):
            return .aborted(leaseId: lease)

        case (.running(let job, let attempt, let lease, let durable, let emitting), .start):
            return .running(jobId: job, attemptId: attempt, leaseId: lease, startDurable: durable, emitting: emitting)

        default:
            throw PreparedLeaseError.invalidTransition
        }
    }
}
