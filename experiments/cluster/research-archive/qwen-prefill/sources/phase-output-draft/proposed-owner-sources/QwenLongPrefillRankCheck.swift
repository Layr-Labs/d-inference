import Foundation
import MLX
import MLXNN

func runQwenLongPrefillRankCheck(options: Options,
    local: QwenRegistered9BLongPrefillReferenceAdmission, phaseCapture: QwenPrefillPhaseCapture? = nil, check: () throws -> Void
) throws -> QwenLongPrefillRankReport {
    try QwenLongPrefillRankAdmission.validateOptions(options)
    let collective = try Collective(transport: options.transport)
    var memory = [QwenStageMemoryObservation("before_stage_load")]
    weak var model: Module?
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            let result = try autoreleasepool {
                let loaded = try loadVerifiedQwenLayerStage(directory: options.modelDirectory!,
                    originalConfiguration: local.configuration, plan: local.plan, stageIndex: collective.rank,
                    expectedAggregateSHA256: local.resource.expectedArtifactAggregateSHA256)
                model = loaded.model; try checked()
                let phaseRecorder: QwenPrefillPhaseRecorder?
                if let phaseCapture {
                    phaseRecorder = try phaseCapture.makeRecorder(identity: .init(
                        requestFingerprint: local.request.fingerprint,
                        profile: local.request.request.profile.rawValue, role: collective.rank == 0 ? .rank0 : .rank1))
                } else { phaseRecorder = nil }
                let agreement = try qwenLongPrefillRankAgreement(loaded: loaded, local: local, options: options)
                memory.append(QwenStageMemoryObservation("stage_loaded_no_request_state"))
                let execution = try runQwenLongPrefillRankRequest(loaded: loaded, local: local,
                    agreement: agreement, collective: collective, onReady: {
                        try emitJSON(QwenLongPrefillRankReady(epoch: options.epoch!, rank: collective.rank,
                            agreementFingerprint: agreement.fingerprint, agreement: agreement.descriptor,
                            promptFileSHA256: local.promptFileSHA256))
                    }, phaseRecorder: phaseRecorder, check: checked)
                memory.append(QwenStageMemoryObservation("stage_request_retired_weights_resident"))
                return (loaded.receipt, agreement, execution)
            }
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
            guard model == nil else { throw ProbeError("Long rank retained its stage model after request retirement") }
            Memory.clearCache(); try checked()
            memory.append(QwenStageMemoryObservation("stage_model_released_cache_cleared"))
            return .init(epoch: options.epoch!, rank: collective.rank,
                agreementFingerprint: result.1.fingerprint, agreement: result.1.descriptor,
                sourceLoad: result.0, request: local.request, promptFileSHA256: local.promptFileSHA256,
                arithmeticEnvironment: local.arithmetic, arithmeticEnvironmentSHA256: local.arithmeticEnvironmentSHA256,
                resourceAdmission: local.resource, execution: result.2, memory: memory)
        }
    } catch {
        phaseCapture?.fail()
        let primary = error
        var cleanup: [String] = []
        do {
            try MLX.withError { error in
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                Memory.clearCache(); try error.check()
            }
        } catch { cleanup.append(String(describing: error)) }
        if model != nil { cleanup.append("stage model remained retained") }
        if !cleanup.isEmpty {
            throw ProbeError("Long rank failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}

private func qwenLongPrefillRankAgreement(loaded: LoadedQwenLayerStage,
    local: QwenRegistered9BLongPrefillReferenceAdmission, options: Options
) throws -> QwenLayerStageProfiledPrefillStartAgreement {
    let r = loaded.receipt
    let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: r.sourceConfigurationSHA256,
        artifactAggregateSHA256: r.verifiedAggregateSHA256, storageCommitmentSHA256: r.storageCommitmentSHA256,
        planFingerprint: local.plan.fingerprint, producerStageFingerprint: local.plan.stages[0].fingerprint)
    return try .init(epoch: options.epoch!, request: local.request, sourceIdentity: source,
        consumerStageFingerprint: local.plan.stages[1].fingerprint,
        producerConstructionConfigurationSHA256: sha256(local.plan.stages[0].constructionConfiguration),
        consumerConstructionConfigurationSHA256: sha256(local.plan.stages[1].constructionConfiguration),
        bf16ConversionEnabled: r.bf16ConversionEnabled, arithmeticEnvironmentSHA256: local.arithmeticEnvironmentSHA256,
        hiddenSize: local.resource.geometry.hiddenSize, nativeDType: String(describing: loaded.activationDType),
        logitsDType: options.stageLogitsDType!, schedulingPolicy: options.stagePrefillPolicy!)
}
