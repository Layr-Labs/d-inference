import Foundation

/// A single qualification fault, not an alternate signer. The ordinary adapter
/// supplies the key/hash and invokes the real API; only callback delivery changes.
final class QualificationAssertionCallbacks: AppAttestCallbacks, @unchecked Sendable {
    typealias Phase = AppAttestWorkerClient.QualificationAssertionEvent.Phase
    typealias Observer = @Sendable (Phase) -> Void

    private enum State {
        case available
        case armed(Observer)
        case consumed
    }

    private let lock = NSLock()
    private let qualificationAllowed: Bool
    private let underlying: any AppAttestCallbacks
    private var state: State = .available

    init(qualificationAllowed: Bool, underlying: any AppAttestCallbacks = SystemAppAttestCallbacks()) {
        self.qualificationAllowed = qualificationAllowed
        self.underlying = underlying
    }

    var requiresNextAssertion: Bool {
        lock.withLock {
            if case .armed = state { return true }
            return false
        }
    }

    func armNextAssertion(onEvent: @escaping Observer) throws {
        try lock.withLock {
            guard qualificationAllowed else { throw AppAttestWorkerError.qualificationRequired }
            guard case .available = state else { throw AppAttestWorkerError.busy }
            state = .armed(onEvent)
        }
    }

    func generateKey(_ complete: @escaping @Sendable (Result<String, Error>) -> Void) {
        underlying.generateKey(complete)
    }

    func attestKey(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        underlying.attestKey(id, hash: hash, complete: complete)
    }

    func generateAssertion(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        let observer: Observer? = lock.withLock {
            guard case .armed(let observer) = state else { return nil }
            state = .consumed
            return observer
        }
        guard let observer else {
            underlying.generateAssertion(id, hash: hash, complete: complete)
            return
        }
        let invocation = DiscardedInvocation(observer: observer)
        // Do not retain or call `complete`, even on an error or duplicate Apple
        // callback. In particular, never release AppleOperationGate admission.
        underlying.generateAssertion(id, hash: hash) { _ in invocation.receivedCallback() }
        invocation.submitted()
    }

    private final class DiscardedInvocation: @unchecked Sendable {
        private let lock = NSLock()
        private let observer: Observer
        private var invocationReturned = false
        private var callbackReceived = false
        private var discardReported = false

        init(observer: @escaping Observer) { self.observer = observer }

        func submitted() {
            lock.withLock {
                invocationReturned = true
                observer(.submitted)
                reportDiscardLocked()
            }
        }

        func receivedCallback() {
            lock.withLock {
                callbackReceived = true
                reportDiscardLocked()
            }
        }

        private func reportDiscardLocked() {
            guard invocationReturned, callbackReceived, !discardReported else { return }
            discardReported = true
            // A synchronous callback is held here until real invocation has
            // returned, so submitted always precedes callbackDiscarded.
            observer(.callbackDiscarded)
        }
    }
}
