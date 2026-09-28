import Foundation
import DarkbloomClusterProtocol

/// Deterministic bookkeeping on the remote owner's serial executor. No IO,
/// authentication, process launch, timer, resource admission or device lock occurs
/// here. Native observations must come from the actual local supervisor.
public struct ClusterOwnerLeaseState: Sendable {
    public let binding: ClusterOwnerBinding
    public let lifetimeDeadlineUptimeNanoseconds: UInt64
    public internal(set) var nextControlSequence: UInt64 = 0
    public internal(set) var quarantined = false
    public internal(set) var deviceLeaseReleased = false
    var lastNow: UInt64
    var recoveryOnly = false
    var draining = false
    var launchAttempted = false
    var childStarted = false
    var launchID: UUID?
    var nativeTerminal: ClusterOwnerNativeTerminal?
    var readyCapacity: Int?
    var request: Request?
    var seen = Set<UUID>()
    var releasedRequests = 0

    struct Request: Sendable {
        enum Phase: Equatable, Sendable { case reserving, admitted, running, retired }
        let id: UUID
        let ceiling: Int
        let deadline: UInt64
        var charged: Int
        var phase: Phase = .reserving
        var cancelled = false
        var releaseRequested = false
    }

    /// Call only after acquiring the device lease and establishing that no older
    /// unresolved native owner exists. `now` and this deadline are same-Mac uptime.
    public init(binding: ClusterOwnerBinding, now: UInt64, remainingLifetimeNanoseconds: UInt64) throws {
        let end = now.addingReportingOverflow(remainingLifetimeNanoseconds)
        guard remainingLifetimeNanoseconds > 0,
              remainingLifetimeNanoseconds <= ClusterWorkerLimits.deadlineNanoseconds, !end.overflow else {
            throw ClusterOwnerStateError.invalid("Invalid owner lifetime")
        }
        self.binding = binding; lastNow = now
        lifetimeDeadlineUptimeNanoseconds = end.partialValue
    }

    /// An incomplete journal is not permission to create another child. Recovery
    /// resolution is deliberately outside this slice: status stays quarantined.
    public static func recoveredUnresolved(binding: ClusterOwnerBinding, launchID: UUID?, now: UInt64) -> Self {
        var value = Self(binding: binding, deadline: now, now: now)
        value.recoveryOnly = true; value.quarantined = true
        value.launchID = launchID; value.launchAttempted = launchID != nil
        return value
    }

    private init(binding: ClusterOwnerBinding, deadline: UInt64, now: UInt64) {
        self.binding = binding; lifetimeDeadlineUptimeNanoseconds = deadline; lastNow = now
    }

    public var status: ClusterOwnerStatus {
        .init(route: binding.route, nextControlSequence: nextControlSequence,
              ready: available && request == nil, quarantined: quarantined, recoveredUnresolved: recoveryOnly,
              nativeLaunchID: launchID, activeRequestID: request?.id,
              chargedRequestBytes: recoveryOnly ? nil : (request?.charged ?? 0), nativeTerminal: nativeTerminal,
              deviceLeaseReleased: deviceLeaseReleased)
    }

    public var requiresNativeFence: Bool {
        !deviceLeaseReleased && !recoveryOnly && quarantined && launchAttempted && nativeTerminal == nil
    }

    public var canReleaseDeviceLease: Bool {
        !deviceLeaseReleased && !recoveryOnly && nativeTerminal != nil && request == nil
    }

    public var terminal: ClusterOwnerTerminal? {
        guard deviceLeaseReleased, let nativeTerminal else { return nil }
        return .init(route: binding.route, native: nativeTerminal, releasedRequestCount: releasedRequests,
                     lastAcceptedControlSequence: nextControlSequence == 0 ? nil : nextControlSequence - 1)
    }

    var available: Bool {
        !recoveryOnly && !quarantined && !draining && !deviceLeaseReleased
            && childStarted && nativeTerminal == nil && readyCapacity != nil
    }

    /// Persist the intended launch identity before calling Process.run.
    public mutating func beginNativeLaunch(_ id: UUID, now: UInt64) throws {
        try clock(now)
        try require(!recoveryOnly && !quarantined && !draining && !deviceLeaseReleased
                    && !launchAttempted && nativeTerminal == nil, "Native launch cannot be repeated")
        launchAttempted = true; launchID = id
    }

    public mutating func observeNativeStarted(_ id: UUID) throws {
        try require(!recoveryOnly && launchID == id && launchAttempted && !childStarted
                    && nativeTerminal == nil, "Wrong or repeated native start")
        childStarted = true
    }

    public mutating func observeReady(_ ready: ClusterWorkerReady, launchID id: UUID, now: UInt64) throws {
        try clock(now)
        try require(!recoveryOnly && !quarantined && !draining && childStarted && launchID == id
                    && nativeTerminal == nil && readyCapacity == nil && binding.matches(ready),
                    "Native readiness differs")
        readyCapacity = ready.requestCapacityBytes
    }

    public mutating func disconnect() { quarantine() }

    /// Expiry only requests fencing. It never manufactures a native-exit receipt.
    public mutating func observeTime(_ now: UInt64) throws { try clock(now) }

    mutating func clock(_ now: UInt64) throws {
        try require(now >= lastNow, "Local monotonic clock regressed")
        lastNow = now
        if now >= lifetimeDeadlineUptimeNanoseconds || (request.map { now >= $0.deadline } ?? false) {
            quarantine()
        }
    }

    mutating func require(_ condition: Bool, _ message: String) throws {
        if !condition { quarantine(); throw ClusterOwnerStateError.invalid(message) }
    }

    mutating func quarantine() { quarantined = true; readyCapacity = nil }
}
