import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Foundation

/// Exactly one native executor uses this wrapper; cancel is the facade's
/// explicitly thread-safe operation. No model or tensor crosses the pipe.
final class NativeWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    /// The adapter that executes the registered model, chosen by its family.
    private enum Owner {
        case qwenDense(QwenResidentRuntime)
        case mimoV26(MiMoResidentRuntime)
    }
    private let owner: Owner
    init(_ configuration: QwenResidentLoadConfiguration, family: ClusterResidentModelCatalog.Family = .qwenDense,
         bootstrap: WorkerBootstrapConfiguration? = nil,
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
        switch family {
        case .qwenDense:
            owner = .qwenDense(try .load(configuration, generationMode: generationMode, qualification: qualification))
        case .mimoV26:
            owner = .mimoV26(try .load(configuration, generationMode: generationMode, qualification: qualification))
        case .gptoss:
            throw WorkerFailure.invalid("GPT-OSS runs on its own worker runtime, not the native wrapper")
        }
    }
    var readiness: ClusterWorkerReady? {
        switch owner {
        case .qwenDense(let runtime): runtime.readiness
        case .mimoV26(let runtime): runtime.readiness
        }
    }
    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        switch owner {
        case .qwenDense(let runtime): try runtime.reserve(requestID: id, request: value)
        case .mimoV26(let runtime): try runtime.reserve(requestID: id, request: value)
        }
    }
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        let result: QwenResidentGenerationCompletion
        switch owner {
        case .qwenDense(let runtime): result = try runtime.start(requestID: id, onCommittedToken: token)
        case .mimoV26(let runtime): result = try runtime.start(requestID: id, onCommittedToken: token)
        }
        guard result.bothRequestStatesRetired else { throw WorkerFailure.invalid("Native generation did not retire both request states") }
        return result.finishReason
    }
    func cancel(_ id: UUID) {
        switch owner {
        case .qwenDense(let runtime): runtime.cancel(requestID: id)
        case .mimoV26(let runtime): runtime.cancel(requestID: id)
        }
    }
    func shutdown() throws {
        switch owner {
        case .qwenDense(let runtime): try runtime.shutdown()
        case .mimoV26(let runtime): try runtime.shutdown()
        }
    }
}
