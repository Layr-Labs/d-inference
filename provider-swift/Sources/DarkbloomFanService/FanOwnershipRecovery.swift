import DarkbloomFanCore
import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct FanOwnershipRecoveryError: Error, CustomStringConvertible {
    public let failures: [FanRollbackFailure]

    public var description: String {
        "fan ownership recovery failed: "
            + failures.map(\.description).joined(separator: "; ")
    }
}

public enum FanOwnershipRecovery {
    public static func reconcile(
        backend: any SMCBackend,
        inventory: FanInventory,
        journalURL: URL,
        requireRootOwnership: Bool = true,
        journalOwner: (uid: uid_t, gid: gid_t)? = (0, 0),
        timing: FanControlTiming = .production
    ) throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return
        }
        let journal = try FanDurableFile.readJSON(
            FanSessionJournal.self,
            from: journalURL,
            requireRootOwnership: requireRootOwnership
        )
        let legacyFtstJournal = journal.ownsFtst
            && !journal.verifyAllFans
            && journal.fanIndices.isEmpty
            && journal.verificationFanIndices.isEmpty
            && journal.minimumVerificationFanCount == 0
        let verifyAllFans = journal.verifyAllFans
            || journal.ownsFtst
            || !journal.verificationFanIndices.isEmpty
            || journal.minimumVerificationFanCount > 0
        var pendingVerification = Set(journal.verificationFanIndices)
        var minimumVerificationFanCount = journal.minimumVerificationFanCount
        if verifyAllFans {
            if legacyFtstJournal {
                minimumVerificationFanCount = max(
                    minimumVerificationFanCount,
                    2
                )
            }
            let knownIndices = Set(journal.fanIndices).union(pendingVerification)
            if let maximumIndex = knownIndices.max() {
                minimumVerificationFanCount = max(
                    minimumVerificationFanCount,
                    maximumIndex + 1
                )
            }
            if !inventory.fans.isEmpty {
                minimumVerificationFanCount = max(
                    minimumVerificationFanCount,
                    inventory.fans.count
                )
            }
            if minimumVerificationFanCount == 0 {
                // Vulnerable v1 Ftst-only journals lost their prior fan set.
                // Validated M3/M4 Max hardware has two fans; requiring two is
                // conservative for unknown legacy state and never authorizes a
                // write by itself.
                minimumVerificationFanCount = 2
            }
        }
        if verifyAllFans, inventory.fans.isEmpty {
            let gateOutcome = FanAutomaticRestore.run(
                backend: backend,
                fans: [],
                ftstKey: inventory.ftstKey,
                ownsFtst: journal.ownsFtst,
                timing: timing
            )
            var failures = gateOutcome.failures
            failures.append(FanRollbackFailure(
                fanIndex: nil,
                step: .restoreMode,
                error: .smc(.injectedFailure(
                    "fan inventory is unavailable; full Auto verification is pending"
                ))
            ))
            try FanDurableFile.writeJSON(
                FanSessionJournal(
                    fanIndices: journal.fanIndices,
                    ownsFtst: gateOutcome.ownsFtst,
                    verifyAllFans: true,
                    verificationFanIndices: Array(pendingVerification),
                    minimumVerificationFanCount: minimumVerificationFanCount
                ),
                to: journalURL,
                permissions: 0o600,
                owner: journalOwner
            )
            throw FanOwnershipRecoveryError(failures: failures)
        }
        var failures: [FanRollbackFailure] = []
        var unresolvedFans = Set<Int>()
        var recoverableFans: [FanCapability] = []
        var recoveryIndices = Set(journal.fanIndices)
        if journal.ownsFtst {
            // v1 helpers could narrow fanIndices to empty after an immediate
            // pre-release Auto readback while retaining Ftst ownership. Treat
            // every discovered fan as possibly controlled during migration so
            // Ftst release is always followed by complete fan verification.
            recoveryIndices.formUnion(inventory.fans.map(\.index))
        }
        for index in recoveryIndices.sorted() {
            guard let fan = inventory.fans.first(where: { $0.index == index }) else {
                unresolvedFans.insert(index)
                failures.append(FanRollbackFailure(
                    fanIndex: index,
                    step: .restoreMode,
                    error: .smc(.injectedFailure(FanControllerError.noFans.description))
                ))
                continue
            }
            recoverableFans.append(fan)
        }

        let outcome = FanAutomaticRestore.run(
            backend: backend,
            fans: recoverableFans,
            ftstKey: inventory.ftstKey,
            ownsFtst: journal.ownsFtst,
            timing: timing
        )
        unresolvedFans.formUnion(outcome.unresolvedFanIndices)
        failures.append(contentsOf: outcome.failures)

        if verifyAllFans, !outcome.ownsFtst {
            let inventoryIndices = Set(inventory.fans.map(\.index))
            for index in pendingVerification
                where !inventoryIndices.contains(index)
            {
                failures.append(FanRollbackFailure(
                    fanIndex: index,
                    step: .restoreMode,
                    error: .smc(.injectedFailure(
                        "fan \(index) is unavailable for pending Auto verification"
                    ))
                ))
            }
            let verificationFailures = FanAutomaticRestore.verifyAutomatic(
                backend: backend,
                fans: inventory.fans,
                timing: timing
            )
            failures.append(contentsOf: verificationFailures)
            let failedVerificationIndices = Set(
                verificationFailures.compactMap(\.fanIndex)
            )
            pendingVerification.subtract(
                inventoryIndices.subtracting(failedVerificationIndices)
            )
            for failure in verificationFailures {
                if let index = failure.fanIndex,
                   recoveryIndices.contains(index)
                {
                    unresolvedFans.insert(index)
                } else if let index = failure.fanIndex {
                    pendingVerification.insert(index)
                }
            }
        }

        if verifyAllFans,
           inventory.fans.count < minimumVerificationFanCount
        {
            failures.append(FanRollbackFailure(
                fanIndex: nil,
                step: .restoreMode,
                error: .smc(.injectedFailure(
                    "fan inventory is incomplete (\(inventory.fans.count)/\(minimumVerificationFanCount))"
                ))
            ))
        }
        if failures.isEmpty, !pendingVerification.isEmpty {
            failures.append(FanRollbackFailure(
                fanIndex: nil,
                step: .restoreMode,
                error: .smc(.injectedFailure(
                    "full fan Auto verification is still pending"
                ))
            ))
        }

        guard !failures.isEmpty else {
            try FanDurableFile.remove(journalURL)
            return
        }
        try FanDurableFile.writeJSON(
            FanSessionJournal(
                fanIndices: Array(unresolvedFans),
                ownsFtst: outcome.ownsFtst,
                verifyAllFans: verifyAllFans,
                verificationFanIndices: Array(pendingVerification),
                minimumVerificationFanCount: minimumVerificationFanCount
            ),
            to: journalURL,
            permissions: 0o600,
            owner: journalOwner
        )
        throw FanOwnershipRecoveryError(failures: failures)
    }

}
