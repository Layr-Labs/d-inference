import Foundation

/// Journal and state authority for update commit, interrupted-transaction
/// recovery, and rollback. Concrete install-layout operations live in
/// `UpdateInstallLayout`; callers must hold `UpdateProcessLock`.
final class UpdateRecoveryStore: @unchecked Sendable {
    enum FaultPoint: Sendable, Equatable {
        case predecessorPromoted
        case transactionPersisted
        case liveLayoutReplaced
        case statePersisted
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
                return "current provider install is incomplete; no signed app or flat binary layout found"
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

        enum CodingKeys: String, CodingKey {
            case schema
            case kind
            case phase
            case target
            case layout
            case stagingRoot = "staging_root"
            case createdAt = "created_at"
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

        if try liveMatches(transaction.target, layout: transaction.layout) {
            try ensureCanonicalLinks()
            try finalizeRecovered(transaction, state: &state, now: now)
            cleanupTransaction(transaction)
            return
        }

        let stagingRoot = URL(
            fileURLWithPath: transaction.stagingRoot
        ).standardizedFileURL
        guard UpdateAtomicFilesystem.isDescendant(stagingRoot, of: installRoot) else {
            throw StoreError.corruptTransaction("staging path escapes install root")
        }

        if try stagingContainsTarget(
            stagingRoot,
            target: transaction.target,
            layout: transaction.layout
        ) {
            try installFromStaging(stagingRoot, layout: transaction.layout)
            guard try liveMatches(transaction.target, layout: transaction.layout) else {
                throw StoreError.interruptedRecoveryFailed(
                    "target hashes do not match after replay")
            }
            try ensureCanonicalLinks()
            try finalizeRecovered(transaction, state: &state, now: now)
            cleanupTransaction(transaction)
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
        guard try liveMatches(predecessor.release, layout: predecessor.layout) else {
            throw StoreError.interruptedRecoveryFailed(
                "predecessor hashes do not match after restore")
        }
        if transaction.kind == .install {
            state.candidate = nil
            state.current = predecessor.release
        } else {
            state.completeRollback(
                now: now,
                reason: "recovered an interrupted rollback of \(transaction.target.version)"
            )
        }
        try writeState(state)
        cleanupTransaction(transaction)
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

        let layout: VerifiedPredecessor.Layout =
            staged.extractedApp == nil ? .flat : .app
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
            layout: layout,
            stagingRoot: staged.stagingRoot.standardizedFileURL.path,
            createdAt: now
        )
        try persist(transaction)
        try faultInjector(.transactionPersisted)

        try installStagedBundle(staged)
        transaction.phase = .liveReplaced
        try persist(transaction)
        try faultInjector(.liveLayoutReplaced)

        state.installCandidate(candidate, predecessor: predecessor, now: now)
        try writeState(state)
        try faultInjector(.statePersisted)
        finish(remove: staged.stagingRoot)
    }

    func rollback(now: Double, reason: String) throws -> String {
        try recoverInterruptedTransaction(now: now)
        var state = try loadState()
        guard let candidate = state.candidate else {
            throw StoreError.missingPredecessor(
                "there is no pending release candidate to roll back")
        }
        guard let predecessor = state.predecessor else {
            throw StoreError.missingPredecessor(
                "v\(candidate.release.version) has no recorded predecessor")
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
            createdAt: now
        )
        try persist(transaction)
        try faultInjector(.transactionPersisted)

        try installFromStaging(stagingRoot, layout: predecessor.layout)
        try ensureCanonicalLinks()
        transaction.phase = .liveReplaced
        try persist(transaction)
        try faultInjector(.liveLayoutReplaced)

        state.installGeneration = rollbackGeneration
        state.completeRollback(now: now, reason: reason)
        try writeState(state)
        try faultInjector(.statePersisted)
        finish(remove: stagingRoot)
        return predecessor.release.version
    }

    func verifyPredecessor(_ predecessor: VerifiedPredecessor) throws {
        let bundle = try resolvedRecoveryPath(predecessor.bundlePath)
        let binary = try resolvedRecoveryPath(predecessor.binaryPath)
        let metallib = try resolvedRecoveryPath(predecessor.metallibPath)
        guard fm.fileExists(atPath: bundle.path),
              fm.fileExists(atPath: binary.path),
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
            let metallibHash = try UpdateAtomicFilesystem.sha256(file: metallib)
            guard metallibHash == predecessor.release.metallibHash else {
                throw StoreError.predecessorVerificationFailed(
                    "metallib hash mismatch (expected \(predecessor.release.metallibHash), got \(metallibHash))")
            }
            try verifySignature(
                layout: predecessor.layout,
                bundle: bundle,
                binary: binary
            )
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
        if state.candidate != nil {
            guard let predecessor = state.predecessor else {
                throw StoreError.missingPredecessor(
                    "an unproven installed candidate exists without rollback material")
            }
            try verifyPredecessor(predecessor)
            return predecessor
        }

        let predecessor = try snapshotLiveAsPredecessor(
            version: state.current?.version ?? currentVersion,
            releaseBundleHash: state.current?.releaseBundleHash,
            installGeneration: state.current?.installGeneration
                ?? state.installGeneration,
            now: now
        )
        state.predecessor = predecessor
        if state.current == nil {
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
            let (generation, overflow) =
                state.installGeneration.addingReportingOverflow(1)
            guard !overflow else {
                throw StoreError.corruptState("install generation overflow")
            }
            state.installGeneration = generation
            state.completeRollback(
                now: now,
                reason: "recovered rollback after \(state.candidate?.failureCount ?? 0) failed starts"
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

    private func finish(remove staging: URL) {
        try? fm.removeItem(at: transactionPath)
        try? fm.removeItem(at: staging)
        cleanupOrphanedRecoveryTemps()
    }

    private func cleanupTransaction(_ transaction: Transaction) {
        try? fm.removeItem(at: transactionPath)
        let staging = URL(
            fileURLWithPath: transaction.stagingRoot
        ).standardizedFileURL
        if UpdateAtomicFilesystem.isDescendant(staging, of: installRoot) {
            try? fm.removeItem(at: staging)
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
        where entry.lastPathComponent.hasPrefix(".predecessor-next-") {
            try? fm.removeItem(at: entry)
        }
    }
}
