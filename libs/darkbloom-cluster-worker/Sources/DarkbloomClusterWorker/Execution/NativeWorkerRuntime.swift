import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Foundation

/// Exactly one native executor uses this wrapper; cancel is the facade's
/// explicitly thread-safe operation. No model or tensor crosses the pipe.
final class NativeWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    private let owner: QwenResidentRuntime
    init(_ configuration: QwenResidentLoadConfiguration, bootstrap: WorkerBootstrapConfiguration? = nil,
         generationMode: ClusterGenerationMode = .pipeline,
         qualification: QwenResidentQualificationSwitches = .refused) throws {
        // STAGING DIVERGENCE: the owner-authenticated JACCL bootstrap needs the
        // mlx-c bootstrap bridge (`mlx_distributed_init_jaccl_with_bootstrap`),
        // which the pinned mlx-c does not carry. The flags are still parsed so
        // the argument contract is stable; supplying them is refused here
        // rather than silently falling back to the direct native bootstrap.
        guard bootstrap == nil else {
            throw WorkerFailure.invalid("The authenticated bootstrap attachment is not available in this build")
        }
        owner = try .load(configuration, generationMode: generationMode, qualification: qualification)
    }
    var readiness: ClusterWorkerReady? { owner.readiness }
    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        try owner.reserve(requestID: id, request: value)
    }
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        let result = try owner.start(requestID: id, onCommittedToken: token)
        guard result.bothRequestStatesRetired else { throw WorkerFailure.invalid("Native generation did not retire both request states") }
        return result.finishReason
    }
    func cancel(_ id: UUID) { owner.cancel(requestID: id) }
    func shutdown() throws { try owner.shutdown() }
}
