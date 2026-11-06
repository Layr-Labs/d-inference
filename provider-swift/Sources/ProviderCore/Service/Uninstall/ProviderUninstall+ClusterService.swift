import Darwin
import Foundation

// The live side of `Operations.runningClusterService`: who holds this install's cluster service lock. `darkbloom
// cluster` starts the service from a session when launchd does not take its agent, and development builds always do, so
// a running service need not have a login agent.
extension ProviderUninstall {
    /// The lock holder, its pid from the service's own pid file, its executable from the kernel, and whose that
    /// executable is. Nil when no cluster service holds the lock.
    public static func liveRunningClusterService(paths: ProviderUninstallPaths) -> RunningClusterService? {
        guard let files = try? ClusterService.paths() else {
            return .init(pid: 0, executable: nil, owner: .unknown, note: unreadableLockNote)
        }
        return runningClusterService(lock: files.lock, pidFile: files.pid, paths: paths,
                                     isClusterService: ClusterService.isClusterService(pid:))
    }

    /// `liveRunningClusterService` on given files, and with the check `cluster stop --service` makes before it stops a
    /// pid (`ClusterService.isClusterService`, the process's arguments).
    static func runningClusterService(lock: URL, pidFile: URL, paths: ProviderUninstallPaths,
                                      isClusterService: (Int32) -> Bool) -> RunningClusterService? {
        switch lockState(lock) {
        case .free: return nil
        case .unreadable: return .init(pid: 0, executable: nil, owner: .unknown, note: unreadableLockNote)
        case .held: break
        }
        let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        guard pid > 1 else { return .init(pid: 0, executable: nil, owner: .unknown, note: "a cluster service is running, and its pid can't be read") }
        let command = processCommand(pid: pid)
        let executable = command?.executable
        let owner = owner(ofExecutable: executable, paths: paths)
        // A pid file can outlive its service, and the number can be reused: only a cluster service is anyone's.
        // The other install's is told by its own command name; this build's by the check `cluster stop` makes.
        let isService = if case .otherInstall = owner, let other = paths.otherEnvironment {
            isClusterServiceCommand(command?.arguments ?? [], cli: other.cliName)
        } else {
            isClusterService(pid)
        }
        if case .otherInstall = owner, isService { return .init(pid: pid, executable: executable, owner: owner) }
        guard isService else {
            return .init(pid: pid, executable: executable, owner: .unknown,
                         note: "the cluster service lock is held, but pid \(pid) from its pid file is not a cluster service")
        }
        return .init(pid: pid, executable: executable, owner: owner, isThisCLI: true)
    }

    static let unreadableLockNote = "this Mac's cluster service lock can't be read, so a cluster service may be running"

    enum LockState: Equatable { case free, held, unreadable }

    /// The service lock's state, as `ClusterService.running` reads it, keeping "can't be read" apart from "free".
    static func lockState(_ lock: URL) -> LockState {
        let fd = open(lock.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .free : .unreadable }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { _ = flock(fd, LOCK_UN); return .free }
        return errno == EWOULDBLOCK ? .held : .unreadable
    }

    /// The executable a process runs and its arguments, as the kernel records them (`KERN_PROCARGS2`: the executable,
    /// padding, then argv; as `ClusterService` reads them).
    static func processCommand(pid: Int32) -> (executable: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        let executable = String(decoding: buffer[start..<index], as: UTF8.self)
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let begin = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[begin..<index], as: UTF8.self))
            index += 1
        }
        return (executable, arguments)
    }

    /// `<cli> cluster service`, the rule `ClusterService.isClusterService` applies to this build's name.
    static func isClusterServiceCommand(_ arguments: [String], cli: String) -> Bool {
        arguments.count >= 3 && URL(fileURLWithPath: arguments[0]).lastPathComponent == cli
            && arguments[1] == "cluster" && arguments[2] == "service"
    }
}
