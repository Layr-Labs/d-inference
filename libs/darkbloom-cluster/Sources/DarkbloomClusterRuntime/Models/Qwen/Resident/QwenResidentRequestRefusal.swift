import DarkbloomClusterProtocol
import Foundation

/// A reservation one rank refused for one request: its live host memory gate,
/// a capacity ceiling, the request's own deadline. Nothing of the request was
/// allocated and the rank's owner is idle again, so only this request failed:
/// the worker answers `refused` with the reason and keeps serving, and the
/// pair's owner gives back what the other rank admitted.
public struct ClusterResidentRequestRefusal: Error, CustomStringConvertible, Sendable {
    public let reason: ClusterWorkerRefusal
    /// The gate's or check's own sentence, for whoever launched the worker.
    public let message: String
    public var description: String { message }
    public init(reason: ClusterWorkerRefusal, message: String) { self.reason = reason; self.message = message }
}

/// A started request both ranks ended alone because a rank's memory refused
/// it while it ran (D6): the refusing rank stopped in the message it owed its
/// peer, the peer confirmed, and both retired the request. A resident runtime's
/// `start` throws this only after that, with its control available again, so
/// the worker publishes `aborted` then `retired(aborted)` and keeps serving.
public struct ClusterResidentRequestAbort: Error, CustomStringConvertible, Sendable {
    public let abort: ClusterWorkerAbort
    /// The refusing rank's own sentence, or the peer's abort as this rank saw it.
    public let message: String
    public var description: String { message }
    public init(abort: ClusterWorkerAbort, message: String) { self.abort = abort; self.message = message }
}

extension QwenResidentControl {
    /// Runs the checks of a reservation the control already holds (`reserve`).
    /// A throw from `body` gives the reservation back and becomes a refusal of
    /// this request alone. Only an owner that a cancel or failure has already
    /// ended keeps the earlier behaviour: failed, and the error as it was.
    func reserving<T>(_ id: UUID, rank: Int, deadline: UInt64, _ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            guard release(id) else { fail(); throw error }
            let reason: ClusterWorkerRefusal = DispatchTime.now().uptimeNanoseconds >= deadline ? .deadline : .capacity
            let message = String(describing: error)
            log("darkbloom-request-refused-v1 rank=\(rank) reason=\(reason.rawValue)")
            log("darkbloom-cluster-worker: request refused before it started (the session keeps serving): \(message)")
            throw ClusterResidentRequestRefusal(reason: reason, message: message)
        }
    }
}
