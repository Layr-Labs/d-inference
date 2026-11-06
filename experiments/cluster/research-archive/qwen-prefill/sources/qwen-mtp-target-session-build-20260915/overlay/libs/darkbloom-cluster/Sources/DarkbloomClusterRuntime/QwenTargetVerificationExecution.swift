import MLX
@_spi(Cluster) import MLXLLM
import MLXLMCommon

/// Serialized target-only native work. The session owns it until resolution or
/// whole-request retirement. No assistant, peer ACK or output publication here.
final class QwenTargetVerificationExecution {
    let request: QwenTargetVerificationRequest
    let resources: QwenTargetVerificationResourceAuthority
    private let stage: LoadedQwenLayerStage
    private let state: CBv2OwnedRequestState
    private var stagedOutputs: [MLXArray] = []
    private var stagedHidden: [MLXArray] = []
    private var activeHidden: MLXArray?
    var stagedCount: Int { stagedOutputs.count }
    private(set) var committedCount = 0

    convenience init(request: QwenTargetVerificationRequest, profile: QwenRegisteredDenseModelProfile,
         stage: LoadedQwenLayerStage, identity: QwenLayerStageSessionIdentity,
         state: CBv2OwnedRequestState, schedule: QwenLayerStageAdmittedSchedule) throws {
        try self.init(request: request, stage: stage, identity: identity, state: state, schedule: schedule) {
            .registered(try .init(loaded: stage, profile: profile, request: request))
        }
    }

    #if QWEN_TARGET_TINY_FIXTURE
    convenience init(request: QwenTargetVerificationRequest, tiny: QwenTinyTargetFixtureResources,
         stage: LoadedQwenLayerStage, identity: QwenLayerStageSessionIdentity,
         state: CBv2OwnedRequestState, schedule: QwenLayerStageAdmittedSchedule) throws {
        try self.init(request: request, stage: stage, identity: identity, state: state, schedule: schedule) {
            .tiny(try tiny.authority(stage: stage, request: request))
        }
    }
    #endif

    private init(request: QwenTargetVerificationRequest, stage: LoadedQwenLayerStage,
         identity: QwenLayerStageSessionIdentity, state: CBv2OwnedRequestState,
         schedule: QwenLayerStageAdmittedSchedule,
         makeResources: () throws -> QwenTargetVerificationResourceAuthority) throws {
        let a = request.agreement.descriptor
        guard (0...1).contains(stage.stageIndex), a.stageFingerprints.count == 2,
              identity.requestFingerprint == request.agreement.request.fingerprint,
              identity.sourceConfigurationSHA256 == a.sourceConfigurationSHA256,
              identity.artifactAggregateSHA256 == a.artifactAggregateSHA256,
              identity.storageCommitmentSHA256 == a.storageCommitmentSHA256,
              identity.planFingerprint == a.planFingerprint,
              identity.stageFingerprint == a.stageFingerprints[stage.stageIndex],
              state.committedTokens == request.base, schedule.committedTokens == request.base,
              schedule.nextSequence == request.descriptor.firstSequence else {
            throw ProbeError("Target verification does not bind this loaded session and frontier")
        }
        self.request = request; self.stage = stage; self.state = state
        resources = try makeResources()
    }

    func begin(ownerCheck: (QwenTargetVerificationBudget) throws -> Void) throws {
        try native(ownerCheck: ownerCheck) { checked in
            try state.beginVerification(maximumSteps: request.maximumSteps, check: checked)
        }
    }

    func stage(step: Int, incoming: QwenTargetVerificationBoundary?,
               ownerCheck: (QwenTargetVerificationBudget) throws -> Void) throws -> QwenTargetVerificationOutput {
        try native(ownerCheck: ownerCheck) { checked in
            guard step == stagedCount, activeHidden == nil else { throw ProbeError("Target verification step is out of order") }
            let token = try request.token(step: step)
            if stage.stageIndex == 0 {
                guard incoming == nil else { throw ProbeError("Target verification rank0 rejects residual ingress") }
            } else {
                guard let incoming else { throw ProbeError("Target verification rank1 requires provisional residual ingress") }
                try incoming.validate(request: request, step: step, dtype: stage.activationDType)
            }
            try checked()
            let input = MLXArray([Int32(token)]).reshaped([1, 1])
            let output = try state.stageVerification(check: checked,
                additionalTargets: { self.activeHidden.map { [$0] } ?? [] }, forward: { caches, evaluation in
                    if self.stage.stageIndex == 0 {
                        let model = self.stage.model as! any CBv2RecurrentMTPForwardable
                        return model.cbv2ForwardWithHidden(input, caches: caches.map { $0 as! any KVCache },
                            recurrentState: [evaluation], positionIds: nil).lastHidden
                    }
                    let value = try Qwen35ClusterMTPForward.forward(target: self.stage.model, tokens: input,
                        residual: incoming!.array, caches: caches.map { $0 as! any KVCache },
                        recurrentState: [evaluation], output: .decodeLastLogits)
                    try checked() // native-primary before secondary Swift shape checks
                    self.activeHidden = value.preNormHidden
                    return value.value
                }, validateOutput: { output in
                    let profile = self.request.agreement.request.profile
                    let shape = self.stage.stageIndex == 0 ? [1, 1, profile.hiddenSize] : [1, profile.vocabularySize]
                    guard output.shape == shape, [.float16, .bfloat16, .float32].contains(output.dtype),
                          self.stage.stageIndex != 0 || output.dtype == self.stage.activationDType else {
                        throw ProbeError("Provisional target output differs from the loaded geometry")
                    }
                    if self.stage.stageIndex == 1 {
                        guard let h = self.activeHidden, h.shape == [1, 1, profile.hiddenSize],
                              h.dtype == self.stage.activationDType else { throw ProbeError("Provisional pre-norm hidden differs") }
                    }
                })
            stagedOutputs.append(output)
            if let activeHidden { stagedHidden.append(activeHidden); self.activeHidden = nil }
            if stage.stageIndex == 0 {
                let digest = sha256(output.asData().data); try checked()
                return .provisionalHidden(.init(verificationFingerprint: request.fingerprint,
                    producerStageFingerprint: request.agreement.descriptor.stageFingerprints[0],
                    step: step, tokenID: token, payloadSHA256: digest, array: output))
            }
            return .provisionalLogits(output)
        }
    }

    func commitNext(ownerCheck: (QwenTargetVerificationBudget) throws -> Void) throws -> QwenTargetVerificationCommit {
        try native(ownerCheck: ownerCheck) { checked in
            guard activeHidden == nil, committedCount < stagedCount else {
                throw ProbeError("Target verification has no oldest pending output")
            }
            let previous = committedCount
            let committed = try state.commitNextVerification(check: checked)
            committedCount += 1
            let rows = Array(stagedHidden.dropFirst(previous).prefix(1))
            let receipt = QwenTargetVerificationLocalReceipt(verificationFingerprint: request.fingerprint,
                rank: stage.stageIndex, base: request.base, stagedInputs: stagedCount,
                retainedInputs: committedCount, committedInputs: committed,
                pendingInputs: stagedCount - committedCount, newlyCommittedInputs: 1, isFinal: false)
            return .init(receipt: receipt, hidden: rows)
        }
    }

    func reconcile(keeping count: Int, ownerCheck: (QwenTargetVerificationBudget) throws -> Void
    ) throws -> QwenTargetVerificationCommit {
        try native(ownerCheck: ownerCheck) { checked in
            guard activeHidden == nil, (committedCount...stagedCount).contains(count) else { throw ProbeError("Target reconciliation has unfinished work") }
            let staged = stagedCount
            let committed = try state.reconcileVerification(keeping: count, check: checked)
            let newlyCommitted = count - committedCount
            let rows = Array(stagedHidden.dropFirst(committedCount).prefix(newlyCommitted))
            committedCount = count
            let receipt = QwenTargetVerificationLocalReceipt(verificationFingerprint: request.fingerprint,
                rank: stage.stageIndex, base: request.base, stagedInputs: staged,
                retainedInputs: count, committedInputs: committed, pendingInputs: 0,
                newlyCommittedInputs: newlyCommitted, isFinal: true)
            discardOutputs()
            return .init(receipt: receipt, hidden: rows)
        }
    }

    func discardOutputs() { activeHidden = nil; stagedHidden.removeAll(); stagedOutputs.removeAll() }

    private func native<T>(ownerCheck: (QwenTargetVerificationBudget) throws -> Void,
                           _ body: (() throws -> Void) throws -> T) throws -> T {
        // The supplied check is borrowed only for this synchronous handler;
        // neither the callback nor its borrowed form is stored by the helper.
        try withoutActuallyEscaping(ownerCheck) { borrowedCheck in
            try MLX.withError { nativeError in
                do {
                    func checked() throws { try nativeError.check(); try resources.requireLive(ownerCheck: borrowedCheck) }
                    try checked()
                    let value = try body(checked)
                    try nativeError.check()
                    return value
                } catch { try nativeError.check(); throw error }
            }
        }
    }
}
