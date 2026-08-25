import Foundation
import ProviderCoreFoundation

/// Crash- and power-loss-durable publication of a verified app bundle and its
/// canonical bin directory.
///
/// Callers must hold `InstallMutationLock.acquireForOneShotInstall` for every
/// operation. The fixed journal is deliberately visible to the CLI updater and
/// shell installer so neither can mutate the install while this transaction
/// needs recovery.
struct AppRelocationTransaction {
    enum FaultPoint: String, CaseIterable {
        case journalPersisted
        case appLiveStateMutated
        case appLiveStateRecorded
        case binLiveStateMutated
        case binLiveStateRecorded
        case appPreviousStateMoved
        case appPreviousStateRecorded
        case binPreviousStateMoved
        case binPreviousStateRecorded
        case ownedAppPreviousRetired
        case appPreviousRetirementRecorded
        case binPreviousRetired
        case binPreviousRetirementRecorded
        case appRemovalAuthorized
        case appPreviousRemoved
        case appRemovalRecorded
        case binRemovalAuthorized
        case binPreviousRemoved
        case binRemovalRecorded
        case journalRemoved
    }

    enum PreviousKind: String, Codable {
        case absent
        case owned
        case foreign
    }

    struct RecoveryResult: Equatable {
        let preservedForeignApp: URL?
    }

    enum TransactionError: Error, LocalizedError {
        case pendingTransaction(path: String)
        case corruptJournal(path: String, reason: String)
        case ambiguousRecovery(path: String, reason: String)
        case invalidStaging(path: String)
        case filesystem(operation: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .pendingTransaction(let path):
                "An app relocation transaction already needs recovery at \(path)."
            case .corruptJournal(let path, let reason):
                "The app relocation journal at \(path) is invalid: \(reason)"
            case .ambiguousRecovery(let path, let reason):
                "The app relocation transaction at \(path) cannot be recovered "
                    + "without risking user data: \(reason)"
            case .invalidStaging(let path):
                "A verified relocation staging path is outside the managed "
                    + "transaction namespace: \(path)"
            case .filesystem(let operation, let reason):
                "The app relocation transaction could not \(operation): \(reason)"
            }
        }
    }

    private enum Phase: String, Codable {
        case prepared
        case appLiveInstalled = "app_live_installed"
        case binLiveInstalled = "bin_live_installed"
        case appPreviousResolved = "app_previous_resolved"
        case binPreviousResolved = "bin_previous_resolved"
        case appPreviousRetired = "app_previous_retired"
        case binPreviousRetired = "bin_previous_retired"
        case appRemovalAuthorized = "app_removal_authorized"
        case appRemoved = "app_removed"
        case binRemovalAuthorized = "bin_removal_authorized"
        case binRemoved = "bin_removed"
    }

    private struct Journal: Codable {
        let schema: Int
        let transactionID: String
        var phase: Phase
        let appCandidate: AppRelocationArtifactState
        let binCandidate: AppRelocationArtifactState
        let previousAppKind: PreviousKind
        let previousApp: AppRelocationArtifactState?
        let previousBin: AppRelocationArtifactState?

        enum CodingKeys: String, CodingKey {
            case schema
            case transactionID = "transaction_id"
            case phase
            case appCandidate = "app_candidate"
            case binCandidate = "bin_candidate"
            case previousAppKind = "previous_app_kind"
            case previousApp = "previous_app"
            case previousBin = "previous_bin"
        }
    }

    private static let schema = 2
    private static let appStagingPrefix = ".Darkbloom.app.relocation-"
    private static let appPreviousPrefix = ".Darkbloom.app.previous-"
    private static let appGarbagePrefix = ".Darkbloom.app.garbage-"
    private static let foreignAppPrefix = "Darkbloom.app.foreign-"
    private static let binPreviousPrefix = ".bin.previous-"
    private static let binGarbagePrefix = ".bin.garbage-"
    private static let journalTemporaryPrefix =
        ".\(InstallMutationLock.appRelocationTransactionFileName).tmp-"
    private static let maximumJournalBytes = 64 * 1024

    private let installRoot: URL
    private let appDestinationURL: URL
    private let binDestinationURL: URL
    private let fileManager: FileManager
    private let faultInjector: (FaultPoint) throws -> Void

    init(
        installRoot: URL,
        fileManager: FileManager = .default,
        faultInjector: @escaping (FaultPoint) throws -> Void = { _ in }
    ) {
        self.installRoot = installRoot.standardizedFileURL
        appDestinationURL = installRoot
            .appendingPathComponent("Darkbloom.app", isDirectory: true)
            .standardizedFileURL
        binDestinationURL = installRoot
            .appendingPathComponent("bin", isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    static func hasPendingTransaction(
        in installRoot: URL,
        fileManager _: FileManager = .default
    ) -> Bool {
        AppRelocationFilesystem.itemExists(
            InstallMutationLock.appRelocationTransactionURL(in: installRoot)
        )
    }

    /// Complete the single recorded transaction, or return nil when there is
    /// no journal. Every accepted endpoint is identified by both inode identity
    /// and a complete content hash; all other combinations fail closed.
    func recover() throws -> RecoveryResult? {
        guard Self.hasPendingTransaction(
            in: installRoot,
            fileManager: fileManager
        ) else {
            return nil
        }
        var journal = try readJournal()
        return try complete(&journal)
    }

    /// Remove only unjournaled candidates from this helper's strict UUID
    /// namespaces. Predecessor, foreign, and garbage paths are intentionally
    /// excluded: deleting one without its authentic journal could destroy the
    /// only copy of user data.
    func cleanupUnjournaledArtifacts() throws {
        guard !Self.hasPendingTransaction(
            in: installRoot,
            fileManager: fileManager
        ) else {
            throw TransactionError.pendingTransaction(path: journalURL.path)
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: installRoot,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw TransactionError.filesystem(
                operation: "inspect app relocation artifacts",
                reason: error.localizedDescription
            )
        }

        for entry in entries {
            let name = entry.lastPathComponent
            let suffix: String?
            if name.hasPrefix(Self.appStagingPrefix) {
                suffix = String(name.dropFirst(Self.appStagingPrefix.count))
            } else if name.hasPrefix(AppRelocationBinLayout.candidatePrefix) {
                suffix = String(
                    name.dropFirst(AppRelocationBinLayout.candidatePrefix.count)
                )
            } else if name.hasPrefix(Self.journalTemporaryPrefix) {
                suffix = String(name.dropFirst(Self.journalTemporaryPrefix.count))
            } else {
                suffix = nil
            }
            guard let suffix, Self.isCanonicalTransactionID(suffix) else {
                continue
            }
            try AppRelocationFilesystem.removeDurably(entry)
        }
    }

    /// Publish both candidates as one forward-recoverable installation.
    /// Ownership of both staging paths transfers to the transaction once the
    /// journal has been durably published.
    func install(
        appStagingURL: URL,
        binStagingURL: URL,
        previousAppKind: PreviousKind,
        expectedPreviousBin: AppRelocationArtifactState?
    ) throws -> RecoveryResult {
        guard !Self.hasPendingTransaction(
            in: installRoot,
            fileManager: fileManager
        ) else {
            throw TransactionError.pendingTransaction(path: journalURL.path)
        }

        let appStaging = appStagingURL.standardizedFileURL
        guard appStaging.deletingLastPathComponent() == installRoot,
              appStaging.lastPathComponent.hasPrefix(Self.appStagingPrefix)
        else {
            throw TransactionError.invalidStaging(path: appStaging.path)
        }
        let transactionID = String(
            appStaging.lastPathComponent.dropFirst(Self.appStagingPrefix.count)
        )
        guard Self.isCanonicalTransactionID(transactionID) else {
            throw TransactionError.invalidStaging(path: appStaging.path)
        }
        let binStaging = binStagingURL.standardizedFileURL
        guard binStaging == self.binStagingURL(transactionID: transactionID) else {
            throw TransactionError.invalidStaging(path: binStaging.path)
        }
        guard try AppRelocationFilesystem.pathKind(at: appStaging) == .directory,
              try AppRelocationFilesystem.pathKind(at: binStaging) == .directory
        else {
            throw TransactionError.invalidStaging(
                path: "\(appStaging.path), \(binStaging.path)"
            )
        }

        let appCandidate = try AppRelocationFilesystem.synchronizedState(
            at: appStaging
        )
        let binCandidate = try AppRelocationFilesystem.synchronizedState(
            at: binStaging
        )
        let previousApp = try AppRelocationFilesystem.synchronizedOptionalState(
            at: appDestinationURL
        )
        switch previousAppKind {
        case .absent:
            guard previousApp == nil else {
                throw ambiguous(
                    "app destination appeared after ownership classification"
                )
            }
        case .owned, .foreign:
            guard previousApp != nil else {
                throw ambiguous(
                    "app destination disappeared after ownership classification"
                )
            }
        }

        let previousBinKind = try AppRelocationFilesystem.pathKind(
            at: binDestinationURL
        )
        guard previousBinKind == nil || previousBinKind == .directory else {
            throw ambiguous("live bin path is not a real directory")
        }
        let previousBin = try AppRelocationFilesystem.synchronizedOptionalState(
            at: binDestinationURL
        )
        guard previousBin == expectedPreviousBin else {
            throw ambiguous(
                "live bin directory changed after its canonical candidate was copied"
            )
        }

        let journal = Journal(
            schema: Self.schema,
            transactionID: transactionID,
            phase: .prepared,
            appCandidate: appCandidate,
            binCandidate: binCandidate,
            previousAppKind: previousAppKind,
            previousApp: previousApp,
            previousBin: previousBin
        )
        try validate(journal)
        try ensureInitialAuxiliaryPathsAreAvailable(for: journal)
        try persist(journal)
        try faultInjector(.journalPersisted)

        var mutableJournal = journal
        return try complete(&mutableJournal)
    }

    private var journalURL: URL {
        InstallMutationLock.appRelocationTransactionURL(in: installRoot)
    }

    private func appStagingURL(for journal: Journal) -> URL {
        installRoot.appendingPathComponent(
            "\(Self.appStagingPrefix)\(journal.transactionID)",
            isDirectory: true
        )
    }

    private func binStagingURL(for journal: Journal) -> URL {
        binStagingURL(transactionID: journal.transactionID)
    }

    private func binStagingURL(transactionID: String) -> URL {
        installRoot.appendingPathComponent(
            "\(AppRelocationBinLayout.candidatePrefix)\(transactionID)",
            isDirectory: true
        ).standardizedFileURL
    }

    private func appPreviousURL(for journal: Journal) -> URL {
        installRoot.appendingPathComponent(
            "\(Self.appPreviousPrefix)\(journal.transactionID)",
            isDirectory: true
        )
    }

    private func appGarbageURL(for journal: Journal) -> URL {
        installRoot.appendingPathComponent(
            "\(Self.appGarbagePrefix)\(journal.transactionID)",
            isDirectory: true
        )
    }

    private func foreignAppURL(for journal: Journal) -> URL {
        installRoot.appendingPathComponent(
            "\(Self.foreignAppPrefix)\(journal.transactionID)",
            isDirectory: true
        )
    }

    private func binPreviousURL(for journal: Journal) -> URL {
        installRoot.appendingPathComponent(
            "\(Self.binPreviousPrefix)\(journal.transactionID)",
            isDirectory: true
        )
    }

    private func binGarbageURL(for journal: Journal) -> URL {
        installRoot.appendingPathComponent(
            "\(Self.binGarbagePrefix)\(journal.transactionID)",
            isDirectory: true
        )
    }

    private func complete(_ journal: inout Journal) throws -> RecoveryResult {
        while true {
            try validate(journal)
            switch journal.phase {
            case .prepared:
                try installLiveApp(journal)
                journal.phase = .appLiveInstalled
                try persist(journal)
                try faultInjector(.appLiveStateRecorded)
            case .appLiveInstalled:
                try installLiveBin(journal)
                journal.phase = .binLiveInstalled
                try persist(journal)
                try faultInjector(.binLiveStateRecorded)
            case .binLiveInstalled:
                try resolvePreviousApp(journal)
                journal.phase = .appPreviousResolved
                try persist(journal)
                try faultInjector(.appPreviousStateRecorded)
            case .appPreviousResolved:
                try resolvePreviousBin(journal)
                journal.phase = .binPreviousResolved
                try persist(journal)
                try faultInjector(.binPreviousStateRecorded)
            case .binPreviousResolved:
                try retirePreviousApp(journal)
                journal.phase = .appPreviousRetired
                try persist(journal)
                try faultInjector(.appPreviousRetirementRecorded)
            case .appPreviousRetired:
                try retirePreviousBin(journal)
                journal.phase = .binPreviousRetired
                try persist(journal)
                try faultInjector(.binPreviousRetirementRecorded)
            case .binPreviousRetired:
                try authorizePreviousAppRemoval(journal)
                journal.phase = .appRemovalAuthorized
                try persist(journal)
                try faultInjector(.appRemovalAuthorized)
            case .appRemovalAuthorized:
                try removePreviousApp(journal)
                try faultInjector(.appPreviousRemoved)
                journal.phase = .appRemoved
                try persist(journal)
                try faultInjector(.appRemovalRecorded)
            case .appRemoved:
                try authorizePreviousBinRemoval(journal)
                journal.phase = .binRemovalAuthorized
                try persist(journal)
                try faultInjector(.binRemovalAuthorized)
            case .binRemovalAuthorized:
                try removePreviousBin(journal)
                try faultInjector(.binPreviousRemoved)
                journal.phase = .binRemoved
                try persist(journal)
                try faultInjector(.binRemovalRecorded)
            case .binRemoved:
                let result = try finish(journal)
                try AppRelocationFilesystem.removeDurably(journalURL)
                try faultInjector(.journalRemoved)
                return result
            }
        }
    }

    private func installLiveApp(_ journal: Journal) throws {
        let staging = appStagingURL(for: journal)
        let destination = try AppRelocationFilesystem.optionalState(
            at: appDestinationURL
        )
        let staged = try AppRelocationFilesystem.optionalState(at: staging)

        switch journal.previousAppKind {
        case .absent:
            guard journal.previousApp == nil else {
                throw corrupt("absent app predecessor carries a recorded state")
            }
            if staged == journal.appCandidate, destination == nil {
                try AppRelocationFilesystem.renameExclusive(
                    staging,
                    to: appDestinationURL
                )
                try faultInjector(.appLiveStateMutated)
            } else if staged == nil, destination == journal.appCandidate {
                // The rename reached disk before the phase journal did.
            } else {
                throw ambiguous(
                    "fresh app install is neither wholly staged nor wholly live"
                )
            }
        case .owned, .foreign:
            guard let previous = journal.previousApp else {
                throw corrupt("existing app predecessor has no recorded state")
            }
            if staged == journal.appCandidate, destination == previous {
                try AppRelocationFilesystem.exchange(staging, appDestinationURL)
                try faultInjector(.appLiveStateMutated)
            } else if staged == previous, destination == journal.appCandidate {
                // The exchange reached disk before the phase journal did.
            } else {
                throw ambiguous(
                    "app endpoints do not match either side of the recorded exchange"
                )
            }
        }
    }

    private func installLiveBin(_ journal: Journal) throws {
        guard try AppRelocationFilesystem.optionalState(at: appDestinationURL)
                == journal.appCandidate
        else {
            throw ambiguous("live app no longer matches the candidate")
        }
        let staging = binStagingURL(for: journal)
        let destination = try AppRelocationFilesystem.optionalState(
            at: binDestinationURL
        )
        let staged = try AppRelocationFilesystem.optionalState(at: staging)

        if let previous = journal.previousBin {
            if staged == journal.binCandidate, destination == previous {
                try AppRelocationFilesystem.exchange(staging, binDestinationURL)
                try faultInjector(.binLiveStateMutated)
            } else if staged == previous, destination == journal.binCandidate {
                // The exchange reached disk before the phase journal did.
            } else {
                throw ambiguous(
                    "bin endpoints do not match either side of the recorded exchange"
                )
            }
        } else if staged == journal.binCandidate, destination == nil {
            try AppRelocationFilesystem.renameExclusive(
                staging,
                to: binDestinationURL
            )
            try faultInjector(.binLiveStateMutated)
        } else if staged == nil, destination == journal.binCandidate {
            // The rename reached disk before the phase journal did.
        } else {
            throw ambiguous(
                "fresh bin install is neither wholly staged nor wholly live"
            )
        }
    }

    private func resolvePreviousApp(_ journal: Journal) throws {
        try verifyLiveCandidates(journal, requireBin: true)
        let staging = appStagingURL(for: journal)
        switch journal.previousAppKind {
        case .absent:
            guard journal.previousApp == nil,
                  try AppRelocationFilesystem.optionalState(at: staging) == nil
            else {
                throw ambiguous("fresh app install unexpectedly has a predecessor")
            }
        case .owned:
            guard let previous = journal.previousApp else {
                throw corrupt("owned app predecessor has no recorded state")
            }
            try resolve(
                state: previous,
                from: staging,
                to: appPreviousURL(for: journal),
                description: "owned app predecessor",
                faultPoint: .appPreviousStateMoved
            )
        case .foreign:
            guard let previous = journal.previousApp else {
                throw corrupt("foreign app predecessor has no recorded state")
            }
            try resolve(
                state: previous,
                from: staging,
                to: foreignAppURL(for: journal),
                description: "foreign app predecessor",
                faultPoint: .appPreviousStateMoved
            )
        }
    }

    private func resolvePreviousBin(_ journal: Journal) throws {
        try verifyLiveCandidates(journal, requireBin: true)
        let staging = binStagingURL(for: journal)
        guard let previous = journal.previousBin else {
            guard try AppRelocationFilesystem.optionalState(at: staging) == nil else {
                throw ambiguous("fresh bin install unexpectedly has a predecessor")
            }
            return
        }
        try resolve(
            state: previous,
            from: staging,
            to: binPreviousURL(for: journal),
            description: "bin predecessor",
            faultPoint: .binPreviousStateMoved
        )
    }

    private func resolve(
        state: AppRelocationArtifactState,
        from source: URL,
        to destination: URL,
        description: String,
        faultPoint: FaultPoint
    ) throws {
        let sourceState = try AppRelocationFilesystem.optionalState(at: source)
        let destinationState = try AppRelocationFilesystem.optionalState(
            at: destination
        )
        if sourceState == state, destinationState == nil {
            try AppRelocationFilesystem.renameExclusive(source, to: destination)
            try faultInjector(faultPoint)
        } else if sourceState == nil, destinationState == state {
            // The rename reached disk before the phase journal did.
        } else {
            throw ambiguous(
                "\(description) is not exactly at its staged or resolved path"
            )
        }
    }

    private func retirePreviousApp(_ journal: Journal) throws {
        try verifyReadyToRetireApp(journal)
        let retired = appPreviousURL(for: journal)
        let garbage = appGarbageURL(for: journal)
        switch journal.previousAppKind {
        case .owned:
            guard let previous = journal.previousApp else {
                throw corrupt("owned app predecessor has no recorded state")
            }
            try retire(
                state: previous,
                from: retired,
                to: garbage,
                description: "owned app predecessor",
                faultPoint: .ownedAppPreviousRetired
            )
        case .absent, .foreign:
            guard try AppRelocationFilesystem.optionalState(at: retired) == nil,
                  try AppRelocationFilesystem.optionalState(at: garbage) == nil
            else {
                throw ambiguous(
                    "non-owned app predecessor appeared in the cleanup namespace"
                )
            }
        }
    }

    private func retirePreviousBin(_ journal: Journal) throws {
        try verifyRetiredApp(journal)
        let retired = binPreviousURL(for: journal)
        let garbage = binGarbageURL(for: journal)
        guard let previous = journal.previousBin else {
            guard try AppRelocationFilesystem.optionalState(at: retired) == nil,
                  try AppRelocationFilesystem.optionalState(at: garbage) == nil
            else {
                throw ambiguous(
                    "fresh bin install has content in the cleanup namespace"
                )
            }
            return
        }
        try retire(
            state: previous,
            from: retired,
            to: garbage,
            description: "bin predecessor",
            faultPoint: .binPreviousRetired
        )
    }

    private func retire(
        state: AppRelocationArtifactState,
        from source: URL,
        to garbage: URL,
        description: String,
        faultPoint: FaultPoint
    ) throws {
        let sourceState = try AppRelocationFilesystem.optionalState(at: source)
        let garbageState = try AppRelocationFilesystem.optionalState(at: garbage)
        if sourceState == state, garbageState == nil {
            try AppRelocationFilesystem.renameExclusive(source, to: garbage)
            try faultInjector(faultPoint)
        } else if sourceState == nil, garbageState == state {
            // The retirement rename reached disk before the phase journal did.
        } else {
            throw ambiguous(
                "\(description) is not exactly at its resolved or garbage path"
            )
        }
    }

    private func authorizePreviousAppRemoval(_ journal: Journal) throws {
        try verifyRetiredBin(journal)
        switch journal.previousAppKind {
        case .owned:
            guard let previous = journal.previousApp,
                  try AppRelocationFilesystem.optionalState(
                    at: appGarbageURL(for: journal)
                  ) == previous
            else {
                throw ambiguous(
                    "owned app predecessor changed before cleanup authorization"
                )
            }
        case .absent, .foreign:
            guard try AppRelocationFilesystem.optionalState(
                at: appGarbageURL(for: journal)
            ) == nil else {
                throw ambiguous("unexpected app garbage cannot be authorized")
            }
        }
    }

    private func removePreviousApp(_ journal: Journal) throws {
        guard journal.previousAppKind == .owned else { return }
        guard let previous = journal.previousApp else {
            throw corrupt("owned app predecessor has no recorded state")
        }
        try removeAuthorizedGarbage(
            appGarbageURL(for: journal),
            expected: previous,
            description: "owned app predecessor"
        )
    }

    private func authorizePreviousBinRemoval(_ journal: Journal) throws {
        try verifyAppRemoved(journal)
        guard let previous = journal.previousBin else {
            guard try AppRelocationFilesystem.optionalState(
                at: binGarbageURL(for: journal)
            ) == nil else {
                throw ambiguous("unexpected bin garbage cannot be authorized")
            }
            return
        }
        guard try AppRelocationFilesystem.optionalState(
            at: binGarbageURL(for: journal)
        ) == previous else {
            throw ambiguous(
                "bin predecessor changed before cleanup authorization"
            )
        }
    }

    private func removePreviousBin(_ journal: Journal) throws {
        guard let previous = journal.previousBin else { return }
        try removeAuthorizedGarbage(
            binGarbageURL(for: journal),
            expected: previous,
            description: "bin predecessor"
        )
    }

    private func removeAuthorizedGarbage(
        _ garbage: URL,
        expected: AppRelocationArtifactState,
        description: String
    ) throws {
        guard let identity = try AppRelocationFilesystem.optionalIdentity(
            at: garbage
        ) else {
            return
        }
        guard identity == expected.identity else {
            throw ambiguous(
                "\(description) garbage path was replaced after cleanup authorization"
            )
        }
        // The authorization phase is durable before recursive deletion begins.
        // A restart can therefore continue a partial deletion by root identity
        // without accepting a replacement path.
        try AppRelocationFilesystem.removeDurably(garbage)
    }

    private func finish(_ journal: Journal) throws -> RecoveryResult {
        try verifyLiveCandidates(journal, requireBin: true)
        guard try AppRelocationFilesystem.optionalState(
            at: appStagingURL(for: journal)
        ) == nil,
              try AppRelocationFilesystem.optionalState(
                at: binStagingURL(for: journal)
              ) == nil,
              try AppRelocationFilesystem.optionalState(
                at: appPreviousURL(for: journal)
              ) == nil,
              try AppRelocationFilesystem.optionalState(
                at: appGarbageURL(for: journal)
              ) == nil,
              try AppRelocationFilesystem.optionalState(
                at: binPreviousURL(for: journal)
              ) == nil,
              try AppRelocationFilesystem.optionalState(
                at: binGarbageURL(for: journal)
              ) == nil
        else {
            throw ambiguous(
                "transaction-owned staging or predecessor cleanup is incomplete"
            )
        }

        switch journal.previousAppKind {
        case .absent:
            guard journal.previousApp == nil else {
                throw corrupt("absent app predecessor carries a recorded state")
            }
            return RecoveryResult(preservedForeignApp: nil)
        case .owned:
            guard journal.previousApp != nil else {
                throw corrupt("owned app predecessor has no recorded state")
            }
            return RecoveryResult(preservedForeignApp: nil)
        case .foreign:
            guard let previous = journal.previousApp,
                  try AppRelocationFilesystem.optionalState(
                    at: foreignAppURL(for: journal)
                  ) == previous
            else {
                throw ambiguous("preserved foreign app changed or disappeared")
            }
            return RecoveryResult(
                preservedForeignApp: foreignAppURL(for: journal)
            )
        }
    }

    private func verifyLiveCandidates(
        _ journal: Journal,
        requireBin: Bool
    ) throws {
        guard try AppRelocationFilesystem.optionalState(at: appDestinationURL)
                == journal.appCandidate
        else {
            throw ambiguous("live app no longer matches the candidate")
        }
        if requireBin {
            guard try AppRelocationFilesystem.optionalState(at: binDestinationURL)
                    == journal.binCandidate
            else {
                throw ambiguous("live bin no longer matches the candidate")
            }
        }
    }

    private func verifyReadyToRetireApp(_ journal: Journal) throws {
        try verifyLiveCandidates(journal, requireBin: true)
        guard try AppRelocationFilesystem.optionalState(
            at: appStagingURL(for: journal)
        ) == nil,
              try AppRelocationFilesystem.optionalState(
                at: binStagingURL(for: journal)
              ) == nil
        else {
            throw ambiguous("staging remains before predecessor retirement")
        }

        switch journal.previousAppKind {
        case .absent:
            guard journal.previousApp == nil,
                  try AppRelocationFilesystem.optionalState(
                    at: appPreviousURL(for: journal)
                  ) == nil,
                  try AppRelocationFilesystem.optionalState(
                    at: appGarbageURL(for: journal)
                  ) == nil
            else {
                throw ambiguous("fresh app install has an unexpected predecessor")
            }
        case .owned:
            guard let previous = journal.previousApp else {
                throw corrupt("owned app predecessor has no recorded state")
            }
            let resolved = try AppRelocationFilesystem.optionalState(
                at: appPreviousURL(for: journal)
            )
            let garbage = try AppRelocationFilesystem.optionalState(
                at: appGarbageURL(for: journal)
            )
            guard (resolved == previous && garbage == nil)
                    || (resolved == nil && garbage == previous)
            else {
                throw ambiguous(
                    "owned app predecessor is not at a recoverable retirement endpoint"
                )
            }
        case .foreign:
            guard let previous = journal.previousApp,
                  try AppRelocationFilesystem.optionalState(
                    at: foreignAppURL(for: journal)
                  ) == previous
            else {
                throw ambiguous("foreign app predecessor is not preserved")
            }
        }

        if let previous = journal.previousBin {
            guard try AppRelocationFilesystem.optionalState(
                at: binPreviousURL(for: journal)
            ) == previous else {
                throw ambiguous("bin predecessor is not resolved")
            }
        }
    }

    private func verifyRetiredApp(_ journal: Journal) throws {
        try verifyLiveCandidates(journal, requireBin: true)
        switch journal.previousAppKind {
        case .owned:
            guard let previous = journal.previousApp,
                  try AppRelocationFilesystem.optionalState(
                    at: appPreviousURL(for: journal)
                  ) == nil,
                  try AppRelocationFilesystem.optionalState(
                    at: appGarbageURL(for: journal)
                  ) == previous
            else {
                throw ambiguous("owned app predecessor is not retired")
            }
        case .absent:
            guard journal.previousApp == nil else {
                throw corrupt("absent app predecessor carries a recorded state")
            }
        case .foreign:
            guard let previous = journal.previousApp,
                  try AppRelocationFilesystem.optionalState(
                    at: foreignAppURL(for: journal)
                  ) == previous
            else {
                throw ambiguous("foreign app predecessor is not preserved")
            }
        }
    }

    private func verifyRetiredBin(_ journal: Journal) throws {
        try verifyRetiredApp(journal)
        guard try AppRelocationFilesystem.optionalState(
            at: binPreviousURL(for: journal)
        ) == nil else {
            throw ambiguous("bin predecessor remains at its resolved path")
        }
        if let previous = journal.previousBin {
            guard try AppRelocationFilesystem.optionalState(
                at: binGarbageURL(for: journal)
            ) == previous else {
                throw ambiguous("bin predecessor is not retired")
            }
        }
    }

    private func verifyAppRemoved(_ journal: Journal) throws {
        try verifyLiveCandidates(journal, requireBin: true)
        guard try AppRelocationFilesystem.optionalState(
            at: appPreviousURL(for: journal)
        ) == nil,
              try AppRelocationFilesystem.optionalState(
                at: appGarbageURL(for: journal)
              ) == nil
        else {
            throw ambiguous("owned app predecessor cleanup is incomplete")
        }
        if journal.previousAppKind == .foreign {
            guard let previous = journal.previousApp,
                  try AppRelocationFilesystem.optionalState(
                    at: foreignAppURL(for: journal)
                  ) == previous
            else {
                throw ambiguous("preserved foreign app changed or disappeared")
            }
        }
    }

    private func ensureInitialAuxiliaryPathsAreAvailable(
        for journal: Journal
    ) throws {
        var paths = [
            appPreviousURL(for: journal),
            appGarbageURL(for: journal),
            foreignAppURL(for: journal),
            binPreviousURL(for: journal),
            binGarbageURL(for: journal),
        ]
        if journal.previousAppKind != .foreign {
            paths.removeAll { $0 == foreignAppURL(for: journal) }
        }
        for path in paths where AppRelocationFilesystem.itemExists(path) {
            throw ambiguous(
                "transaction auxiliary path already exists at \(path.path)"
            )
        }
    }

    private func readJournal() throws -> Journal {
        let data: Data
        do {
            data = try AppRelocationFilesystem.readRegularFile(
                journalURL,
                maximumBytes: Self.maximumJournalBytes
            )
        } catch {
            throw corrupt(error.localizedDescription)
        }
        do {
            let journal = try JSONDecoder().decode(Journal.self, from: data)
            try validate(journal)
            return journal
        } catch let error as TransactionError {
            throw error
        } catch {
            throw corrupt(error.localizedDescription)
        }
    }

    private func persist(_ journal: Journal) throws {
        try validate(journal)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try AppRelocationFilesystem.writeAtomically(
                encoder.encode(journal),
                to: journalURL
            )
        } catch {
            throw TransactionError.filesystem(
                operation: "persist \(journalURL.path)",
                reason: error.localizedDescription
            )
        }
    }

    private func validate(_ journal: Journal) throws {
        guard journal.schema == Self.schema else {
            throw corrupt("unsupported schema \(journal.schema)")
        }
        guard Self.isCanonicalTransactionID(journal.transactionID) else {
            throw corrupt("transaction identifier is not a canonical UUID")
        }
        guard Self.isValidArtifactState(journal.appCandidate),
              Self.isValidArtifactState(journal.binCandidate)
        else {
            throw corrupt("candidate identity or content hash is invalid")
        }
        switch journal.previousAppKind {
        case .absent:
            guard journal.previousApp == nil else {
                throw corrupt("absent app predecessor includes state")
            }
        case .owned, .foreign:
            guard let previous = journal.previousApp,
                  Self.isValidArtifactState(previous)
            else {
                throw corrupt("existing app predecessor state is invalid")
            }
        }
        if let previousBin = journal.previousBin,
           !Self.isValidArtifactState(previousBin) {
            throw corrupt("existing bin predecessor state is invalid")
        }

        let states = [
            journal.appCandidate,
            journal.binCandidate,
            journal.previousApp,
            journal.previousBin,
        ].compactMap { $0 }
        guard Set(states.map(\.identity)).count == states.count else {
            throw corrupt("multiple relocation endpoints share one inode identity")
        }
    }

    private static func isCanonicalTransactionID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func isValidArtifactState(
        _ state: AppRelocationArtifactState
    ) -> Bool {
        isValidIdentity(state.identity) && isLowercaseSHA256(state.contentHash)
    }

    private static func isValidIdentity(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy {
            !$0.isEmpty
                && $0.allSatisfy(\.isNumber)
                && UInt64($0) != nil
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }

    private func corrupt(_ reason: String) -> TransactionError {
        .corruptJournal(path: journalURL.path, reason: reason)
    }

    private func ambiguous(_ reason: String) -> TransactionError {
        .ambiguousRecovery(path: journalURL.path, reason: reason)
    }
}
