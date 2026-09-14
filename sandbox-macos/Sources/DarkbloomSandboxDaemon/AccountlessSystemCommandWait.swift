import Foundation
import SandboxRuntime

/// Observe mutating DiskImages/DiskArbitration clients without killing them on
/// caller cancellation or an observation deadline. Their inherited machine EX
/// lease must outlive in-flight system work. A timeout leaves intent unresolved.
enum AccountlessSystemCommandWait {
    static func naturalExit(of child: SandboxManagedProcess, seconds: UInt32) async throws -> SandboxProcessResult {
        guard seconds > 0 else { throw AccountlessDiskError.invalidInventory }
        return try await Task.detached {
            let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            while child.isRunning {
                if clock.now >= deadline {
                    // Keep the managed wrapper alive so its deinit stop policy
                    // cannot signal an unobserved attach. If the operator exits,
                    // the OS child independently retains its inherited EX fd.
                    Task.detached { _ = await child.wait() }
                    throw AccountlessDiskError.systemOperationPending
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            return await child.wait()
        }.value
    }
}
