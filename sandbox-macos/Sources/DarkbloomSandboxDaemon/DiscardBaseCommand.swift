import Foundation
import HostRuntimeCoordination
import SandboxRuntime
import SandboxRuntimeLume

enum DiscardBaseCommand {
    static func run(_ arguments: [String]) async throws {
        let options = try DiscardBaseOptions(arguments)
        try HostUserIdentityValidator.validate(file: options.hostIdentityFile, hostID: options.hostID)
        let authority = try HostRuntimeAuthority.system.acquireSandbox()
        defer { withExtendedLifetime(authority) {} }
        // Cleanup performs no admission, boot, guest-package or free-space check.
        // An interrupted root disk operation must be settled by its own journal.
        let runtime = LumeVirtualMachineRuntime(configuration: try .init(executable: options.executable,
            storageDirectory: options.storage, commandTimeoutSeconds: 120,
            trustPolicy: .production, hostRuntimeLease: authority))
        try await runtime.discardUnqualifiedBase(name: options.name, installationID: options.installationID)
        let report = DiscardBaseReport(name: options.name, installationID: options.installationID, absent: true)
        if options.json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else { print("\(options.name): absent") }
    }
}

struct DiscardBaseReport: Encodable {
    let name: String
    let installationID: UUID
    let absent: Bool
}
