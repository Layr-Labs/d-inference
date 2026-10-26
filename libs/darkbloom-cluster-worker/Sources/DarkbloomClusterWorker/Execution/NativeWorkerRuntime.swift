import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import DarkbloomClusterSecurity
import Foundation

/// Exactly one native executor uses this wrapper; cancel is the facade's
/// explicitly thread-safe operation. No model or tensor crosses the pipe.
final class NativeWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    /// The adapter that executes the registered model, chosen by its family.
    private enum Owner {
        case qwenDense(QwenResidentRuntime)
        case qwenTensorParallel(QwenTensorParallelResidentRuntime)
        case mimoV26(MiMoResidentRuntime)
        case glm5Next(GLM5NextResidentRuntime)
        case glm5NextTensorParallel(GLM5NextTensorParallelResidentRuntime)
    }
    private let owner: Owner
    /// The owner's bootstrap connection and native key, held for the worker's lifetime.
    private let attachment: WorkerOwnerAttachment?
    /// Written and read only by the native executor.
    private(set) var lastPromptCache: (reused: Int, stored: [Int]) = (0, [])
    private(set) var lastRequestTelemetry: ClusterWorkerRequestTelemetry?
    init(_ configuration: QwenResidentLoadConfiguration, family: ClusterResidentModelCatalog.Family = .qwenDense,
         attachment: WorkerOwnerAttachment? = nil,
         generationMode: ClusterGenerationMode = .pipeline, speculativeTerms: QwenMTPTerms? = nil,
         qualification: QwenResidentQualificationSwitches = .refused,
         dataPlane: ClusterDataPlaneCredential? = nil, prefixSSDKey: Data? = nil, tensorShares: [Int] = [1, 1]) throws {
        // With the owner's attachment, the exchange it installed creates the
        // JACCL group (no coordinator socket); a load that did not use it stops.
        self.attachment = attachment
        switch family {
        case .qwenDense where generationMode == .tensorParallel:
            owner = .qwenTensorParallel(try .load(configuration, shares: tensorShares, qualification: qualification,
                dataPlane: dataPlane, prefixSSDKey: prefixSSDKey))
        case .qwenDense:
            owner = .qwenDense(try .load(configuration, generationMode: generationMode,
                speculativeTerms: speculativeTerms, qualification: qualification, dataPlane: dataPlane,
                prefixSSDKey: prefixSSDKey))
        case .mimoV26:
            // `--mtp-depth` is parsed once for every family; MiMo's own terms bound it (1...3).
            owner = .mimoV26(try .load(configuration, generationMode: generationMode,
                speculativeDepth: speculativeTerms?.depth, qualification: qualification, dataPlane: dataPlane,
                prefixSSDKey: prefixSSDKey))
        case .glm5Next where generationMode == .tensorParallel:
            // Every layer on both ranks, half of each split weight, sealed sums.
            guard speculativeTerms == nil, let dataPlane else {
                throw WorkerFailure.invalid("GLM tensor parallel runs over a keyed data plane without speculation")
            }
            owner = .glm5NextTensorParallel(try .load(configuration, qualification: qualification, dataPlane: dataPlane))
        case .glm5Next:
            // The registered GLM row: plain pipeline over the keyed data plane,
            // with its prompt-prefix cache and SSD tier as every family keeps them.
            guard generationMode == .pipeline, speculativeTerms == nil, let dataPlane else {
                throw WorkerFailure.invalid("GLM serves the pipeline over a keyed data plane; other modes are not in its row")
            }
            let runtime = try GLM5NextResidentRuntime.serving(configuration, qualification: qualification,
                prefixSSDKey: prefixSSDKey)
            try runtime.load(dataPlane: dataPlane)
            owner = .glm5Next(runtime)
        case .gptoss:
            throw WorkerFailure.invalid("GPT-OSS runs on its own worker runtime, not the native wrapper")
        }
        try JACCLOwnerBootstrap.requireConsumedIfInstalled()
    }
    var readiness: ClusterWorkerReady? {
        switch owner {
        case .qwenDense(let runtime): runtime.readiness
        case .qwenTensorParallel(let runtime): runtime.readiness
        case .glm5NextTensorParallel(let runtime): runtime.readiness
        case .mimoV26(let runtime): runtime.readiness
        case .glm5Next(let runtime): runtime.readiness
        }
    }
    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        switch owner {
        case .qwenDense(let runtime): try runtime.reserve(requestID: id, request: value)
        case .qwenTensorParallel(let runtime): try runtime.reserve(requestID: id, request: value)
        case .glm5NextTensorParallel(let runtime): try runtime.reserve(requestID: id, request: value)
        case .mimoV26(let runtime): try runtime.reserve(requestID: id, request: value)
        case .glm5Next(let runtime): try runtime.reserve(requestID: id, request: value)
        }
    }
    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        try ClusterCommittedTokenChannel.answering(token) { try start(id, tokens: $0) }
    }
    func start(_ id: UUID, tokens channel: ClusterCommittedTokenChannel) throws -> ClusterWorkerFinishReason {
        let result: QwenResidentGenerationCompletion
        lastPromptCache = (0, []); lastRequestTelemetry = nil
        let token = { (ordinal: Int, token: Int, frontier: Int) throws -> Bool in
            try channel.publish(ordinal, token, frontier)
            return try channel.answer()
        }
        switch owner {
        case .qwenDense(let runtime): result = try runtime.start(requestID: id, onCommittedToken: token)
        case .qwenTensorParallel(let runtime): result = try runtime.start(requestID: id, onCommittedToken: token)
        // Reads each answer after its next step was submitted.
        case .glm5NextTensorParallel(let runtime): result = try runtime.start(requestID: id, tokens: channel)
        case .mimoV26(let runtime): result = try runtime.start(requestID: id, onCommittedToken: token)
        case .glm5Next(let runtime): result = try runtime.start(requestID: id, onCommittedToken: token)
        }
        guard result.bothRequestStatesRetired else { throw WorkerFailure.invalid("Native generation did not retire both request states") }
        lastPromptCache = (result.reusedPromptTokens, result.storedPromptFrontiers)
        lastRequestTelemetry = result.telemetry.flatMap { $0.isEmpty ? nil : $0 }
        return result.finishReason
    }
    func releaseReservation(_ id: UUID) throws {
        switch owner {
        case .qwenDense(let runtime): try runtime.releaseReservation(requestID: id)
        case .qwenTensorParallel(let runtime): try runtime.releaseReservation(requestID: id)
        case .glm5NextTensorParallel(let runtime): try runtime.releaseReservation(requestID: id)
        case .mimoV26(let runtime): try runtime.releaseReservation(requestID: id)
        case .glm5Next(let runtime): try runtime.releaseReservation(requestID: id)
        }
    }
    /// GLM tensor parallel also drops its prompt-prefix entries under host
    /// pressure; every other family gives back its freed-buffer cache only.
    func releaseIdleMemory(underPressure: Bool) -> Int? {
        switch owner {
        case .glm5NextTensorParallel(let runtime): return try? runtime.releaseIdleMemory(underPressure: underPressure)
        case .qwenDense, .qwenTensorParallel, .mimoV26, .glm5Next: return ClusterIdleMemory.releaseFreedBuffers()
        }
    }
    func refreshServingContext() -> Int? {
        switch owner {
        case .qwenDense(let runtime): runtime.refreshServingContext()
        case .glm5NextTensorParallel(let runtime): runtime.refreshServingContext()
        case .qwenTensorParallel, .mimoV26, .glm5Next: nil
        }
    }
    // Batch lanes: the Qwen family's pipeline lanes and GLM tensor parallel's.
    var batchLanes: Int {
        switch owner {
        case .qwenDense(let runtime): runtime.batch.lanes
        case .glm5NextTensorParallel(let runtime): runtime.lanes.lanes
        case .qwenTensorParallel, .mimoV26, .glm5Next: 1
        }
    }
    /// GLM tensor parallel publishes each token's logprobs from its decoding
    /// rank, on its one-request path and in its batch lanes alike.
    var capturesLogprobs: Bool {
        if case .glm5NextTensorParallel = owner { return true }
        return false
    }
    func reserveLane(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        switch owner {
        case .qwenDense(let runtime): try runtime.reserveLane(requestID: id, request: value)
        case .glm5NextTensorParallel(let runtime): try runtime.reserveLane(requestID: id, request: value)
        case .qwenTensorParallel, .mimoV26, .glm5Next: throw WorkerFailure.invalid("This family serves one request at a time")
        }
    }
    func startLane(_ id: UUID) throws {
        switch owner {
        case .qwenDense(let runtime): try runtime.startLane(requestID: id)
        case .glm5NextTensorParallel(let runtime): try runtime.startLane(requestID: id)
        case .qwenTensorParallel, .mimoV26, .glm5Next: throw WorkerFailure.invalid("This family serves one request at a time")
        }
    }
    func cancelLane(_ id: UUID) {
        switch owner {
        case .qwenDense(let runtime): runtime.cancelLane(requestID: id)
        case .glm5NextTensorParallel(let runtime): runtime.cancelLane(requestID: id)
        case .qwenTensorParallel, .mimoV26, .glm5Next: break
        }
    }
    func withdrawLane(_ id: UUID) -> Bool {
        switch owner {
        case .qwenDense(let runtime): runtime.withdrawLane(requestID: id)
        case .glm5NextTensorParallel(let runtime): runtime.withdrawLane(requestID: id)
        case .qwenTensorParallel, .mimoV26, .glm5Next: false
        }
    }
    var hasStartedLanes: Bool {
        switch owner {
        case .qwenDense(let runtime): runtime.hasStartedLanes
        case .glm5NextTensorParallel(let runtime): runtime.hasStartedLanes
        case .qwenTensorParallel, .mimoV26, .glm5Next: false
        }
    }
    func serveBatch(host: QwenBatchServingHost) throws {
        switch owner {
        case .qwenDense(let runtime): try runtime.serveBatch(host: host)
        case .glm5NextTensorParallel(let runtime): try runtime.serveBatch(host: host)
        case .qwenTensorParallel, .mimoV26, .glm5Next: throw WorkerFailure.invalid("This family serves one request at a time")
        }
    }
    /// GLM tensor parallel's lane loop retires a cancelled lane alone.
    var retiresCancelledLanes: Bool {
        if case .glm5NextTensorParallel = owner { return true }
        return false
    }
    func cancel(_ id: UUID) {
        switch owner {
        case .qwenDense(let runtime): runtime.cancel(requestID: id)
        case .qwenTensorParallel(let runtime): runtime.cancel(requestID: id)
        case .glm5NextTensorParallel(let runtime): runtime.cancel(requestID: id)
        case .mimoV26(let runtime): runtime.cancel(requestID: id)
        case .glm5Next(let runtime): runtime.cancel(requestID: id)
        }
    }
    func keepWarmPulse() throws -> UInt64 {
        switch owner {
        case .qwenDense(let runtime): try runtime.keepWarmPulse()
        case .qwenTensorParallel(let runtime): try runtime.keepWarmPulse()
        case .glm5NextTensorParallel(let runtime): try runtime.keepWarmPulse()
        case .mimoV26(let runtime): try runtime.keepWarmPulse()
        case .glm5Next(let runtime): try runtime.keepWarmPulse()
        }
    }
    func dataPlanePing() throws -> UInt64 {
        switch owner {
        case .qwenDense(let runtime): try runtime.dataPlanePing()
        case .qwenTensorParallel(let runtime): try runtime.dataPlanePing()
        case .glm5NextTensorParallel(let runtime): try runtime.dataPlanePing()
        case .mimoV26(let runtime): try runtime.dataPlanePing()
        case .glm5Next(let runtime): try runtime.dataPlanePing()
        }
    }
    func shutdown() throws {
        switch owner {
        case .qwenDense(let runtime): try runtime.shutdown()
        case .qwenTensorParallel(let runtime): try runtime.shutdown()
        case .glm5NextTensorParallel(let runtime): try runtime.shutdown()
        case .mimoV26(let runtime): try runtime.shutdown()
        case .glm5Next(let runtime): try runtime.shutdown()
        }
    }
}
