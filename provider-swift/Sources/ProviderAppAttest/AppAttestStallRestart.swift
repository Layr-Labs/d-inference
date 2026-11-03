import Foundation

/// What may justify an automatic graceful provider restart.
public enum AppAttestRestartTrigger: Sendable, Equatable {
    /// An Apple callback has held admission for this many seconds. Only a new
    /// process releases the stranded Apple admission.
    case stalled(seconds: Int)
    /// `DCAppAttestService.isSupported` has been false for this many seconds
    /// on a Mac whose App Attest the coordinator verified before. A new
    /// process started by launchd usually reads it as supported again.
    case unsupported(seconds: Int)
}

/// When a stalled DeviceCheck operation, or App Attest that stopped being
/// supported, may trigger a graceful provider restart. Both triggers share one
/// rate limit and one persisted marker.
public enum AppAttestStallRestartPolicy {
    /// At most one automatic restart per interval, across process restarts.
    public static let minimumInterval: TimeInterval = 6 * 3600

    /// How long `isSupported` must stay false before a restart. It can flip
    /// back on its own, so one failed `ready` alone does not drain the provider.
    public static let unsupportedThreshold: TimeInterval = 5 * 60

    /// A coordinator verification older than this does not justify a restart:
    /// the Mac may have lost App Attest support for good.
    public static let verifiedWithin: TimeInterval = 7 * 24 * 3600

    public enum SkipReason: String, Sendable, Equatable {
        case notStalled = "not_stalled"
        /// `isSupported` has been false for less than `unsupportedThreshold`.
        case unsupportedBriefly = "unsupported_briefly"
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
        decide(trigger: stalledSeconds.map { .stalled(seconds: $0) }, inferenceActive: inferenceActive,
               lifecycleBusy: lifecycleBusy, lastRestartAt: lastRestartAt, retryDeferred: retryDeferred, now: now)
    }

    public static func decide(trigger: AppAttestRestartTrigger?, inferenceActive: Bool, lifecycleBusy: Bool,
                              lastRestartAt: Date?, retryDeferred: Bool, now: Date) -> Decision {
        switch trigger {
        case nil:
            return .skip(.notStalled)
        case .stalled(let seconds):
            guard Double(seconds) > AppleOperationStall.threshold else { return .skip(.notStalled) }
        case .unsupported(let seconds):
            guard Double(seconds) >= unsupportedThreshold else { return .skip(.unsupportedBriefly) }
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
        afterDrain(updateOwnsDrain: updateOwnsDrain, stillBlocked: stillStalled(heldSince: heldSince, now: now))
    }

    /// `stillBlocked`: the trigger still holds after the drain (the Apple call
    /// is still unanswered, or `isSupported` is still false).
    public static func afterDrain(updateOwnsDrain: Bool, stillBlocked: Bool) -> AfterDrain {
        guard updateOwnsDrain else { return .lifecycleTookOver }
        return stillBlocked ? .restart : .recovered
    }

    /// Whether `isSupported == false` may lead to a restart at all. The
    /// coordinator must have verified App Attest on this Mac within
    /// `verifiedWithin`; launchd must start the new process (an in-place exec
    /// is a suspected cause of this state, so it is never the remedy); and the provisioning
    /// profile must not have expired, because a restart cannot renew it.
    public static func unsupportedRestartEligible(lastVerifiedAt: Date?, relaunchesThroughLaunchd: Bool,
                                                  profileExpired: Bool?, now: Date) -> Bool {
        guard relaunchesThroughLaunchd, profileExpired != true, let lastVerifiedAt else { return false }
        return abs(now.timeIntervalSince(lastVerifiedAt)) < verifiedWithin
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

/// Persisted time when the coordinator last granted this Mac an App Attest
/// authorization. It only enables the restart for `isSupported == false`; it
/// never authorizes serving.
public struct AppAttestVerifiedMarker: Sendable {
    public static let fileName = "app-attest-verified.json"
    /// The running provider rewrites the marker at most this often.
    public static let refreshInterval: TimeInterval = 3600
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    private struct Record: Codable {
        let verifiedAt: Double
        enum CodingKeys: String, CodingKey { case verifiedAt = "verified_at" }
    }

    /// Nil when the marker is missing or unreadable: no evidence, no restart.
    public func lastVerified() -> Date? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.verifiedAt.isFinite else { return nil }
        return Date(timeIntervalSince1970: record.verifiedAt)
    }

    public func record(_ date: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Record(verifiedAt: date.timeIntervalSince1970))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
