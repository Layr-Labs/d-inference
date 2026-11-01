import Foundation

/// What the cluster-member supervisor is doing, persisted for `darkbloom
/// status`, for the coordinated update and for evidence. Written by the
/// supervisor only; never used to decide liveness (launchd and the process
/// table own that).
public struct ClusterMemberSupervisorState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Waiting for this Mac's cluster port before letting the member register.
        case waitingForLink
        /// A member process is running.
        case running
        /// The last run ended; the next starts at `restartAt`.
        case backoff
        /// The restart budget is spent; nothing runs until the operator restarts.
        case exhausted
        /// Draining for, or applying, a coordinated update.
        case updating
        /// The supervisor is stopping or has stopped (operator stop).
        case stopped
    }

    public struct RunRecord: Codable, Equatable, Sendable {
        public var pid: Int32
        public var startedAt: Double
        public var endedAt: Double?
        public var exitCode: Int32?
        public var signal: Int32?
        /// `operatorStop`, `guardTeardown`, `failure`, `signaled`, or a guard recycle reason.
        public var end: String?

        public init(pid: Int32, startedAt: Double, endedAt: Double? = nil, exitCode: Int32? = nil,
                    signal: Int32? = nil, end: String? = nil) {
            self.pid = pid
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.exitCode = exitCode
            self.signal = signal
            self.end = end
        }
    }

    public var supervisorPID: Int32
    public var version: String
    /// Epoch seconds the Mac booted when this record was written; a record
    /// from an earlier boot is history only.
    public var bootTime: Double
    public var phase: Phase
    public var detail: String?
    public var budget: ClusterMemberRestartBudget
    public var current: RunRecord?
    public var lastRun: RunRecord?
    public var runs: Int
    public var restartAt: Double?
    public var updatedAt: Double

    public init(supervisorPID: Int32, version: String, bootTime: Double, phase: Phase, detail: String? = nil,
                budget: ClusterMemberRestartBudget, current: RunRecord? = nil, lastRun: RunRecord? = nil,
                runs: Int = 0, restartAt: Double? = nil, updatedAt: Double) {
        self.supervisorPID = supervisorPID
        self.version = version
        self.bootTime = bootTime
        self.phase = phase
        self.detail = detail
        self.budget = budget
        self.current = current
        self.lastRun = lastRun
        self.runs = runs
        self.restartAt = restartAt
        self.updatedAt = updatedAt
    }

    /// One line for `darkbloom status`.
    public func summary(now: Double, name: String = "cluster member supervisor") -> String {
        var parts = ["\(name): \(phase.rawValue)"]
        if let current, phase == .running { parts.append("member pid \(current.pid) up \(Int(now - current.startedAt)) s") }
        if let restartAt, phase == .backoff { parts.append("restart in \(max(0, Int(restartAt - now))) s") }
        parts.append("runs \(runs), quick failures \(budget.quickFailures)/\(budget.limits.maxQuickFailures), "
            + "guard teardowns \(budget.guardTeardowns)/\(budget.limits.maxGuardTeardowns)")
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: "; ")
    }
}
