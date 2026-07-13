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
        journalOwner: (uid: uid_t, gid: gid_t)? = (0, 0)
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
        for index in journal.fanIndices {
            do {
                guard let fan = inventory.fans.first(where: { $0.index == index }) else {
                    throw FanControllerError.noFans
                }
                try backend.write(fan.modeKey, bytes: [FanMode.automatic.rawValue])
                let rawMode = try backend.read(fan.modeKey).uint8()
                guard FanMode(rawValue: rawMode).isAutomatic else {
                    throw FanRollbackError.modeNotAutomatic(rawValue: rawMode)
                }
                if let zero = try? SMCValue.float32Bytes(0, key: fan.targetKey) {
                    try? backend.write(fan.targetKey, bytes: zero)
                }
            } catch {
                unresolvedFans.append(index)
                failures.append(FanRollbackFailure(
                    fanIndex: index,
                    step: .restoreMode,
                    error: recoveryError(error)
                ))
            }
        }

        var unresolvedFtst = false
        if journal.ownsFtst, let ftstKey = inventory.ftstKey {
            do {
                try backend.write(ftstKey, bytes: [0])
                let value = try backend.read(ftstKey).uint8()
                guard value == 0 else {
                    throw FanRollbackError.ftstStillSet(rawValue: value)
                }
            } catch {
                unresolvedFtst = true
                failures.append(FanRollbackFailure(
                    fanIndex: nil,
                    step: .clearFtst,
                    error: recoveryError(error)
                ))
            }
        } else if journal.ownsFtst {
            unresolvedFtst = true
            failures.append(FanRollbackFailure(
                fanIndex: nil,
                step: .clearFtst,
                error: .smc(.keyNotFound("Ftst"))
            ))
        }

        guard !failures.isEmpty else {
            try FanDurableFile.remove(journalURL)
            return
        }
        try FanDurableFile.writeJSON(
            FanSessionJournal(
                fanIndices: unresolvedFans,
                ownsFtst: unresolvedFtst
            ),
            to: journalURL,
            permissions: 0o600,
            owner: journalOwner
        )
        throw FanOwnershipRecoveryError(failures: failures)
    }

    private static func recoveryError(_ error: Error) -> FanRollbackError {
        if let error = error as? FanRollbackError { return error }
        if let error = error as? FanHardwareError { return .hardware(error) }
        if let error = error as? SMCError { return .smc(error) }
        if let error = error as? FanControllerError {
            switch error {
            case .hardware(let hardware): return .hardware(hardware)
            case .smc(let smc): return .smc(smc)
            default: return .smc(.injectedFailure(error.description))
            }
        }
        return .smc(.injectedFailure(String(describing: error)))
    }
}
