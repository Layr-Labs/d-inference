import Darwin
import Foundation
import HostRuntimeCoordination
import SandboxRuntime

/// This same-binary child owns EX independently of the vendor tool. It closes
/// the original inherited fd and retains only a CLOEXEC duplicate, so a platform
/// helper cannot accidentally keep machine ownership for the mount's lifetime.
enum AccountlessSystemCommandWorker {
    static let command = "__owned-system-command"

    static func run(_ arguments: [String]) async throws -> Int32 {
        guard getuid() == 0, geteuid() == 0, getegid() == 0,
              ProcessInfo.processInfo.environment["DARKBLOOM_HOST_RUNTIME_FD"] == "4",
              arguments.count >= 4, let operation = UUID(uuidString: arguments[0]),
              let tool = AccountlessMountSystemTools.Tool(rawValue: arguments[2]) else {
            throw AccountlessDiskError.bindingChanged
        }
        let intent = try HostRuntimeMaintenanceIntent(operationID: operation, journalSHA256: arguments[1])
        let lease = try HostRuntimeAuthority.system.retainRootMaintenanceDescriptor(4, intent: intent)
        try lease.validateSystemExclusive()
        close(4)
        let child = try SandboxProcessRunner().startSystemTool(executable: URL(fileURLWithPath: tool.rawValue),
            arguments: Array(arguments.dropFirst(3)))
        let result = await child.wait()
        try lease.validateSystemExclusive()
        FileHandle.standardOutput.write(result.standardOutput)
        FileHandle.standardError.write(result.standardError)
        return withExtendedLifetime(lease) {
            result.standardOutputTruncated || result.standardErrorTruncated ? 1 : result.exitCode
        }
    }

    static func arguments(intent: HostRuntimeMaintenanceIntent, tool: AccountlessMountSystemTools.Tool,
                          arguments: [String]) -> [String] {
        [command, intent.operationID.uuidString.lowercased(), intent.journalSHA256, tool.rawValue] + arguments
    }
}
