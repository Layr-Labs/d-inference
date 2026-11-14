import DarkbloomClusterSecurity
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

        /// Where this install's cluster pairing keeps its link keys (`ClusterPairingStore.default()`'s); a stand-in in tests.
        var linkKeyVault: (any ClusterEdgeSecretVault)? = ClusterKeychainEdgeSecretVault.install()

        /// Every rollback (the operator's, the pair's follow, the candidate recovery, the watchdog) comes through here,
        /// in the release that is rolled back. The release it restores may read the cluster pairing's link keys only
        /// from files (0.10.12 and earlier), so they are written back from the Keychain into this install's pairing
        /// store beside its app: before the swap (a process that dies after it still leaves them), and again after it
        /// (for one a process started in between removed). Best effort; a later release that keeps the keys in the
        /// Keychain removes the files again (`ClusterPairingStore.edgeSecret`).
        @discardableResult
        func rollback(now: Double, reason: String) throws -> String {
            let pairing = ClusterPairingStore(directory: store.installRoot.appendingPathComponent("cluster-pairing", isDirectory: true),
                                              vault: linkKeyVault)
            _ = pairing.writeLegacyFilesForRollback()
            let restored = try store.rollback(now: now, reason: reason)
            _ = pairing.writeLegacyFilesForRollback()
            return restored
        }

        func reconcileWithInstalledApp(runningVersion: String, now: Double) throws -> UpdateRecoveryReconciliation? {
            try store.reconcileWithInstalledApp(runningVersion: runningVersion, now: now)
        }
    }
}
