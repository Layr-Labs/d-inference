import Darwin
import Foundation
import SandboxRuntime
import SandboxCore

extension LumeVirtualMachineRuntime {
    func baseImageShareArguments(scope: SandboxOperationScope?) throws -> [String] {
        guard let directory = configuration.baseImageSharedDirectory else { return [] }
        guard scope == nil, configuration.guestCommandPolicy == .baseImagePreparationAndDevelopment else {
            throw SandboxRuntimeError.unsupported("a bootstrap share is restricted to base-image preparation")
        }
        let descriptor = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(descriptor) }
        return ["--shared-dir", directory.path + ":ro"]
    }
}
