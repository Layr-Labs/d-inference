import Foundation

/// When a stalled DeviceCheck operation may trigger a graceful provider
/// restart. Only a new process releases the stranded Apple admission.
public enum AppAttestStallRestartPolicy {
    /// At most one automatic restart per interval, across process restarts.
    public static let minimumInterval: TimeInterval = 6 * 3600

    public enum SkipReason: String, Sendable, Equatable {
        case notStalled = "not_stalled"
        case recentlyRestarted = "recently_restarted"
        /// An earlier attempt in this process drained but could not restart.
        case retryDeferred = "retry_deferred"
        case lifecycleBusy = "lifecycle_busy"
        case inferenceActive = "inference_active"
    }

    public enum Decision: Sendable, Equatable {
        case restart
        case skip(SkipReason)
    }

    /// Why an attempt that had already closed admission did not restart.
    public enum FailedAttempt: Sendable, Equatable {
        /// Accepted work or the coordinator's drain acknowledgement did not
        /// finish before the drain timeout, or the connection dropped.
        case drainNotAcknowledged
        /// The restart marker could not be persisted, so no restart may be issued.
        case markerNotPersisted
    }

    /// Often transient, but retrying on every one-minute monitor tick would
    /// close admission again and again.
    public static let drainRetryDelay: TimeInterval = 15 * 60

    /// How long this process waits before draining again. A marker that cannot
    /// be written keeps failing and forbids the restart, so it waits the full
    /// interval: at most one drain per interval, as if the restart had run.
    public static func retryDelay(after failure: FailedAttempt) -> TimeInterval {
        switch failure {
        case .drainNotAcknowledged: return drainRetryDelay
        case .markerNotPersisted: return minimumInterval
        }
    }

    /// A marker from the future (clock moved backwards) also counts as recent
    /// unless it is more than one interval away. `retryDeferred` is this
    /// process's in-memory deferral after a failed attempt.
    public static func decide(stalledSeconds: Int?, inferenceActive: Bool, lifecycleBusy: Bool,
                              lastRestartAt: Date?, retryDeferred: Bool, now: Date) -> Decision {
        guard let stalledSeconds, Double(stalledSeconds) > AppleOperationStall.threshold else {
            return .skip(.notStalled)
        }
        if let lastRestartAt, abs(now.timeIntervalSince(lastRestartAt)) < minimumInterval {
            return .skip(.recentlyRestarted)
        }
        if retryDeferred { return .skip(.retryDeferred) }
        if lifecycleBusy { return .skip(.lifecycleBusy) }
        if inferenceActive { return .skip(.inferenceActive) }
        return .restart
    }

    /// Re-evaluated after the drain, right before the restart is committed:
    /// false once Apple's callback has released the gate, so a stall that
    /// resolved during the drain never spends the marker or restarts.
    public static func stillStalled(heldSince: Date?, now: Date) -> Bool {
        AppleOperationStall.reportedSeconds(heldSince: heldSince, now: now) != nil
    }

    public enum AfterDrain: Sendable, Equatable {
        case restart
        /// Apple's callback released the gate while the drain was awaited.
        case recovered
        /// A CLI stop, OS termination or scheduled shutdown took over the
        /// drain; a relaunch would undo it.
        case lifecycleTookOver
    }

    /// Decided after the drain's last suspension point. Losing ownership of
    /// the drain wins over everything else: the process is being stopped.
    public static func afterDrain(updateOwnsDrain: Bool, heldSince: Date?, now: Date) -> AfterDrain {
        guard updateOwnsDrain else { return .lifecycleTookOver }
        return stillStalled(heldSince: heldSince, now: now) ? .restart : .recovered
    }
}

/// Persisted time of the last automatic stall restart. Written before the
/// restart is issued so a failed or looping restart cannot exceed the limit.
public struct AppAttestStallRestartMarker: Sendable {
    public static let fileName = "app-attest-stall-restart.json"
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    private struct Record: Codable {
        let restartedAt: Double
        enum CodingKeys: String, CodingKey { case restartedAt = "restarted_at" }
    }

    /// An unreadable marker falls back to its modification time, so damage
    /// cannot lift the limit early.
    public func lastRestart() -> Date? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let data = try? Data(contentsOf: url),
           let record = try? JSONDecoder().decode(Record.self, from: data), record.restartedAt.isFinite {
            return Date(timeIntervalSince1970: record.restartedAt)
        }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public func record(_ date: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Record(restartedAt: date.timeIntervalSince1970))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
