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
    /// The owner's bootstrap connection and native key, held for the worker's lifetime.
    private let attachment: WorkerOwnerAttachment?
    /// Written and read only by the native executor.
    private(set) var lastPromptCache: (reused: Int, stored: [Int]) = (0, [])
    init(_ configuration: QwenResidentLoadConfiguration, family: ClusterResidentModelCatalog.Family = .qwenDense,
         attachment: WorkerOwnerAttachment? = nil,
         generationMode: ClusterGenerationMode = .pipeline, speculativeTerms: QwenMTPTerms? = nil,
         qualification: QwenResidentQualificationSwitches = .refused) throws {
        // With the owner's attachment, the exchange it installed creates the
        // JACCL group (no coordinator socket); a load that did not use it stops.
        self.attachment = attachment
        switch family {
        case .qwenDense:
            owner = .qwenDense(try .load(configuration, generationMode: generationMode,
                speculativeTerms: speculativeTerms, qualification: qualification))
        case .mimoV26:
            guard speculativeTerms == nil else { throw WorkerFailure.invalid("MiMo has no speculative decoding on a pair") }
            owner = .mimoV26(try .load(configuration, generationMode: generationMode, qualification: qualification))
        case .gptoss:
            throw WorkerFailure.invalid("GPT-OSS runs on its own worker runtime, not the native wrapper")
        }
        try JACCLOwnerBootstrap.requireConsumedIfInstalled()
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
        lastPromptCache = (0, [])
        switch owner {
        case .qwenDense(let runtime): result = try runtime.start(requestID: id, onCommittedToken: token)
        case .mimoV26(let runtime): result = try runtime.start(requestID: id, onCommittedToken: token)
        }
        guard result.bothRequestStatesRetired else { throw WorkerFailure.invalid("Native generation did not retire both request states") }
        lastPromptCache = (result.reusedPromptTokens, result.storedPromptFrontiers)
        return result.finishReason
    }
    func cancel(_ id: UUID) {
        switch owner {
        case .qwenDense(let runtime): runtime.cancel(requestID: id)
        case .mimoV26(let runtime): runtime.cancel(requestID: id)
        }
    }
    func keepWarmPulse() throws -> UInt64 {
        switch owner {
        case .qwenDense(let runtime): try runtime.keepWarmPulse()
        case .mimoV26(let runtime): try runtime.keepWarmPulse()
        }
    }
    func dataPlanePing() throws -> UInt64 {
        switch owner {
        case .qwenDense(let runtime): try runtime.dataPlanePing()
        case .mimoV26(let runtime): try runtime.dataPlanePing()
        }
    }
    func shutdown() throws {
        switch owner {
        case .qwenDense(let runtime): try runtime.shutdown()
        case .mimoV26(let runtime): try runtime.shutdown()
        }
    }
}
