import DarkbloomClusterProtocol
import Foundation

/// Native methods belong to one executor. Only cancel is called by the control
/// reader. A fake implementation can exercise orchestration without model IO.
protocol WorkerRuntime: AnyObject, Sendable {
    var readiness: ClusterWorkerReady? { get }
    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason
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
}

extension WorkerRuntime {
    var lastPromptCache: (reused: Int, stored: [Int]) { (0, []) }
    func releaseReservation(_ id: UUID) throws {
        throw WorkerFailure.invalid("This runtime cannot give back a reservation")
    }
    func refreshServingContext() -> Int? { nil }
}
