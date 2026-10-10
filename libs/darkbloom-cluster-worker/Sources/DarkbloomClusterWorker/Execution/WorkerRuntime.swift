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
}
