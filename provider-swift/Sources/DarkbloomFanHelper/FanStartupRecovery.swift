import DarkbloomFanCore
import DarkbloomFanService
import Foundation

struct FanStartupState {
    let recoveryInventory: FanInventory
    let sensorBaseline: FanSensorBaseline?
}

enum FanStartupRecovery {
    static func prepare(
        backend: any SMCBackend,
        reader: FanHardwareReader,
        paths: FanServicePaths,
        brandString: String? = nil,
        requireRootOwnership: Bool = true,
        journalOwner: (uid: uid_t, gid: gid_t)? = (0, 0),
        timing: FanControlTiming = .production
    ) throws -> FanStartupState {
        let recoveryInventory = try reader.discoverForRecovery(
            brandString: brandString
        )
        try FanOwnershipRecovery.reconcile(
            backend: backend,
            inventory: recoveryInventory,
            journalURL: paths.sessionJournal,
            requireRootOwnership: requireRootOwnership,
            journalOwner: journalOwner,
            timing: timing
        )

        let baseline = FileManager.default.fileExists(
            atPath: paths.sensorBaseline.path
        ) ? try FanDurableFile.readJSON(
            FanSensorBaseline.self,
            from: paths.sensorBaseline,
            requireRootOwnership: requireRootOwnership
        ) : nil
        if let baseline,
           baseline.chipFamily != recoveryInventory.chipFamily
        {
            throw FanDurableFileError.unsafeFile(
                "fan sensor baseline chip \(baseline.chipFamily.rawValue) does not match \(recoveryInventory.chipFamily.rawValue)"
            )
        }
        return FanStartupState(
            recoveryInventory: recoveryInventory,
            sensorBaseline: baseline
        )
    }
}
