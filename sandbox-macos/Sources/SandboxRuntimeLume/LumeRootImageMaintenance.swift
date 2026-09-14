import Foundation
import HostRuntimeCoordination
import SandboxRuntime

/// Serial root operation: both durable fences are installed before image IO is
/// exposed. Finish requires independently observed detach/stopped-state cleanup
/// and a synchronously persisted journal checkpoint. No deinit clears fences.
package final class LumeRootImageMaintenance {
    private let source: LumeRootBaseImageGuard
    private let maintenance: HostRuntimeMaintenanceScope
    private let image: LumeImageMaintenanceState
    private let use = LumeMaintenanceUseGate()

    init(guard source: LumeRootBaseImageGuard, maintenance: HostRuntimeMaintenanceScope,
                     image: LumeImageMaintenanceState) throws {
        self.source = source; self.maintenance = maintenance; self.image = image
        try maintenance.runtimeLease.validateSystemExclusive(); try maintenance.validate()
    }

    package func withOfflineImage<T>(_ body: (URL, Int32) throws -> T) throws -> T {
        try use.enter(); defer { use.leave() }
        try maintenance.validate(); try image.validateForOfflineIO()
        let result = try source.withImage(body)
        try image.validateForOfflineIO(); try maintenance.validate()
        return result
    }

    package func withOfflineImage<T>(_ body: (URL, Int32) async throws -> T) async throws -> T {
        try use.enter(); defer { use.leave() }
        try maintenance.validate(); try image.validateForOfflineIO()
        let (url, descriptor) = try source.withImage { ($0, $1) }
        let result = try await body(url, descriptor)
        try image.validateForOfflineIO(); try maintenance.validate()
        return result
    }

    package func finishAfterVerifiedCleanup(persist: (LumeImageMaintenanceCleanup) throws -> Void) throws {
        try use.enter(); defer { use.leave() }
        try maintenance.validate()
        try image.removeFenceAfterVerifiedCleanup(persist: persist)
        // Image fence first, global fence last. Both EX and the retained image
        // descriptor remain owned until this scope and its guard are released.
        try maintenance.finishAfterVerifiedCleanup()
    }

    /// Spawn only inside the active image callback. The foreground system tool
    /// retains machine EX if the operator exits while attach/mount is running.
    /// Callers must await actual child termination before observing cleanup.
    package func startOwnedProcess(executable: URL, arguments: [String],
                                   runner: SandboxProcessRunner = .init()) throws -> SandboxManagedProcess {
        try use.withActiveClaim {
            try maintenance.validate(); try image.validateForOfflineIO()
            return try maintenance.runtimeLease.withInheritedDescriptor { descriptor in
                try runner.start(executable: executable, arguments: arguments,
                    maximumOutputBytes: 4 * 1_048_576, runtimeAuthorityDescriptor: descriptor)
            }
        }
    }
}
