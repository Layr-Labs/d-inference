import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

public struct QwenResidentGenerationCompletion: Sendable {
    public let requestID: UUID
    public let finishReason: ClusterWorkerFinishReason
    public let selectedTokenIDs: [Int]
    public let completedFrames: Int
    public let committedTokens: Int
    public let tokenChainSHA256: String
    public let bothRequestStatesRetired: Bool
    public let physicalTransferQualified = false
    public let independentNumericalComparisonPerformed = false
    public let externalTTFTMeasured = false
}

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
    private var reservation: (request: QwenLayerStageGenerationRequest, allowance: QwenResidentRequestAllowance, deadline: UInt64)?
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

    /// Metadata/native resource reservation only; no request state or forward.
    /// Returned bytes are this rank's named allowance, not combined peer RAM.
    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
        try control.check(); try control.reserve(requestID)
        do {
            guard let stage else { throw ProbeError("Resident model already released") }
            let allowance = try QwenResidentRequestAllowance.derive(profile: stage.profile,
                plan: admission.plan, rank: collective.rank, maximumTokens: request.maximumTokens,
                chunkSize: min(request.chunkSize, request.promptCount), bound: QwenResidentResourceEnvironment.allocationBound)
            guard allowance.reservedBytes <= value.capacityLimitBytes,
                  allowance.reservedBytes <= baseReady.requestCapacityBytes else {
                throw ProbeError("Resident reservation exceeds its additional owner capacity ceiling")
            }
            try allowance.requireLive(); try control.check(deadline: value.deadlineUptimeNanoseconds)
            reservation = (request, allowance, value.deadlineUptimeNanoseconds)
            return allowance.reservedBytes
        } catch { control.fail(); throw error }
    }

    /// Only rank0 invokes the callback, after both ranks commit/accept the token.
    /// False requests agreed clean stop; a thrown callback is abnormal failure.
    public func start(requestID: UUID,
                      onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID else {
            throw ProbeError("Resident start has no matching reservation")
        }
        try control.start(requestID)
        do {
            let value = try lifecycle.withRequest(identity: .init(requestID: requestID, epoch: requestID,
                recordedRequestFingerprint: reserved.request.fingerprint)) {
                try autoreleasepool {
                    guard let stage else { throw ProbeError("Resident model already released") }
                    let receipt = stage.loaded.receipt
                    let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
                        artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
                        storageCommitmentSHA256: receipt.storageCommitmentSHA256,
                        planFingerprint: admission.plan.fingerprint,
                        producerStageFingerprint: admission.plan.stages[0].fingerprint)
                    let agreement = try QwenLayerStageGenerationAgreement(request: reserved.request,
                        membershipEpoch: admission.configuration.identity.membershipEpoch,
                        source: source, consumerStageFingerprint: admission.plan.stages[1].fingerprint,
                        rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
                        numericalPolicySHA256: admission.arithmeticSHA256)
                    var lastResourceCheck: UInt64 = 0, ordinal = 0
                    func check() throws {
                        try control.check(deadline: reserved.deadline)
                        let now = DispatchTime.now().uptimeNanoseconds
                        if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                            try reserved.allowance.requireLive(); lastResourceCheck = DispatchTime.now().uptimeNanoseconds
                        }
                        try control.check(deadline: reserved.deadline)
                    }
                    try check()
                    let result = try runQwenLayerStageGenerationRequest(loaded: stage.loaded,
                        plan: admission.plan, agreement: agreement, collective: collective,
                        onCommittedToken: { token in
                            let current = ordinal; ordinal += 1
                            return try onCommittedToken(current, token, reserved.request.promptCount + current)
                        }, check: check)
                    guard result.bothRequestStatesRetired,
                          let reason = ClusterWorkerFinishReason(rawValue: result.finishReason.rawValue) else {
                        throw ProbeError("Resident generation returned without clean bilateral retirement")
                    }
                    return QwenResidentGenerationCompletion(requestID: requestID, finishReason: reason,
                        selectedTokenIDs: result.selectedTokenIDs, completedFrames: result.completedFrames,
                        committedTokens: result.committedTokens, tokenChainSHA256: result.tokenChainSHA256,
                        bothRequestStatesRetired: true)
                }
            }
            // Publication occurs after the lifecycle and complete native scope.
            try control.completed(requestID); reservation = nil
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
