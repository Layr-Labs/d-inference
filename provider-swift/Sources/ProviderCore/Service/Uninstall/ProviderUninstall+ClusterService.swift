import Darwin
import Foundation

// The live side of `Operations.runningClusterService` and `.stopClusterService`: who holds this Mac's cluster service
// lock, and ending it. `darkbloom cluster` starts the service from a session when launchd does not take its agent, and
// development builds always do, so a running service need not have a login agent.
extension ProviderUninstall {
    /// The lock holder (`ClusterService.running`), its pid from the service's own pid file, its executable from the
    /// kernel, and whose that executable is. Nil when no cluster service runs.
    public static func liveRunningClusterService(paths: ProviderUninstallPaths) -> RunningClusterService? {
        guard ClusterService.running() else { return nil }
        let pid = (try? ClusterService.paths()).flatMap { try? String(contentsOf: $0.pid, encoding: .utf8) }
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let executable = pid > 1 ? executablePath(pid: pid) : nil
        return .init(pid: pid, executable: executable, owner: owner(ofExecutable: executable, paths: paths))
    }

    /// Ends the service as `cluster stop --local-only` does for one a session started: SIGTERM, on which it ends this
    /// Mac's part, then waits until it has released the lock.
    public static func liveStopClusterService(pid: Int32) throws {
        guard pid > 1 else { throw StepFailure("the cluster service's pid could not be read") }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else {
            throw StepFailure("could not stop the cluster service (pid \(pid)): \(String(cString: strerror(errno)))")
        }
        let deadline = Date().addingTimeInterval(Double(ClusterServiceAgentPlan.exitTimeOutSeconds))
        while ClusterService.running() {
            guard Date() < deadline else {
                throw StepFailure("the cluster service (pid \(pid)) did not stop within \(ClusterServiceAgentPlan.exitTimeOutSeconds) s")
            }
            usleep(200_000)
        }
    }

    /// The executable a process runs, as the kernel records it (`KERN_PROCARGS2` starts with it).
    static func executablePath(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let start = MemoryLayout<Int32>.size
        guard let end = buffer[start..<size].firstIndex(of: 0), end > start else { return nil }
        return String(decoding: buffer[start..<end], as: UTF8.self)
    }
}
