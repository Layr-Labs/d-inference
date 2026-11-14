import Darwin
import Foundation

/// What the kernel reports about a child while its launch is being checked.
/// A launch check passes `record` as (part of) its check; a child that has
/// not run any instruction is stopped, is this process's own child and has
/// no process of its own.
final class LaunchStates: @unchecked Sendable {
    struct State { let pid: pid_t; let stopped: Bool; let ours: Bool; let children: Int32 }
    private let lock = NSLock()
    private var values: [State] = []

    func record(_ pid: pid_t) {
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size
        // Without a buffer the call returns an estimate of the space needed, not the children.
        var children = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        let state = State(pid: pid, stopped: read && information.pbi_status == UInt32(SSTOP),
            ours: read && information.pbi_ppid == UInt32(getpid()), children: count)
        lock.withLock { values.append(state) }
    }

    var states: [State] { lock.withLock { values } }

    /// The checked child's identifier when exactly one check ran, on a child
    /// that had not run; otherwise what was wrong.
    func unstarted() -> Result<pid_t, LaunchStateFault> {
        let seen = states
        guard seen.count == 1 else { return .failure(.init(description: "the check ran \(seen.count) times")) }
        guard seen[0].ours else { return .failure(.init(description: "the checked process is not this process's child")) }
        guard seen[0].stopped else { return .failure(.init(description: "the child was already running when its launch was checked")) }
        guard seen[0].children == 0 else { return .failure(.init(description: "the child had started processes before its launch was checked")) }
        return .success(seen[0].pid)
    }
}

struct LaunchStateFault: Error, CustomStringConvertible { let description: String }

/// True once `pid` names no process at all, not even a zombie: a child that
/// was reaped.
func launchedChildReaped(_ pid: pid_t) -> Bool { Darwin.kill(pid, 0) != 0 && errno == ESRCH }
