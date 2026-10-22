import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Foundation

/// Native methods belong to one executor. Cancellation and unstarted-lane
/// withdrawal may run on the control reader and must be thread-safe, with no
/// native work. A fake implementation exercises orchestration without model IO.
protocol WorkerRuntime: AnyObject, Sendable {
    var readiness: ClusterWorkerReady? { get }
    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason
    /// As `start(_:token:)`, with publication and the owner's answer apart
    /// (`ClusterCommittedTokenChannel`); a runtime that cannot read answers
    /// late publishes and waits as before.
    func start(_ id: UUID, tokens: ClusterCommittedTokenChannel) throws -> ClusterWorkerFinishReason
    func cancel(_ id: UUID)
    func shutdown() throws
    /// Keep-warm tier 1: one asynchronous GPU pulse while idle; returns the
    /// submission time in nanoseconds.
    func keepWarmPulse() throws -> UInt64
    /// Keep-warm tier 2: one 1x16 data-plane exchange with the peer while
    /// idle; returns its duration in nanoseconds.
    func dataPlanePing() throws -> UInt64
    /// The last started request's prefix cache: prompt tokens restored, and
    /// frontiers kept. Read after `start` returns, on the same executor.
    var lastPromptCache: (reused: Int, stored: [Int]) { get }
    /// Gives back a reservation that never started (the owner cancelled it
    /// because the pair's other rank refused the request); the runtime is idle
    /// and available again. Throws when it cannot, which fails the worker.
    func releaseReservation(_ id: UUID) throws
    /// Re-derives, while idle, the longest context this rank's host memory
    /// gate admits now; nil when it does not derive one or cannot now.
    func refreshServingContext() -> Int?
    /// The last started request's own measurements (hand-off, MTP), when any.
    /// Read after `start` returns, on the same executor.
    var lastRequestTelemetry: ClusterWorkerRequestTelemetry? { get }
    /// Requests served at once (continuous batching); one for every runtime
    /// that does not batch. Fixed at load and agreed with the peer.
    var batchLanes: Int { get }
    /// Lane reservation, start and cancellation for a batching runtime. The
    /// batch loop serves started lanes until none is left on rank 0's side.
    func reserveLane(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int
    func startLane(_ id: UUID) throws
    func cancelLane(_ id: UUID)
    /// Thread-safe, no native work. True when `id` was reserved but not started
    /// and its reservation is given back. The caller must not have accepted start.
    func withdrawLane(_ id: UUID) -> Bool
    var hasStartedLanes: Bool { get }
    func serveBatch(host: QwenBatchServingHost) throws
}

extension WorkerRuntime {
    func start(_ id: UUID, tokens: ClusterCommittedTokenChannel) throws -> ClusterWorkerFinishReason {
        try start(id) { ordinal, token, frontier in
            try tokens.publish(ordinal, token, frontier)
            return try tokens.answer()
        }
    }
    var lastPromptCache: (reused: Int, stored: [Int]) { (0, []) }
    func releaseReservation(_ id: UUID) throws {
        throw WorkerFailure.invalid("This runtime cannot give back a reservation")
    }
    func refreshServingContext() -> Int? { nil }
    var lastRequestTelemetry: ClusterWorkerRequestTelemetry? { nil }
    var batchLanes: Int { 1 }
    func reserveLane(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        throw WorkerFailure.invalid("This runtime serves one request at a time")
    }
    func startLane(_ id: UUID) throws { throw WorkerFailure.invalid("This runtime serves one request at a time") }
    func cancelLane(_ id: UUID) {}
    func withdrawLane(_ id: UUID) -> Bool { false }
    var hasStartedLanes: Bool { false }
    func serveBatch(host: QwenBatchServingHost) throws {
        throw WorkerFailure.invalid("This runtime serves one request at a time")
    }
}
