import Foundation
import SandboxCore
import SandboxRuntime

/// Uses the same broker lock as start/stop/delete while a stopped candidate is
/// checked and recorded. No native image mount or qualification is authorized.
package final class LumeBaseCandidateOperationGuard: @unchecked Sendable {
    private let operation: LumeVirtualMachineOperationLock
    package let source: SandboxGuestBaseSource

    package init(name: String, storage: URL) throws {
        let identity = try LumeVirtualMachineOwnership.requireOwned(name: name, owner: .baseTemplate, in: storage)
        operation = try LumeVirtualMachineOperationLock(workspace: .init(storageDirectory: storage),
            name: name, operation: "prepare-accountless-candidate")
        source = try LumeGuestTemplateSource.load(name: name, installationID: identity.installationID, storage: storage)
        guard source.kind == .appleRestore else {
            throw SandboxRuntimeError.unsupported("accountless candidate requires raw Apple ownership")
        }
    }
}

extension LumeVirtualMachineRuntime {
    package func requireBaseCandidateStorage(_ storage: URL) throws {
        guard capacityArbiter == nil,
              try SandboxAuthorityFileSystem.canonicalPath(for: storage)
                == SandboxAuthorityFileSystem.canonicalPath(for: configuration.storageDirectory) else {
            throw SandboxRuntimeError.unsupported("accountless candidate storage does not match the base runtime")
        }
    }
}
