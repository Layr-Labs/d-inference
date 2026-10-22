import DarkbloomClusterProtocol
import Foundation

/// What the batch loop needs from the worker that owns it. Every call is made
/// on the runtime's executor, between native steps; none may run MLX work.
public protocol QwenBatchServingHost: AnyObject {
    /// Applies whatever control arrived (reservations, starts, cancellations)
    /// without waiting for more.
    func serviceControl() throws
    /// Rank 0 only: one committed token of one request, after both ranks hold it.
    func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws
    /// Rank 0 only: the owner's continue (true) or clean stop (false) for each
    /// request's last published token; returns once every one arrived.
    func awaitDecisions(_ requestIDs: [UUID]) throws -> [UUID: Bool]
    /// Both ranks: the request finished cleanly here and its native state retired.
    func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws
    /// Both ranks, just before `publishFinished`: prompt tokens this rank
    /// restored from its prefix cache and the frontiers it kept afterwards.
    /// Called only when either is not empty.
    func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws
    /// Rank 0 only, without waiting: the owner's answer to `requestID`'s last
    /// published token if it has arrived (true: go on), else nil. False once
    /// the request was cancelled or passed its deadline: no answer comes then.
    func pollDecision(_ requestID: UUID) throws -> Bool?
    /// Rank 0 only: as `pollDecision`, waiting for the answer.
    func awaitDecision(_ requestID: UUID) throws -> Bool
    /// Both ranks: a started request left the loop without finishing
    /// (cancelled, or past its deadline) and its native state retired. The
    /// worker answers the owner's cancel of it with `retired(cancelled)`,
    /// now or when that cancel arrives; the other lanes go on.
    func publishLeft(requestID: UUID) throws
}

extension QwenBatchServingHost {
    public func pollDecision(_ requestID: UUID) throws -> Bool? {
        throw ProbeError("This batch host reads every lane's decisions together")
    }
    public func awaitDecision(_ requestID: UUID) throws -> Bool {
        throw ProbeError("This batch host reads every lane's decisions together")
    }
    public func publishLeft(requestID: UUID) throws {
        throw ProbeError("This batch host cannot retire a started lane on its own")
    }
}

/// What the lane book charges a lane for while it is held: its named
/// request state, beside the one whole allowance the newest lane carries.
protocol ClusterBatchLaneReservation {
    var laneStateBytes: Int { get }
}

extension QwenResidentReservation: ClusterBatchLaneReservation {
    var laneStateBytes: Int { allowance.stateBytes }
}

/// The Qwen pipeline's lane book (`QwenResidentRuntime+Batch.swift`).
typealias QwenBatchLaneBook = ClusterBatchLaneBook<QwenResidentReservation>

extension ClusterBatchLaneBook where Reservation == QwenResidentReservation {
    func allowances() -> [QwenResidentRequestAllowance] { reservations().map(\.allowance) }
}

/// The lanes one rank holds: reserved, started (waiting to join the loop),
/// joined, and cancelled. The worker's control reader may cancel or withdraw
/// an unstarted lane; everything else runs on the executor. A lane stays charged
/// from reservation until withdrawal or until its request finishes and retires.
final class ClusterBatchLaneBook<Reservation: ClusterBatchLaneReservation>: @unchecked Sendable {
    private let lock = NSLock()
    private var reserved: [UUID: Reservation] = [:]
    private var started: [UUID] = []
    private var joined = Set<UUID>()
    private var cancelled = Set<UUID>()
    private var seen = Set<UUID>()
    private var seenOrder: [UUID] = []

    /// Lanes charged now (reserved, started or joined).
    var count: Int { lock.withLock { reserved.count } }
    var hasStarted: Bool { lock.withLock { !started.isEmpty } }
    var isEmpty: Bool { lock.withLock { reserved.isEmpty } }

    /// Named request state of every charged lane except `excluding`. Lanes
    /// share the stage's one-time fusion and run one prefill frame at a time,
    /// so beside the newest lane's whole allowance the others add their state.
    func stateBytes(excluding: UUID? = nil) throws -> Int {
        let values = lock.withLock { reserved.filter { $0.key != excluding }.map { $0.value.laneStateBytes } }
        return try QwenLongPrefillCheckedBytes.sum(values)
    }

    func reservations() -> [Reservation] {
        lock.withLock { Array(reserved.values) }
    }

    func reserve(_ id: UUID, _ value: Reservation, lanes: Int) throws {
        try lock.withLock {
            guard reserved.count < lanes, !seen.contains(id) else {
                throw ProbeError("Every batch lane is taken or the request ID was used")
            }
            reserved[id] = value; seen.insert(id); seenOrder.append(id)
            if seenOrder.count > ClusterWorkerLimits.requestReplayWindow { seen.remove(seenOrder.removeFirst()) }
        }
    }

    func start(_ id: UUID) throws {
        try lock.withLock {
            guard reserved[id] != nil, !started.contains(id), !joined.contains(id) else {
                throw ProbeError("Batch lane start has no matching reservation")
            }
            started.append(id)
        }
    }

    /// The oldest started lane, now joined (rank 0 picks joins in arrival order).
    func takeStarted() -> (UUID, Reservation)? {
        lock.withLock {
            guard !started.isEmpty else { return nil }
            let id = started.removeFirst(); joined.insert(id)
            return (id, reserved[id]!)
        }
    }

    /// The oldest started lane that is `ready`, now joined (a lane that is
    /// not ready yet keeps its place; `ready` must not use the book).
    func takeStarted(where ready: (Reservation) -> Bool) -> (UUID, Reservation)? {
        lock.withLock {
            guard let index = started.firstIndex(where: { reserved[$0].map(ready) ?? false }) else { return nil }
            let id = started.remove(at: index); joined.insert(id)
            return (id, reserved[id]!)
        }
    }

    /// One charged lane's reservation.
    func reservation(_ id: UUID) -> Reservation? { lock.withLock { reserved[id] } }

    /// That started lane, now joined (rank 1 joins what rank 0 named).
    func takeStarted(_ id: UUID) -> Reservation? {
        lock.withLock {
            guard let index = started.firstIndex(of: id) else { return nil }
            started.remove(at: index); joined.insert(id)
            return reserved[id]
        }
    }

    func isStarted(_ id: UUID) -> Bool { lock.withLock { started.contains(id) } }

    /// The request finished and retired: its charge ends.
    func finish(_ id: UUID) {
        lock.withLock { reserved[id] = nil; joined.remove(id); started.removeAll { $0 == id }; cancelled.remove(id) }
    }

    func cancel(_ id: UUID) { lock.withLock { if reserved[id] != nil { cancelled.insert(id) } } }

    /// True once `id`'s owner cancelled it (a lane that runs leaves the loop
    /// at its next step boundary, where a runtime retires lanes one by one).
    func isCancelled(_ id: UUID) -> Bool { lock.withLock { cancelled.contains(id) } }

    /// A lane reserved but not started gives its reservation back: nothing
    /// native was made for it, so the lanes that run are untouched. False for a
    /// lane that started or joined (cancelling one of those ends the batch).
    func withdraw(_ id: UUID) -> Bool {
        lock.withLock {
            guard reserved[id] != nil, !started.contains(id), !joined.contains(id) else { return false }
            reserved[id] = nil; cancelled.remove(id)
            return true
        }
    }
    var anyCancelled: Bool { lock.withLock { !cancelled.isEmpty } }

    /// Every lane is gone (a failed loop, or shutdown).
    func clear() { lock.withLock { reserved.removeAll(); started.removeAll(); joined.removeAll(); cancelled.removeAll() } }
}
