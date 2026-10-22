import Foundation
import DarkbloomClusterProtocol

/// Deterministic bookkeeping on the remote owner's serial executor. No IO,
/// authentication, process launch, timer, resource admission or device lock occurs
/// here. Native observations must come from the actual local supervisor.
public struct ClusterOwnerLeaseState: Sendable {
    public let binding: ClusterOwnerBinding
    /// Requests this owner's worker serves at once: its batch lanes (one
    /// unless the pair batches). Each request keeps its own bookkeeping.
    public let lanes: Int
    /// The rank lease's current deadline on this Mac (S03). The leader renews
    /// it every few seconds while it keeps the session; there is no fixed
    /// lifetime. Past it the state fences, as for any loss of the leader.
    public internal(set) var lifetimeDeadlineUptimeNanoseconds: UInt64
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
    /// Every reserved, admitted, running or retiring request, by ID: at most `lanes`.
    var requests: [UUID: Request] = [:]
    /// Recent request IDs, to refuse a replay: a window, never a count.
    var seen = Set<UUID>()
    var seenOrder: [UUID] = []
    var releasedRequests = 0
    /// With lanes: requests that retired here recently, oldest first, whose
    /// late cancel changes nothing (as the worker's lane session treats it).
    var retiredRecently: [UUID] = []

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
    public init(binding: ClusterOwnerBinding, now: UInt64, remainingLifetimeNanoseconds: UInt64,
                lanes: Int = 1) throws {
        let end = now.addingReportingOverflow(remainingLifetimeNanoseconds)
        guard remainingLifetimeNanoseconds > 0,
              remainingLifetimeNanoseconds <= ClusterWorkerLimits.deadlineNanoseconds, !end.overflow,
              (1...8).contains(lanes) else {
            throw ClusterOwnerStateError.invalid("Invalid owner lifetime or lane count")
        }
        self.binding = binding; self.lanes = lanes; lastNow = now
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
        self.binding = binding; lanes = 1; lifetimeDeadlineUptimeNanoseconds = deadline; lastNow = now
    }

    public var status: ClusterOwnerStatus {
        .init(route: binding.route, nextControlSequence: nextControlSequence,
              ready: available && requests.count < lanes, quarantined: quarantined, recoveredUnresolved: recoveryOnly,
              nativeLaunchID: launchID, activeRequestID: activeRequestIDs.first,
              chargedRequestBytes: recoveryOnly ? nil : requests.values.reduce(0) { $0 + $1.charged },
              nativeTerminal: nativeTerminal, deviceLeaseReleased: deviceLeaseReleased)
    }

    /// Every request this owner still holds, in a stable order.
    public var activeRequestIDs: [UUID] { requests.keys.sorted { $0.uuidString < $1.uuidString } }

    public var requiresNativeFence: Bool {
        !deviceLeaseReleased && !recoveryOnly && quarantined && launchAttempted && nativeTerminal == nil
    }

    public var canReleaseDeviceLease: Bool {
        !deviceLeaseReleased && !recoveryOnly && nativeTerminal != nil && requests.isEmpty
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

    /// One renewal of the rank lease from the leader: the deadline moves to
    /// `ttl` after `now`, never earlier than it was. A fenced, released or
    /// expired lease is not revived.
    public mutating func renewLease(now: UInt64, ttl: UInt64) throws {
        try clock(now)
        try require(!recoveryOnly && !quarantined && !deviceLeaseReleased
                    && (1...ClusterWorkerLease.maximumNanoseconds).contains(ttl), "Lease renewal refused")
        let end = now.addingReportingOverflow(ttl)
        if !end.overflow { lifetimeDeadlineUptimeNanoseconds = max(lifetimeDeadlineUptimeNanoseconds, end.partialValue) }
    }

    /// Expiry only requests fencing. It never manufactures a native-exit receipt.
    public mutating func observeTime(_ now: UInt64) throws { try clock(now) }

    mutating func clock(_ now: UInt64) throws {
        try require(now >= lastNow, "Local monotonic clock regressed")
        lastNow = now
        if now >= lifetimeDeadlineUptimeNanoseconds || requests.values.contains(where: { now >= $0.deadline }) {
            quarantine()
        }
    }

    mutating func require(_ condition: Bool, _ message: String) throws {
        if !condition { quarantine(); throw ClusterOwnerStateError.invalid(message) }
    }

    mutating func quarantine() { quarantined = true; readyCapacity = nil }
}
