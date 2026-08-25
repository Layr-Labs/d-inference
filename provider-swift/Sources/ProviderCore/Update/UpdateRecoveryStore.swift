import Foundation

/// Journal and state authority for update commit, interrupted-transaction
/// recovery, and rollback. Concrete install-layout operations live in
/// `UpdateInstallLayout`; callers must hold `UpdateProcessLock`.
final class UpdateRecoveryStore: @unchecked Sendable {
    private static let rollbackStagingPrefix = ".rollback-staging-"
    private static let recoveryRestorePrefix = ".recovery-restore-"

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
        static let currentSchema = 2

        var schema: Int
        var kind: TransactionKind
        var phase: TransactionPhase
        var target: InstalledReleaseRecord
        var layout: VerifiedPredecessor.Layout
        var stagingRoot: String
        var createdAt: Double
        var resultingInstallGeneration: UInt64?

        enum CodingKeys: String, CodingKey {
            case schema
            case kind
            case phase
            case target
            case layout
            case stagingRoot = "staging_root"
            case createdAt = "created_at"
            case resultingInstallGeneration = "resulting_install_generation"
        }
    }

    let installRoot: URL
    let recoveryRoot: URL
    let lockPath: URL
    let verifyCodeSignatures: Bool
    let faultInjector: @Sendable (FaultPoint) throws -> Void
    let recoveryReplayHook: @Sendable () throws -> Void
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
        faultInjector: @escaping @Sendable (FaultPoint) throws -> Void = { _ in },
        recoveryReplayHook: @escaping @Sendable () throws -> Void = {}
    ) {
        self.installRoot = installRoot.standardizedFileURL
        self.recoveryRoot = installRoot
            .appendingPathComponent("recovery", isDirectory: true)
            .standardizedFileURL
        self.lockPath = recoveryRoot.appendingPathComponent("update.lock")
        self.verifyCodeSignatures = verifyCodeSignatures
        self.faultInjector = faultInjector
        self.recoveryReplayHook = recoveryReplayHook
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
        // Validate every journal-owned mutation path before the live-target
        // fast path can finalize state or retire the journal.
        let stagingRoot = try validatedStagingRoot(for: transaction)
        var state = try loadState()

        if try liveMatches(transaction.target, layout: transaction.layout) {
            try stagingRoot.assertUnchanged()
            try ensureCanonicalLinks(layout: transaction.layout)
            guard try liveMatches(
                transaction.target,
                layout: transaction.layout
            ) else {
                throw StoreError.interruptedRecoveryFailed(
                    "target changed while repairing canonical links")
            }
            try finalizeRecovered(transaction, state: &state, now: now)
            try cleanupTransaction(transaction, stagingRoot: stagingRoot)
            return
        }

        if let stagedTarget = try matchingLayoutSnapshot(
            stagingRoot.url,
            target: transaction.target,
            layout: transaction.layout,
            context: "journal staging",
            verifySignature: false
        ) {
            guard stagedTarget.root.identity == stagingRoot.identity else {
                throw StoreError.corruptTransaction(
                    "journal staging root was replaced before payload verification")
            }
            try stagingRoot.assertUnchanged()
            try recoveryReplayHook()
            try installFromStaging(
                stagingRoot.url,
                layout: transaction.layout,
                validatedSource: stagedTarget
            )
            guard try liveMatches(transaction.target, layout: transaction.layout) else {
                throw StoreError.interruptedRecoveryFailed(
                    "target hashes do not match after replay")
            }
            try ensureCanonicalLinks(layout: transaction.layout)
            guard try liveMatches(
                transaction.target,
                layout: transaction.layout
            ) else {
                throw StoreError.interruptedRecoveryFailed(
                    "target changed while repairing canonical links")
            }
            try finalizeRecovered(transaction, state: &state, now: now)
            try cleanupTransaction(transaction, stagingRoot: stagingRoot)
            return
        }

        try stagingRoot.assertUnchanged()
        guard let predecessor = state.predecessor else {
            throw StoreError.interruptedRecoveryFailed(
                "neither target staging nor a predecessor is available; live install left untouched")
        }
        try verifyPredecessor(predecessor)
        try restorePredecessorCopy(
            predecessor,
            stagingName: "\(Self.recoveryRestorePrefix)\(UUID().uuidString)"
        )
        guard try liveMatches(predecessor.release, layout: predecessor.layout) else {
            throw StoreError.interruptedRecoveryFailed(
                "predecessor hashes do not match after restore")
        }
        if transaction.kind == .install {
            state.candidate = nil
            state.current = predecessor.release
            try writeState(state)
        } else {
            try finalizeRecovered(transaction, state: &state, now: now)
        }
        try cleanupTransaction(transaction, stagingRoot: stagingRoot)
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
            schema: Transaction.currentSchema,
            kind: .install,
            phase: .prepared,
            target: candidate,
            layout: layout,
            stagingRoot: staged.stagingRoot.standardizedFileURL.path,
            createdAt: now,
            resultingInstallGeneration: candidate.installGeneration
        )
        try persist(transaction)
        try faultInjector(.transactionPersisted)

        guard let stagedTarget = try matchingLayoutSnapshot(
            staged.stagingRoot,
            target: candidate,
            layout: layout,
            context: "prepared install staging",
            verifySignature: false
        ) else {
            throw StoreError.corruptTransaction(
                "prepared install staging no longer matches its journal target")
        }
        try installStagedBundle(staged, validatedSource: stagedTarget)
        guard try liveMatches(candidate, layout: layout) else {
            throw StoreError.filesystem(
                "installed candidate does not match its verified payload"
            )
        }
        try ensureCanonicalLinks(layout: layout)
        guard try liveMatches(candidate, layout: layout) else {
            throw StoreError.filesystem(
                "installed candidate changed while repairing canonical links"
            )
        }
        try faultInjector(.liveLayoutExchanged)
        transaction.phase = .liveReplaced
        try persist(transaction)
        try faultInjector(.liveLayoutReplaced)

        state.installCandidate(candidate, predecessor: predecessor, now: now)
        try writeState(state)
        try faultInjector(.statePersisted)
        try finish(remove: staged.stagingRoot)
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
            "\(Self.rollbackStagingPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try copyPredecessor(predecessor, to: stagingRoot)
        let stagedPredecessor = try verifyStagedPredecessor(
            predecessor,
            at: stagingRoot
        )

        var transaction = Transaction(
            schema: Transaction.currentSchema,
            kind: .rollback,
            phase: .prepared,
            target: predecessor.release,
            layout: predecessor.layout,
            stagingRoot: stagingRoot.path,
            createdAt: now,
            resultingInstallGeneration: rollbackGeneration
        )
        try persist(transaction)
        try faultInjector(.transactionPersisted)

        try installFromStaging(
            stagingRoot,
            layout: predecessor.layout,
            validatedSource: stagedPredecessor
        )
        guard try liveMatches(
            predecessor.release,
            layout: predecessor.layout
        ) else {
            throw StoreError.predecessorVerificationFailed(
                "restored predecessor does not match its verified payload"
            )
        }
        try ensureCanonicalLinks(layout: predecessor.layout)
        guard try liveMatches(
            predecessor.release,
            layout: predecessor.layout
        ) else {
            throw StoreError.predecessorVerificationFailed(
                "restored predecessor changed while repairing canonical links"
            )
        }
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
            let modes = try UpdateArtifactModes(
                binary: binary,
                enclave: enclave,
                metallib: metallib
            )
            if let payload = modes.nonExecutablePayload {
                throw StoreError.predecessorVerificationFailed(
                    "recorded payload \(payload) is not executable"
                )
            }
            guard modes.matches(predecessor.release) else {
                throw StoreError.predecessorVerificationFailed(
                    "recorded payload permission mismatch"
                )
            }
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
            let generation = try recoveredRollbackGeneration(
                transaction,
                state: state
            )
            if state.candidate != nil {
                state.installGeneration = generation
                state.completeRollback(
                    now: now,
                    reason: "recovered rollback after \(state.candidate?.failureCount ?? 0) failed starts"
                )
            }
        }
        try writeState(state)
        try faultInjector(.statePersisted)
    }

    private func recoveredRollbackGeneration(
        _ transaction: Transaction,
        state: UpdateRecoveryState
    ) throws -> UInt64 {
        if let recorded = transaction.resultingInstallGeneration {
            if state.candidate == nil {
                guard rollbackIsAlreadyFinalized(transaction, state: state),
                      state.installGeneration == recorded
                else {
                    throw StoreError.interruptedRecoveryFailed(
                        "rollback state does not match its recorded install generation")
                }
                return recorded
            }
            let (expected, overflow) =
                state.installGeneration.addingReportingOverflow(1)
            guard !overflow else {
                throw StoreError.corruptState("install generation overflow")
            }
            guard recorded == expected else {
                throw StoreError.corruptTransaction(
                    "rollback install generation \(recorded) does not follow \(state.installGeneration)")
            }
            return recorded
        }

        // Schema-1 rollback journals did not record the resulting generation.
        // If their state transition is already durable, retain that generation;
        // otherwise derive it once from the still-pending candidate state.
        if rollbackIsAlreadyFinalized(transaction, state: state) {
            return state.installGeneration
        }
        guard state.candidate != nil else {
            throw StoreError.interruptedRecoveryFailed(
                "legacy rollback journal has neither pending nor completed state")
        }
        let (generation, overflow) =
            state.installGeneration.addingReportingOverflow(1)
        guard !overflow else {
            throw StoreError.corruptState("install generation overflow")
        }
        return generation
    }

    private func rollbackIsAlreadyFinalized(
        _ transaction: Transaction,
        state: UpdateRecoveryState
    ) -> Bool {
        state.candidate == nil
            && state.current == transaction.target
            && state.predecessor?.release == transaction.target
            && state.quarantine != nil
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
        guard transaction.schema == 1
                || transaction.schema == Transaction.currentSchema
        else {
            throw StoreError.corruptTransaction(
                "unsupported schema \(transaction.schema)")
        }
        if transaction.schema == 1 {
            guard transaction.resultingInstallGeneration == nil else {
                throw StoreError.corruptTransaction(
                    "schema 1 unexpectedly records a resulting install generation")
            }
        } else {
            guard let generation = transaction.resultingInstallGeneration else {
                throw StoreError.corruptTransaction(
                    "schema \(Transaction.currentSchema) is missing its resulting install generation")
            }
            if transaction.kind == .install,
               generation != transaction.target.installGeneration {
                throw StoreError.corruptTransaction(
                    "install transaction generation does not match its target")
            }
        }
        return transaction
    }

    private func validatedStagingRoot(
        for transaction: Transaction
    ) throws -> RecoveryNodeSnapshot {
        let expectedPrefix = transaction.kind == .install
            ? SelfUpdater.stagingDirPrefix
            : Self.rollbackStagingPrefix
        return try validatedJournalStagingRoot(
            path: transaction.stagingRoot,
            expectedPrefix: expectedPrefix
        )
    }

    private func persist(_ transaction: Transaction) throws {
        try UpdateAtomicFilesystem.writeJSON(transaction, to: transactionPath)
    }

    private func finish(remove staging: URL) throws {
        let stagingRoot = try recoveryNodeSnapshot(
            at: staging,
            label: "completed transaction staging root"
        )
        if let identity = stagingRoot.identity {
            guard identity.kind == .directory else {
                throw StoreError.corruptTransaction(
                    "completed transaction staging root changed node type")
            }
            try stagingRoot.assertUnchanged()
            try UpdateAtomicFilesystem.removeDurably(
                staging,
                expectedIdentity: identity
            )
        }
        try UpdateAtomicFilesystem.removeDurably(transactionPath)
        try faultInjector(.transactionRemoved)
        cleanupOrphanedRecoveryTemps()
    }

    private func cleanupTransaction(
        _ transaction: Transaction,
        stagingRoot: RecoveryNodeSnapshot
    ) throws {
        let current = try validatedStagingRoot(for: transaction)
        guard current.identity == stagingRoot.identity else {
            throw StoreError.corruptTransaction(
                "journal staging root was replaced during recovery")
        }
        try current.assertUnchanged()
        if let identity = current.identity {
            try UpdateAtomicFilesystem.removeDurably(
                current.url,
                expectedIdentity: identity
            )
        }
        try UpdateAtomicFilesystem.removeDurably(transactionPath)
        try faultInjector(.transactionRemoved)
        cleanupOrphanedRecoveryTemps()
    }

    private func cleanupOrphanedRecoveryTemps() {
        if let recoveryEntries = try? fm.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: nil
        ) {
            for entry in recoveryEntries
            where entry.lastPathComponent.hasPrefix(".predecessor-next-") {
                try? fm.removeItem(at: entry)
            }
        }
        if let installEntries = try? fm.contentsOfDirectory(
            at: installRoot,
            includingPropertiesForKeys: nil
        ) {
            for entry in installEntries
            where entry.lastPathComponent.hasPrefix(Self.rollbackStagingPrefix)
                || entry.lastPathComponent.hasPrefix(Self.recoveryRestorePrefix)
                || entry.lastPathComponent.hasPrefix(Self.staleAppAsidePrefix)
            {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
