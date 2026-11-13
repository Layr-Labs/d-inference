import Foundation

/// Journal and state authority for update commit, interrupted-transaction
/// recovery, and rollback. Concrete install-layout operations live in
/// `UpdateInstallLayout`; callers must hold `UpdateProcessLock`.
final class UpdateRecoveryStore: @unchecked Sendable {
    enum FaultPoint: Sendable, Equatable, CaseIterable {
        case predecessorPromoted
        case transactionPersisted
        case liveLayoutExchanged
        case liveLayoutReplaced
        case statePersisted
        case transactionRemoved
    }

    enum StoreError: Error, CustomStringConvertible {
        case corruptState(String)
        case corruptTransaction(String)
        case missingLiveInstall
        case missingPredecessor(String)
        case predecessorVerificationFailed(String)
        case interruptedRecoveryFailed(String)
        case filesystem(String)

        var description: String {
            switch self {
            case .corruptState(let reason):
                return "update recovery state is unreadable: \(reason)"
            case .corruptTransaction(let reason):
                return "update transaction journal is unreadable: \(reason)"
            case .missingLiveInstall:
                return "current provider install is incomplete; no signed \(BuildEnvironment.current.appBundleName) found"
            case .missingPredecessor(let reason):
                return "verified predecessor unavailable: \(reason)"
            case .predecessorVerificationFailed(let reason):
                return "verified predecessor refused: \(reason)"
            case .interruptedRecoveryFailed(let reason):
                return "interrupted update recovery failed: \(reason)"
            case .filesystem(let reason):
                return reason
            }
        }
    }

    private enum TransactionKind: String, Codable {
        case install
        case rollback
    }

    private enum TransactionPhase: String, Codable {
        case prepared
        case liveReplaced = "live_replaced"
    }

    private struct Transaction: Codable {
        var schema: Int
        var kind: TransactionKind
        var phase: TransactionPhase
        var target: InstalledReleaseRecord
        var layout: VerifiedPredecessor.Layout
        var stagingRoot: String
        var createdAt: Double
        /// The rollback's quarantine reason, for a replay to record. Absent
        /// in journals of earlier releases, which ignore it.
        var reason: String?

        enum CodingKeys: String, CodingKey {
            case schema
            case kind
            case phase
            case target
            case layout
            case stagingRoot = "staging_root"
            case createdAt = "created_at"
            case reason
        }
    }

    let installRoot: URL
    let recoveryRoot: URL
    let lockPath: URL
    let verifyCodeSignatures: Bool
    let faultInjector: @Sendable (FaultPoint) throws -> Void
    let fm = FileManager.default

    private var statePath: URL {
        recoveryRoot.appendingPathComponent("state.json")
    }
    private var transactionPath: URL {
        recoveryRoot.appendingPathComponent("transaction.json")
    }
    var predecessorRoot: URL {
        recoveryRoot.appendingPathComponent("predecessor", isDirectory: true)
    }
    /// A rollback copy on its way out (`removeRollbackCopy`).
    static let retiredPredecessorPrefix = ".predecessor-retired-"
    private var predecessorManifestPath: URL {
        predecessorRoot.appendingPathComponent("manifest.json")
    }

    init(
        installRoot: URL,
        verifyCodeSignatures: Bool,
        faultInjector: @escaping @Sendable (FaultPoint) throws -> Void = { _ in }
    ) {
        self.installRoot = installRoot.standardizedFileURL
        self.recoveryRoot = installRoot
            .appendingPathComponent("recovery", isDirectory: true)
            .standardizedFileURL
        self.lockPath = recoveryRoot.appendingPathComponent("update.lock")
        self.verifyCodeSignatures = verifyCodeSignatures
        self.faultInjector = faultInjector
    }

    func loadState() throws -> UpdateRecoveryState {
        var state: UpdateRecoveryState
        if fm.fileExists(atPath: statePath.path) {
            do {
                state = try JSONDecoder().decode(
                    UpdateRecoveryState.self,
                    from: Data(contentsOf: statePath)
                )
            } catch {
                throw StoreError.corruptState(error.localizedDescription)
            }
            guard state.schema == UpdateRecoveryState.currentSchema else {
                throw StoreError.corruptState("unsupported schema \(state.schema)")
            }
            if let failures = state.candidate?.failureCount, failures < 0 {
                throw StoreError.corruptState("negative candidate failure count")
            }
            if let failures = state.quarantine?.failureCount, failures < 0 {
                throw StoreError.corruptState("negative quarantine failure count")
            }
        } else {
            state = UpdateRecoveryState()
        }

        // The manifest is inside the atomically-promoted predecessor tree, so
        // it wins if death occurred after promotion but before state replace.
        if fm.fileExists(atPath: predecessorManifestPath.path) {
            let diskManifest: VerifiedPredecessor
            do {
                diskManifest = try JSONDecoder().decode(
                    VerifiedPredecessor.self,
                    from: Data(contentsOf: predecessorManifestPath)
                )
            } catch {
                throw StoreError.corruptState(
                    "predecessor manifest: \(error.localizedDescription)")
            }
            state.predecessor = diskManifest
        } else if state.predecessor != nil {
            throw StoreError.corruptState(
                "state references a missing predecessor directory")
        }
        return state
    }

    func writeState(_ state: UpdateRecoveryState) throws {
        try UpdateAtomicFilesystem.writeJSON(state, to: statePath)
    }

    func recoverInterruptedTransaction(now: Double) throws {
        guard fm.fileExists(atPath: transactionPath.path) else {
            cleanupOrphanedRecoveryTemps()
            return
        }
        let transaction = try readTransaction()
        var state = try loadState()

        if try liveMatches(transaction.target) {
            try ensureCanonicalLinks()
            try finalizeRecovered(transaction, state: &state, now: now)
            try cleanupTransaction(transaction)
            return
        }

        let stagingRoot = URL(
            fileURLWithPath: transaction.stagingRoot
        ).standardizedFileURL
        guard UpdateAtomicFilesystem.isDescendant(stagingRoot, of: installRoot) else {
            throw StoreError.corruptTransaction("staging path escapes install root")
        }

        if try stagingContainsTarget(stagingRoot, target: transaction.target) {
            try installFromStaging(stagingRoot)
            guard try liveMatches(transaction.target) else {
                throw StoreError.interruptedRecoveryFailed(
                    "target hashes do not match after replay")
            }
            try ensureCanonicalLinks()
            try finalizeRecovered(transaction, state: &state, now: now)
            try cleanupTransaction(transaction)
            return
        }

        guard let predecessor = state.predecessor else {
            throw StoreError.interruptedRecoveryFailed(
                "neither target staging nor a predecessor is available; live install left untouched")
        }
        try verifyPredecessor(predecessor)
        try restorePredecessorCopy(
            predecessor,
            stagingName: ".recovery-restore-\(UUID().uuidString)"
        )
        guard try liveMatches(predecessor.release) else {
            throw StoreError.interruptedRecoveryFailed(
                "predecessor hashes do not match after restore")
        }
        if transaction.kind == .install {
            state.candidate = nil
            state.current = predecessor.release
        } else {
            state.completeRollback(
                now: now,
                reason: transaction.reason
                    ?? "recovered an interrupted rollback of \(transaction.target.version)"
            )
        }
        try writeState(state)
        try cleanupTransaction(transaction)
    }

    func commit(
        staged: SelfUpdater.StagedBundle,
        currentVersion: String,
        now: Double
    ) throws {
        try recoverInterruptedTransaction(now: now)
        var state = try loadState()
        let predecessor = try preparePredecessor(
            state: &state,
            currentVersion: currentVersion,
            now: now
        )

        let (nextGeneration, overflow) =
            state.installGeneration.addingReportingOverflow(1)
        guard !overflow else {
            throw StoreError.corruptState("install generation overflow")
        }
        let candidate = try recordForStagedBundle(
            staged,
            generation: nextGeneration,
            now: now
        )
        var transaction = Transaction(
            schema: 1,
            kind: .install,
            phase: .prepared,
            target: candidate,
            layout: .app,
            stagingRoot: staged.stagingRoot.standardizedFileURL.path,
            createdAt: now
        )
        try persist(transaction)
        try faultInjector(.transactionPersisted)

        try installStagedBundle(staged)
        try faultInjector(.liveLayoutExchanged)
        transaction.phase = .liveReplaced
        try persist(transaction)
        try faultInjector(.liveLayoutReplaced)

        state.installCandidate(candidate, predecessor: predecessor, now: now)
        try writeState(state)
        try faultInjector(.statePersisted)
        try finish(remove: staged.stagingRoot)
    }

    /// Restore the verified predecessor over the installed release (a pending
    /// candidate, or a promoted release for an operator rollback) and
    /// quarantine that release.
    func rollback(now: Double, reason: String) throws -> String {
        try recoverInterruptedTransaction(now: now)
        var state = try loadState()
        guard let predecessor = state.predecessor else {
            throw StoreError.missingPredecessor(
                "v\(state.rollbackSource?.version ?? state.current?.version ?? "unknown") has no recorded predecessor")
        }
        guard state.rollbackSource != nil else {
            throw StoreError.missingPredecessor(
                "v\(predecessor.release.version), the recorded predecessor, is already installed")
        }
        try verifyPredecessor(predecessor)
        let (rollbackGeneration, overflow) =
            state.installGeneration.addingReportingOverflow(1)
        guard !overflow else {
            throw StoreError.corruptState("install generation overflow")
        }

        let stagingRoot = installRoot.appendingPathComponent(
            ".rollback-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try copyPredecessor(predecessor, to: stagingRoot)
        try verifyStagedPredecessor(predecessor, at: stagingRoot)

        var transaction = Transaction(
            schema: 1,
            kind: .rollback,
            phase: .prepared,
            target: predecessor.release,
            layout: predecessor.layout,
            stagingRoot: stagingRoot.path,
            createdAt: now,
            reason: reason
        )
        try persist(transaction)
        try faultInjector(.transactionPersisted)

        try installFromStaging(stagingRoot)
        try ensureCanonicalLinks()
        try faultInjector(.liveLayoutExchanged)
        transaction.phase = .liveReplaced
        try persist(transaction)
        try faultInjector(.liveLayoutReplaced)

        state.installGeneration = rollbackGeneration
        state.completeRollback(now: now, reason: reason)
        try writeState(state)
        try faultInjector(.statePersisted)
        try finish(remove: stagingRoot)
        return predecessor.release.version
    }

    /// The record's installed release (the pending candidate, else `current`) must be the installed app: the hashes
    /// the updater recorded, and the version its signed `Info.plist` names when it names one. Evidence of an install
    /// outside the updater (`install.sh`, a copied app), a signed version or hashes that differ, re-bases the record:
    /// the installed app becomes `current`, as the release its `Info.plist` names (else `runningVersion`), and the
    /// pending release and the rollback copy go. A pair forms only between Macs on the same build
    /// (`ClusterConfiguration.peerBuildDiffers`), and that copy was kept for an install that is gone, so no other Mac
    /// keeps it to follow a rollback to it. An installed app that cannot be read is no such evidence: the record stays,
    /// so failed starts of a damaged release still count toward restoring the verified copy. Nil when nothing changed.
    func reconcileWithInstalledApp(runningVersion: String, now: Double) throws -> UpdateRecoveryReconciliation? {
        var state = try loadState()
        let signed = installedSignedVersion()
        if let recorded = state.candidate?.release ?? state.current {
            if (signed != nil && signed != recorded.version) || installedApp(is: recorded) == false {
                return try recordInstalledApp(as: signed ?? runningVersion, in: &state, now: now)
            }
        }
        // Checked only where apps name their version (every release does): an app that names none cannot vouch for one.
        guard signed != nil, let copy = state.predecessor else { return nil }
        return try reconcileRollbackCopy(copy, in: &state, now: now)
    }

    /// The rollback copy must be recorded as the release its app is signed as. A copy an earlier updater labelled from a
    /// stale record holds the release that ran here before, the one the other Mac keeps and follows a rollback to: when
    /// its files are the recorded ones and its signature holds (`verifyPredecessor`) it is relabelled and kept. A copy
    /// that names no version, or does not verify, is removed (fail closed).
    private func reconcileRollbackCopy(_ copy: VerifiedPredecessor, in state: inout UpdateRecoveryState,
                                       now: Double) throws -> UpdateRecoveryReconciliation? {
        let signed = try Self.signedVersion(ofApp: resolvedRecoveryPath(copy.bundlePath))
        guard signed != copy.release.version else { return nil }
        if let signed, (try? verifyPredecessor(copy)) != nil {
            var relabelled = copy
            relabelled.release.version = signed
            relabelled.release.releaseBundleHash = nil
            relabelled.verifiedAt = now
            // The manifest inside the copy first: `loadState` takes it over the record, so a death before the record is
            // written still leaves the new label.
            try UpdateAtomicFilesystem.writeJSON(relabelled, to: predecessorManifestPath)
            state.predecessor = relabelled
            try writeState(state)
            return .rollbackCopyRelabelled(recordedAs: copy.release.version, signed: signed)
        }
        try discardRollbackCopy(in: &state)
        return .unverifiedRollbackCopyRemoved(recordedAs: copy.release.version)
    }

    /// The installed app becomes `current`, as release `version`; the pending release and the rollback copy go.
    private func recordInstalledApp(as version: String, in state: inout UpdateRecoveryState,
                                    now: Double) throws -> UpdateRecoveryReconciliation {
        let (generation, overflow) = state.installGeneration.addingReportingOverflow(1)
        guard !overflow else {
            throw StoreError.corruptState("install generation overflow")
        }
        let installed = try installedAppRecord(version: version, generation: generation, now: now)
        let change = UpdateRecoveryReconciliation.installedOutsideTheUpdater(
            installed: version, recorded: state.current?.version, pending: state.candidate?.release.version,
            removedCopy: state.predecessor?.release.version)
        state.candidate = nil
        try discardRollbackCopy(in: &state)
        // Named last: a death before this write leaves the same mismatch for the next reconcile to finish.
        state.installGeneration = generation
        state.current = installed
        try writeState(state)
        return change
    }

    /// The record stops naming the rollback copy before its tree goes (`removeRollbackCopy`): `loadState` refuses a
    /// record that names a missing copy, and a death in between leaves the copy's manifest naming it again.
    private func discardRollbackCopy(in state: inout UpdateRecoveryState) throws {
        guard state.predecessor != nil else { return }
        state.predecessor = nil
        try writeState(state)
        try removeRollbackCopy()
    }

    func verifyPredecessor(_ predecessor: VerifiedPredecessor) throws {
        let bundle = try resolvedRecoveryPath(predecessor.bundlePath)
        let binary = try resolvedRecoveryPath(predecessor.binaryPath)
        let enclave = try resolvedRecoveryPath(predecessor.enclavePath)
        let metallib = try resolvedRecoveryPath(predecessor.metallibPath)
        guard fm.fileExists(atPath: bundle.path),
              fm.fileExists(atPath: binary.path),
              fm.fileExists(atPath: enclave.path),
              fm.fileExists(atPath: metallib.path)
        else {
            throw StoreError.predecessorVerificationFailed(
                "recorded files are missing")
        }
        do {
            let bundleHash = try UpdateAtomicFilesystem.treeHash(root: bundle)
            guard bundleHash == predecessor.release.installedBundleHash else {
                throw StoreError.predecessorVerificationFailed(
                    "bundle hash mismatch (expected \(predecessor.release.installedBundleHash), got \(bundleHash))")
            }
            let binaryHash = try UpdateAtomicFilesystem.sha256(file: binary)
            guard binaryHash == predecessor.release.binaryHash else {
                throw StoreError.predecessorVerificationFailed(
                    "binary hash mismatch (expected \(predecessor.release.binaryHash), got \(binaryHash))")
            }
            let enclaveHash = try UpdateAtomicFilesystem.sha256(file: enclave)
            guard enclaveHash == predecessor.release.enclaveHash else {
                throw StoreError.predecessorVerificationFailed(
                    "enclave hash mismatch (expected \(predecessor.release.enclaveHash), got \(enclaveHash))")
            }
            let metallibHash = try UpdateAtomicFilesystem.sha256(file: metallib)
            guard metallibHash == predecessor.release.metallibHash else {
                throw StoreError.predecessorVerificationFailed(
                    "metallib hash mismatch (expected \(predecessor.release.metallibHash), got \(metallibHash))")
            }
            try verifySignature(bundle: bundle, binary: binary)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.predecessorVerificationFailed(
                error.localizedDescription)
        }
    }

    private func preparePredecessor(
        state: inout UpdateRecoveryState,
        currentVersion: String,
        now: Double
    ) throws -> VerifiedPredecessor {
        if let candidate = state.candidate {
            // A pending release that is not the installed app was replaced outside the updater: the installed app,
            // not the pending release's copy, is what the new release replaces and keeps for rollback.
            guard try stagingContainsTarget(installRoot, target: candidate.release) else {
                state.candidate = nil
                return try snapshotInstalledApp(state: &state, currentVersion: currentVersion, now: now)
            }
            guard let predecessor = state.predecessor else {
                throw StoreError.missingPredecessor(
                    "an unproven installed candidate exists without rollback material")
            }
            try verifyPredecessor(predecessor)
            return predecessor
        }
        return try snapshotInstalledApp(state: &state, currentVersion: currentVersion, now: now)
    }

    /// Keeps a copy of the installed app for rollback, recorded as the release its app is signed as. `current` lends the
    /// copy its version, release hash and install generation only when it names that release (or the app names none);
    /// otherwise it describes an app replaced outside the updater, and the copy's record becomes `current` instead.
    private func snapshotInstalledApp(
        state: inout UpdateRecoveryState,
        currentVersion: String,
        now: Double
    ) throws -> VerifiedPredecessor {
        let signed = installedSignedVersion()
        let recorded = state.current.flatMap { signed == nil || $0.version == signed ? $0 : nil }
        let predecessor = try snapshotLiveAsPredecessor(
            version: recorded?.version ?? signed ?? currentVersion,
            releaseBundleHash: recorded?.releaseBundleHash,
            installGeneration: recorded?.installGeneration
                ?? state.installGeneration,
            now: now
        )
        state.predecessor = predecessor
        if recorded == nil {
            state.current = predecessor.release
        }
        try writeState(state)
        return predecessor
    }

    private func finalizeRecovered(
        _ transaction: Transaction,
        state: inout UpdateRecoveryState,
        now: Double
    ) throws {
        guard let predecessor = state.predecessor else {
            throw StoreError.interruptedRecoveryFailed(
                "predecessor metadata is missing")
        }
        switch transaction.kind {
        case .install:
            if state.candidate?.release != transaction.target {
                state.installCandidate(
                    transaction.target,
                    predecessor: predecessor,
                    now: now
                )
            }
        case .rollback:
            // A replay after the state write (death before the journal was
            // removed) finds the rollback already recorded: count it once.
            guard state.rollbackSource != nil else { break }
            let (generation, overflow) =
                state.installGeneration.addingReportingOverflow(1)
            guard !overflow else {
                throw StoreError.corruptState("install generation overflow")
            }
            state.installGeneration = generation
            state.completeRollback(
                now: now,
                reason: transaction.reason
                    ?? "recovered rollback after \(state.candidate?.failureCount ?? 0) failed starts"
            )
        }
        try writeState(state)
    }

    private func readTransaction() throws -> Transaction {
        let transaction: Transaction
        do {
            transaction = try JSONDecoder().decode(
                Transaction.self,
                from: Data(contentsOf: transactionPath)
            )
        } catch {
            throw StoreError.corruptTransaction(error.localizedDescription)
        }
        guard transaction.schema == 1 else {
            throw StoreError.corruptTransaction(
                "unsupported schema \(transaction.schema)")
        }
        return transaction
    }

    private func persist(_ transaction: Transaction) throws {
        try UpdateAtomicFilesystem.writeJSON(transaction, to: transactionPath)
    }

    private func finish(remove staging: URL) throws {
        try UpdateAtomicFilesystem.removeDurably(transactionPath)
        try faultInjector(.transactionRemoved)
        try UpdateAtomicFilesystem.removeDurably(staging)
        cleanupOrphanedRecoveryTemps()
    }

    private func cleanupTransaction(_ transaction: Transaction) throws {
        try UpdateAtomicFilesystem.removeDurably(transactionPath)
        let staging = URL(
            fileURLWithPath: transaction.stagingRoot
        ).standardizedFileURL
        if UpdateAtomicFilesystem.isDescendant(staging, of: installRoot) {
            try UpdateAtomicFilesystem.removeDurably(staging)
        }
        cleanupOrphanedRecoveryTemps()
    }

    private func cleanupOrphanedRecoveryTemps() {
        guard let entries = try? fm.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries
        where entry.lastPathComponent.hasPrefix(".predecessor-next-")
            || entry.lastPathComponent.hasPrefix(Self.retiredPredecessorPrefix) {
            try? fm.removeItem(at: entry)
        }
    }
}
