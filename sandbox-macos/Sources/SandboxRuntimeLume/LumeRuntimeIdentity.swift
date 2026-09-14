import Foundation
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    /// Read-only preflight shared by fresh work and recovery. A changed runtime
    /// cannot take over an operation authorized for another signed executable.
    package func requireRuntimeIdentity(_ expectedSHA256: String) async throws {
        _ = try await validateRuntime()
        guard LumeInstalledCandidateCheckpoint.isDigest(expectedSHA256),
              validatedRuntime?.files["lume"]?.sha256 == expectedSHA256 else {
            throw SandboxRuntimeError.unsupported("runtime differs from the protected operation binding")
        }
    }
}
