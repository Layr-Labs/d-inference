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

        var failures: [FanRollbackFailure] = []
        var unresolvedFans: [Int] = []
        var recoverableFans: [FanCapability] = []
        for index in journal.fanIndices {
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
                ownsFtst: outcome.ownsFtst
            ),
            to: journalURL,
            permissions: 0o600,
            owner: journalOwner
        )
        throw FanOwnershipRecoveryError(failures: failures)
    }

}
