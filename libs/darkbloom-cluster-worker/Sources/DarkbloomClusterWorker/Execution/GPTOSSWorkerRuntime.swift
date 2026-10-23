import DarkbloomClusterProtocol
@_spi(Benchmark) import DarkbloomClusterRuntime
import DarkbloomClusterSecurity
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

    init(_ configuration: QwenResidentLoadConfiguration, attachment: WorkerOwnerAttachment? = nil,
         evidenceDirectory: String?, generationMode: ClusterGenerationMode = .pipeline,
         qualification: QwenResidentQualificationSwitches = .refused,
         dataPlane: ClusterDataPlaneCredential? = nil) throws {
        _ = try Self.batchLaunchLanes(environment: ProcessInfo.processInfo.environment,
            mode: generationMode, recording: evidenceDirectory != nil)
        self.attachment = attachment
        // Opened before any model work: an unusable directory fails the launch.
        sink = try evidenceDirectory.map { try WorkerEvidenceSink(path: $0) }
        owner = try .load(configuration, generationMode: generationMode, qualification: qualification,
            dataPlane: dataPlane)
        try JACCLOwnerBootstrap.requireConsumedIfInstalled()
    }
    /// The owner's bootstrap connection and native key, held for the worker's lifetime.
    private let attachment: WorkerOwnerAttachment?

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

    /// Recording has a per-request capture contract and stays single-lane.
    /// Refuse this combination before opening an evidence sink or loading.
    static func batchLaunchLanes(environment: [String: String], mode: ClusterGenerationMode,
                                 recording: Bool) throws -> Int {
        let settings = try GPTOSSBatchSettings.fromEnvironment(environment, mode: mode)
        guard !recording || settings.lanes == 1 else {
            throw WorkerFailure.invalid("GPT-OSS recording requires one batch lane")
        }
        return settings.lanes
    }

    var batchLanes: Int { owner.batchLanes }
    var retiresCancelledLanes: Bool {
        sink == nil && owner.generationMode == .pipeline && (2...8).contains(owner.batchLanes)
    }
    func reserveLane(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int {
        guard sink == nil else { throw WorkerFailure.invalid("GPT-OSS recording cannot reserve batch lanes") }
        return try owner.reserveLane(requestID: id, request: value)
    }
    func startLane(_ id: UUID) throws { try owner.startLane(requestID: id) }
    func cancelLane(_ id: UUID) { owner.cancelLane(requestID: id) }
    func withdrawLane(_ id: UUID) -> Bool { owner.withdrawLane(requestID: id) }
    var hasStartedLanes: Bool { owner.hasStartedLanes }
    func serveBatch(host: QwenBatchServingHost) throws {
        guard sink == nil else { throw WorkerFailure.invalid("GPT-OSS recording cannot serve batch lanes") }
        try owner.serveBatch(host: host)
    }

    func releaseReservation(_ id: UUID) throws {
        if sink != nil {
            guard let reservation = active, reservation.id == id else {
                throw WorkerFailure.invalid("Recording release has no matching reservation")
            }
        }
        try owner.releaseReservation(requestID: id)
        active = nil
    }
    func cancel(_ id: UUID) { owner.cancel(requestID: id) }
    func keepWarmPulse() throws -> UInt64 { try owner.keepWarmPulse() }
    func dataPlanePing() throws -> UInt64 { try owner.dataPlanePing() }
    func releaseIdleMemory(underPressure: Bool) -> Int? { ClusterIdleMemory.releaseFreedBuffers() }
    func shutdown() throws { try owner.shutdown(); active = nil }
}
