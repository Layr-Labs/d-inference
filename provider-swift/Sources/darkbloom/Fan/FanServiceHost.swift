import DarkbloomFanCore
import DarkbloomFanProtocol
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The host operations that `FanServiceManager` uses: root check, launchctl
/// and codesign, AppleSMC, helper XPC, the current executable, root
/// ownership of state files, and the retry delay. `production` is the real
/// system. Tests inject fakes so that no launchd, SMC, XPC or root-owned
/// state changes.
struct FanServiceHost {
    var effectiveUserID: () -> uid_t
    var runProcess: (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> FanProcessResult
    var makeSMCBackend: () throws -> any SMCBackend
    /// `nil` reads the brand string of this Mac.
    var brandString: String?
    var helperStatus: () throws -> FanServiceStatus
    var helperRestoreAutomatic: () throws -> FanIPCReply
    /// `nil` resolves the real executable of this process.
    var currentExecutableURL: (() throws -> URL)?
    /// When true, state files and directories are owned by root and reads
    /// require root ownership.
    var requiresRootOwnership: Bool
    var retryDelay: TimeInterval

    static var production: FanServiceHost {
        FanServiceHost(
            effectiveUserID: { geteuid() },
            runProcess: { FanProcessRunner.run($0, arguments: $1, timeout: $2) },
            makeSMCBackend: { try AppleSMCBackend() },
            brandString: nil,
            helperStatus: { try FanHelperClient().status() },
            helperRestoreAutomatic: { try FanHelperClient().restoreAutomatic() },
            currentExecutableURL: nil,
            requiresRootOwnership: true,
            retryDelay: 0.1
        )
    }

    var stateOwner: (uid: uid_t, gid: gid_t)? {
        requiresRootOwnership ? (0, 0) : nil
    }
}
