import Foundation
import Darwin
import DarkbloomClusterSecurity

/// This Mac's cluster service as a login agent (review finding 12): what
/// `darkbloom cluster` installs on the leader and on every member, and what
/// `darkbloom cluster stop` and unpairing remove.
extension ClusterService {
    /// The resolved path of a darkbloom executable (a symlinked
    /// `~/.darkbloom/bin/darkbloom` resolves into the installed app, whose
    /// identity the label and macOS permissions follow).
    public static func resolvedExecutable(_ executable: URL) -> String {
        guard let resolved = realpath(executable.path, nil) else { return executable.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The login agent's job for this executable and the service options.
    public static func loginAgentJob(executable: URL, serviceOptions: [String]) throws -> ClusterServiceAgent.Job {
        try ClusterServiceAgent.job(executablePath: resolvedExecutable(executable), serviceOptions: serviceOptions,
                                    logPath: try paths().log)
    }

    /// Installs (or keeps) the login agent and waits, bounded, until the
    /// service holds its lock. Idempotent; asks for nothing.
    public static func installAtLogin(executable: URL, serviceOptions: [String],
                                      waitSeconds: Double = 15) throws -> ClusterServiceAgent.Outcome {
        let files = try paths()
        try ClusterConfigurationFiles.ensureDirectory(files.lock.deletingLastPathComponent(), create: true, privateMode: true)
        let job = try loginAgentJob(executable: executable, serviceOptions: serviceOptions)
        let outcome = try ClusterServiceAgent.install(job, serviceRunning: { running() }, stopUnsupervisedService: {
            try stopDetached()
        })
        let deadline = Date().addingTimeInterval(waitSeconds)
        while !running() {
            guard Date() < deadline else {
                throw ClusterOnboardingFailure("this Mac's cluster service was installed but did not start within \(Int(waitSeconds)) s; "
                    + "its log is ~/.darkbloom/cluster-setup/service.log")
            }
            usleep(100_000)
        }
        return outcome
    }

    /// Removes the login agent (the service stops this Mac's part first) and
    /// ends a service still running outside launchd. Returns the labels removed.
    @discardableResult
    public static func removeFromLogin(executable: URL? = nil) throws -> [String] {
        let current = executable.map { ClusterServiceAgentPlan.label(executablePath: resolvedExecutable($0)) }
        let removed = try ClusterServiceAgent.uninstall(alsoLabel: current)
        if running() { try stopDetached() }
        return removed
    }

    /// Whether this Mac holds no pairing at all (after an unpair). An unreadable
    /// pairing store is not taken for "unpaired".
    public static func holdsNoPairing() -> Bool { holdsNoPairing(store: .default()) }

    static func holdsNoPairing(store: ClusterPairingStore) -> Bool {
        do { return try store.load()?.pairings.isEmpty ?? true } catch { return false }
    }

    /// Ends the cluster service that holds this home's lock outside launchd (an
    /// earlier version started it detached from a terminal): SIGTERM to the pid
    /// its pid file names, only while that process is a darkbloom cluster
    /// service; then waits for the lock, as long as the service may take to
    /// release this Mac's part.
    static func stopDetached() throws {
        let files = try paths()
        guard running(), let text = try? String(contentsOf: files.pid, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        guard isClusterService(pid: pid) else {
            throw ClusterOnboardingFailure("another program holds this Mac's cluster service lock (pid \(pid)); stop it and run `darkbloom cluster` again")
        }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(Double(ClusterServiceAgentPlan.exitTimeOutSeconds))
        while running() {
            guard Date() < deadline else {
                throw ClusterOnboardingFailure("the earlier cluster service (pid \(pid)) is still releasing this Mac's part; run `darkbloom cluster` again in a minute")
            }
            usleep(200_000)
        }
    }

    /// Whether `pid` is a `darkbloom cluster service` of this user (its argv, read from the kernel).
    static func isClusterService(pid: Int32) -> Bool {
        guard let arguments = processArguments(pid: pid) else { return false }
        let name = arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        return name == "darkbloom" && arguments.count >= 3 && arguments[1] == "cluster" && arguments[2] == "service"
    }

    private static func processArguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // The executable path, then padding NULs, then argv.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }
}
