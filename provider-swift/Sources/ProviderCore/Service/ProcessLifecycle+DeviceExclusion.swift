import Foundation
import DarkbloomClusterProcess

private final class ServingDeviceExclusionState: @unchecked Sendable {
    let lock = NSLock()
    var held: ClusterDeviceExclusion?
}

extension ProcessLifecycle {
    private static let servingDeviceExclusion = ServingDeviceExclusionState()

    /// Call only in the process that runs solo inference, before its first MLX
    /// preparation. A daemon launcher or cluster leader delegates device
    /// ownership to its child and must not acquire this exclusion itself.
    ///
    /// Retain until process exit, including errors and background-task teardown.
    /// Releasing when a serve function returns could precede a still-unwinding
    /// model load. The kernel releases the CLOEXEC descriptor on exit or exec.
    public static func acquireInferenceDeviceExclusion() throws {
        try servingDeviceExclusion.lock.withLock {
            guard servingDeviceExclusion.held == nil else { return }
            servingDeviceExclusion.held = try ClusterDeviceExclusion(
                directoryURL: ClusterUserPaths().deviceDirectory)
        }
    }
}
