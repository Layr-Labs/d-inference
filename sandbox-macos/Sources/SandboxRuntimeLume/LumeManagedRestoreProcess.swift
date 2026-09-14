import Foundation
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    /// Raw restore is a VM-owning operation. Keep the exclusive kernel lease in
    /// the installer child even if the broker exits during VZ installation.
    func runManagedAppleRestore(arguments: [String], environment: [String: String]) async throws -> SandboxProcessResult {
        guard let lease = configuration.hostRuntimeLease else {
            throw SandboxRuntimeError.unsupported("raw Apple restore requires exclusive host ownership")
        }
        var environment = environment
        environment["DARKBLOOM_RESTORE_PROFILE"] = "apple-v1"
        let process = try lease.withInheritedDescriptor { descriptor in
            try processRunner.start(executable: configuration.executable, arguments: arguments,
                environment: environment, cooperativeControl: LumeLifecycleControl.processControl,
                runtimeAuthorityDescriptor: descriptor)
        }
        return try await process.wait(timeoutSeconds: configuration.createTimeoutSeconds,
            cooperativeGracePeriod: .seconds(20), signalGracePeriod: .seconds(2))
    }
}
