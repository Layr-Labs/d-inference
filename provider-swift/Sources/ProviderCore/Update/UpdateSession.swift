import Foundation

extension SelfUpdater {
    /// A cross-process update lease. Holding a session is mandatory for every
    /// stage, commit, recovery, or rollback mutation.
    public final class UpdateSession: @unchecked Sendable {
        let processLock: UpdateProcessLock
        let store: UpdateRecoveryStore
        private let releaseMutex = NSLock()
        private var released = false

        init(processLock: UpdateProcessLock, store: UpdateRecoveryStore) {
            self.processLock = processLock
            self.store = store
        }

        deinit {
            release()
        }

        public func release() {
            releaseMutex.lock()
            defer { releaseMutex.unlock() }
            guard !released else { return }
            released = true
            processLock.release()
        }

        func recover(now: Double = Date().timeIntervalSince1970) throws {
            try store.recoverInterruptedTransaction(now: now)
        }

        func readState() throws -> UpdateRecoveryState {
            try store.loadState()
        }

        func writeState(_ state: UpdateRecoveryState) throws {
            try store.writeState(state)
        }

        @discardableResult
        func rollback(now: Double, reason: String) throws -> String {
            try store.rollback(now: now, reason: reason)
        }
    }
}
