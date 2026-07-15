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
        let verifyAllFans = journal.verifyAllFans || journal.ownsFtst
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
                    verifyAllFans: true
                ),
                to: journalURL,
                permissions: 0o600,
                owner: journalOwner
            )
            throw FanOwnershipRecoveryError(failures: failures)
        }
        if verifyAllFans, !journal.ownsFtst {
            let failures = FanAutomaticRestore.verifyAutomatic(
                backend: backend,
                fans: inventory.fans,
                timing: timing
            )
            guard !failures.isEmpty else {
                try FanDurableFile.remove(journalURL)
                return
            }
            try FanDurableFile.writeJSON(
                FanSessionJournal(
                    fanIndices: journal.fanIndices,
                    ownsFtst: false,
                    verifyAllFans: true
                ),
                to: journalURL,
                permissions: 0o600,
                owner: journalOwner
            )
            throw FanOwnershipRecoveryError(failures: failures)
        }

        var failures: [FanRollbackFailure] = []
        var unresolvedFans: [Int] = []
        var recoverableFans: [FanCapability] = []
        var recoveryIndices = Set(journal.fanIndices)
        if verifyAllFans {
            // v1 helpers could narrow fanIndices to empty after an immediate
            // pre-release Auto readback while retaining Ftst ownership. Treat
            // every discovered fan as possibly controlled during migration so
            // Ftst release is always followed by complete fan verification.
            recoveryIndices.formUnion(inventory.fans.map(\.index))
        }
        for index in recoveryIndices.sorted() {
            guard let fan = inventory.fans.first(where: { $0.index == index }) else {
                unresolvedFans.append(index)
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
        unresolvedFans.append(contentsOf: outcome.unresolvedFanIndices)
        failures.append(contentsOf: outcome.failures)

        guard !failures.isEmpty else {
            try FanDurableFile.remove(journalURL)
            return
        }
        try FanDurableFile.writeJSON(
            FanSessionJournal(
                fanIndices: unresolvedFans,
                ownsFtst: outcome.ownsFtst,
                verifyAllFans: verifyAllFans
            ),
            to: journalURL,
            permissions: 0o600,
            owner: journalOwner
        )
        throw FanOwnershipRecoveryError(failures: failures)
    }

}
