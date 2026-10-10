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
}
