import DarkbloomClusterProtocol
@_spi(Benchmark) import DarkbloomClusterRuntime
import Foundation

/// The GPT-OSS layer-stage adapter behind the worker's runtime contract. One
/// type serves both entries: without an evidence directory it runs the serving
/// path, with one it runs the recording entry of the same resident owner and
/// writes this rank's evidence before `finished` is published. Exactly one
/// native executor uses it; cancel is the owner's thread-safe operation.
final class GPTOSSWorkerRuntime: WorkerRuntime, @unchecked Sendable {
    private let owner: GPTOSSResidentRuntime
    private let sink: WorkerEvidenceSink?
    private var active: (id: UUID, deadline: UInt64)?

    static func handles(modelID: String) -> Bool { GPTOSSResidentCapabilityMetadata.handles(runtimeModelID: modelID) }

    init(_ configuration: QwenResidentLoadConfiguration, bootstrap: WorkerBootstrapConfiguration? = nil,
         evidenceDirectory: String?, generationMode: ClusterGenerationMode = .pipeline,
         qualification: QwenResidentQualificationSwitches = .refused) throws {
        guard bootstrap == nil else {
            throw WorkerFailure.invalid("The authenticated bootstrap attachment is not available in this build")
        }
        // Opened before any model work: an unusable directory fails the launch.
        sink = try evidenceDirectory.map { try WorkerEvidenceSink(path: $0) }
        owner = try .load(configuration, generationMode: generationMode, qualification: qualification)
    }

    var readiness: ClusterWorkerReady? {
        sink == nil ? owner.readiness : (try? owner.recordingReadiness()) ?? nil
    }

    func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        guard sink != nil else { return try owner.reserve(requestID: id, request: value) }
        guard active == nil else { throw WorkerFailure.invalid("Recording request already active") }
        let bytes = try owner.reserveRecording(requestID: id, request: value)
        active = (id, value.deadlineUptimeNanoseconds)
        return bytes
    }

    func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason {
        guard let sink else {
            let result = try owner.start(requestID: id, onCommittedToken: token)
            guard result.bothRequestStatesRetired else {
                throw WorkerFailure.invalid("Native generation did not retire both request states")
            }
            return result.finishReason
        }
        guard let reservation = active, reservation.id == id else {
            throw WorkerFailure.invalid("Recording start has no matching reservation")
        }
        let result = try owner.startRecording(requestID: id, onCommittedToken: token)
        guard result.completion.requestID == id, result.completion.bothRequestStatesRetired else {
            throw WorkerFailure.invalid("Recording generation returned without matching retirement")
        }
        // The coordinator cannot publish finished/retired until this returns. A
        // write failure fails the worker; no successful sidecar is fabricated.
        try sink.publish(result.encodedEvidence, requestID: id, deadline: reservation.deadline)
        active = nil
        return result.completion.finishReason
    }

    func cancel(_ id: UUID) { owner.cancel(requestID: id) }
    func shutdown() throws { try owner.shutdown(); active = nil }
}
