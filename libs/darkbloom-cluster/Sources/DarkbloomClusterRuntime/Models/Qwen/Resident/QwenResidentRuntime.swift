import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

/// Synchronous, process-local native owner for the worker's private executor.
/// Only cancel/readiness may run on its separate control thread. Concurrent
/// reserve/start/shutdown calls refuse instead of overlapping MLX work.
///
/// A hard enclosing worker/process deadline is REQUIRED: cooperative checks
/// cannot interrupt a blocked native collective. On any throw, withdraw this
/// worker and fence/cancel its peer out of band; do not publish a retired event
/// merely because the call threw or a timer elapsed. shutdown releases only this
/// process's weights. Provider lease retirement remains the two-worker owner's job.
public final class QwenResidentRuntime {
    let admission: QwenResidentAdmission
    let control: QwenResidentControl
    let collective: Collective
    let baseReady: ClusterWorkerReady
    private let operation = NSLock()
    private let lifecycle: QwenLayerStageResidentLifecycle
    private var stage: QwenResidentLoadedStage?
    private weak var model: Module?
    private var reservation: QwenResidentReservation?
    private var processLeaseOwned = true

    init(admission: QwenResidentAdmission, control: QwenResidentControl, collective: Collective,
         stage: QwenResidentLoadedStage, capacity: Int, lifecycle: QwenLayerStageResidentLifecycle) {
        self.admission = admission; self.control = control; self.collective = collective
        self.stage = stage; model = stage.loaded.model; self.lifecycle = lifecycle
        baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
            profile: admission.wireProfile, executionPlanSHA256: admission.plan.fingerprint,
            requestCapacityBytes: capacity)
    }

    public var readiness: ClusterWorkerReady? {
        guard control.available, (try? control.check()) != nil else { return nil }
        return baseReady
    }

    /// Named local recording ceiling, available only after the existing bilateral
    /// load and while idle. This query allocates no request state and does not
    /// replace live admission at reserve/start or the enclosing process fence.
    @_spi(Benchmark) public func recordingReadiness(prefillPolicy: QwenResidentPrefillPolicy = .serial) throws -> ClusterWorkerReady? {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available, (try? control.check()) != nil else { return nil }
        let capacity = try recordingCapacity(prefillPolicy)
        try control.check()
        return .init(identity: baseReady.identity, rank: baseReady.rank, profile: baseReady.profile,
            executionPlanSHA256: baseReady.executionPlanSHA256, requestCapacityBytes: capacity)
    }

    private func prefillAllowance(_ policy: QwenResidentPrefillPolicy, promptCount: Int,
                                  chunkSize: Int) throws -> QwenGenerationPrefillAllowance? {
        try QwenResidentPrefillSelection.allowance(policy, rank: collective.rank,
            promptCount: promptCount, chunkSize: chunkSize,
            hiddenSize: admission.profile.hiddenSize,
            elementBytes: qwenStageWireElementBytes(admission.profile.activationDType),
            bound: QwenResidentResourceEnvironment.allocationBound)
    }
    private func recordingCapacity(_ policy: QwenResidentPrefillPolicy) throws -> Int {
        let base = try maximumRecordingCharge().reservedBytes
        let extra = try prefillAllowance(policy, promptCount: admission.profile.maximumPromptTokens,
            chunkSize: admission.profile.maximumChunkTokens)
        return try QwenLongPrefillCheckedBytes.sum([base, extra?.reservedBytes ?? 0])
    }

    private func maximumRecordingCharge() throws -> QwenResidentRecordingCharge {
        guard let stage else { throw ProbeError("Resident model already released") }
        let base = try QwenResidentRequestAllowance.derive(profile: stage.profile, plan: admission.plan,
            rank: collective.rank, maximumTokens: admission.profile.maximumContextTokens,
            chunkSize: admission.profile.maximumChunkTokens, bound: QwenResidentResourceEnvironment.allocationBound)
        guard base.reservedBytes <= baseReady.requestCapacityBytes else {
            throw ProbeError("Recording maximum differs from the admitted resident base ceiling")
        }
        return try .derive(base: base, rank: collective.rank, vocabularySize: admission.profile.vocabularySize,
            activationDType: admission.profile.activationDType, bound: QwenResidentResourceEnvironment.allocationBound)
    }

    /// Metadata/native resource reservation only; no request state or forward.
    /// Returned bytes are this rank's named allowance, not combined peer RAM.
    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        try reserve(requestID: requestID, request: value, mode: .serving,
            prefillPolicy: QwenResidentPrefillSelection.policy(admission.configuration.prefillSchedule))
    }

    /// Charges the original state/fusion allowance plus both named host/native
    /// capture terms. Both workers must use recording reservations; a serving
    /// reservation cannot be upgraded at start or by a live resource check.
    @_spi(Benchmark) public func reserveRecording(requestID: UUID, request value: ClusterWorkerReservation,
        prefillPolicy: QwenResidentPrefillPolicy = .serial) throws -> Int {
        try reserve(requestID: requestID, request: value, mode: .recording, prefillPolicy: prefillPolicy)
    }

    private func reserve(requestID: UUID, request value: ClusterWorkerReservation,
                         mode: QwenResidentRequestMode, prefillPolicy: QwenResidentPrefillPolicy = .serial) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
        try control.check(); try control.reserve(requestID)
        do {
            guard let stage else { throw ProbeError("Resident model already released") }
            let allowance = try QwenResidentRequestAllowance.derive(profile: stage.profile,
                plan: admission.plan, rank: collective.rank, maximumTokens: request.maximumTokens,
                chunkSize: min(request.chunkSize, request.promptCount), bound: QwenResidentResourceEnvironment.allocationBound)
            let prefill = try prefillAllowance(prefillPolicy, promptCount: request.promptCount, chunkSize: request.chunkSize)
            let charge: QwenResidentRecordingCharge?
            if mode == .recording {
                let recording = try QwenResidentRecordingCharge.derive(base: allowance, rank: collective.rank,
                    vocabularySize: request.profile.vocabularySize, activationDType: request.profile.activationDType,
                    bound: QwenResidentResourceEnvironment.allocationBound)
                if let prefill {
                    try prefill.requireCapacity(baseBytes: recording.reservedBytes, ownerLimit: value.capacityLimitBytes,
                        readinessLimit: recordingCapacity(prefillPolicy))
                } else {
                    try recording.requireCapacity(ownerLimit: value.capacityLimitBytes,
                        readinessLimit: maximumRecordingCharge().reservedBytes)
                }
                // Reuse the actual diagnostic source/request/allocator binding
                // and live policy; no caller-supplied budget grants permission.
                let resources = try QwenGenerationDiagnosticResources(loaded: stage.loaded, profile: stage.profile,
                    plan: admission.plan, request: request, rank: collective.rank, requestAllowance: allowance)
                try recording.requireCapture(resources.budget)
                charge = recording
            } else {
                if let prefill {
                    try prefill.requireCapacity(baseBytes: allowance.reservedBytes,
                        ownerLimit: value.capacityLimitBytes, readinessLimit: baseReady.requestCapacityBytes)
                } else {
                    guard allowance.reservedBytes <= value.capacityLimitBytes,
                          allowance.reservedBytes <= baseReady.requestCapacityBytes else {
                        throw ProbeError("Resident reservation exceeds its additional owner capacity ceiling")
                    }
                }
                charge = nil
            }
            let reserved = QwenResidentReservation(request: request, allowance: allowance,
                deadline: value.deadlineUptimeNanoseconds, mode: mode, recordingCharge: charge,
                prefillPolicy: prefillPolicy, prefillAllowance: prefill)
            try reserved.requireLive()
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            reservation = reserved
            return try QwenLongPrefillCheckedBytes.sum([charge?.reservedBytes ?? allowance.reservedBytes,
                prefill?.reservedBytes ?? 0])
        } catch { control.fail(); throw error }
    }

    /// Only rank0 invokes the callback, after both ranks commit/accept the token.
    /// False requests agreed clean stop; a thrown callback is abnormal failure.
    public func start(requestID: UUID,
                      onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        try execute(requestID: requestID, mode: .serving, onCommittedToken: onCommittedToken) { completion, _ in completion }
    }

    /// Returns bounded CPU evidence only after bilateral retirement, local
    /// lifecycle exit and encoding. No tensors or model handle cross this SPI.
    @_spi(Benchmark) public func startRecording(requestID: UUID,
        onCommittedToken: (Int, Int, Int) throws -> Bool
    ) throws -> QwenResidentRecordingCompletion {
        try execute(requestID: requestID, mode: .recording, onCommittedToken: onCommittedToken) { completion, evidence in
            guard let evidence else { throw ProbeError("Recording request returned no diagnostic evidence") }
            return .init(completion: completion, encodedEvidence: try evidence.encoded())
        }
    }

    private func execute<Output>(requestID: UUID, mode: QwenResidentRequestMode,
        onCommittedToken: (Int, Int, Int) throws -> Bool,
        prepare: (QwenResidentGenerationCompletion, QwenGenerationDiagnosticEvidence?) throws -> Output
    ) throws -> Output {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID else {
            throw ProbeError("Resident start has no matching reservation")
        }
        try reserved.mode.require(mode)
        do {
            guard reserved.prefillAllowance == (try prefillAllowance(reserved.prefillPolicy,
                promptCount: reserved.request.promptCount, chunkSize: reserved.request.chunkSize)) else {
                throw ProbeError("Lookahead allowance changed since reservation")
            }
            let value = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
                identity: .init(requestID: requestID, epoch: requestID,
                    recordedRequestFingerprint: reserved.request.fingerprint), deadline: reserved.deadline, body: {
                try autoreleasepool {
                    guard let stage else { throw ProbeError("Resident model already released") }
                    return try QwenResidentRequestExecution.run(stage: stage, admission: admission,
                        collective: collective, control: control, reserved: reserved,
                        onCommittedToken: onCommittedToken)
                }
            }, prepare: { try prepare($0.0, $0.1) })
            // Output is fully prepared and control completed before this slot
            // is cleared. A thrown encode keeps the failed owner unavailable.
            reservation = nil
            return value
        } catch { control.fail(); throw error }
    }

    public func cancel(requestID: UUID) { control.cancel(requestID) }

    /// Local release only. On failure the external owner must retain/fence its
    /// peer and must not manufacture a successful request-retirement event.
    public func shutdown() throws {
        guard operation.try() else { throw ProbeError("Cannot release a running native request") }
        defer { operation.unlock() }
        try control.beginClose()
        do {
            try lifecycle.withModelRelease {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    reservation = nil; stage = nil
                    guard model == nil else { throw ProbeError("Resident model remains retained") }
                    Memory.clearCache(); try error.check()
                }
            }
            control.closed()
            processLeaseOwned = false; QwenResidentProcessLease.shared.release()
        } catch { control.fail(); throw error }
    }

    deinit {
        // Explicit shutdown is required. Do not reopen the process-wide native
        // admission if a caller dropped an owner without acknowledged cleanup.
        if processLeaseOwned { control.fail() }
    }
}
