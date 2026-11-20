import Foundation
import MLX
import MLXLLM
@_spi(Cluster) import MLXLMCommon

/// Named tensor allowance, not a claim to predict every kernel workspace.
/// Existing live allocator/OS headroom and6GiB floor remain mandatory. The
/// loaded target,31 head tensors and3 replica tensors are already active memory.
struct QwenResidentMTPRequestResources {
    let base: QwenResidentRequestAllowance
    let assistantStateBytes: Int
    let captureAndProposalBytes: Int
    let additionalBytes: Int
    let requiredReservationBytes: Int

    init(assets: QwenResidentStageWithMTPAssets, plan: QwenLayerStagePlan,
         agreement: QwenLayerStageGenerationAgreement, capacityLimitBytes: Int) throws {
        let target = assets.target, loaded = target.loaded, request = agreement.request
        guard target.profile.model == .qwen35NineB, loaded.stageIndex == 1,
              loaded.plan.fingerprint == plan.fingerprint, plan.stages.count == 2,
              plan.stages[0].sourceRange.count == 4,
              request.promptCount <= 8192, request.chunkSize <= 512, (2...128).contains(request.outputCount),
              request.profile.hiddenSize == 4096, request.profile.vocabularySize == 248320,
              request.profile.activationDType == "bfloat16", loaded.activationDType == .bfloat16,
              agreement.prefillPolicy == .serial,
              agreement.descriptor.planFingerprint == plan.fingerprint,
              agreement.descriptor.stageFingerprints == plan.stages.map(\.fingerprint),
              agreement.descriptor.sourceConfigurationSHA256 == loaded.receipt.sourceConfigurationSHA256,
              agreement.descriptor.artifactAggregateSHA256 == loaded.receipt.verifiedAggregateSHA256,
              agreement.descriptor.storageCommitmentSHA256 == loaded.receipt.storageCommitmentSHA256,
              assets.receipt.targetLoadReceiptSHA256 == sha256(try canonicalJSONData(loaded.receipt)),
              assets.receipt.loadedTensorBytes == 709_010_432,
              assets.receipt.placement.targetPlanSHA256 == plan.fingerprint,
              assets.assistant.requiredVerificationMode == .serialTarget,
              assets.assistant.maximumSpeculativeBatch == 1,
              assets.assistant.draftShortlistSize == nil,
              let actualTarget = loaded.model as? any CBv2RecurrentMTPForwardable,
              assets.assistant.targetIdentity == actualTarget.cbv2MTPTargetIdentity else {
            throw ProbeError("MTP proposal resources require the exact loaded cut4/BF16/serial9B owner")
        }
        // No process-global shortlist or historical double-forward oracle may
        // silently change this one-proposal path.
        for key in ["DARKBLOOM_QWEN_MTP_DOUBLE_FORWARD", "DARKBLOOM_QWEN_MTP_SHORTLIST"] {
            guard ProcessInfo.processInfo.environment[key] == nil else {
                throw ProbeError("MTP proposal refuses an ambient draft override")
            }
        }
        guard let specs = assets.assistant.requestStateAllocationSpecs, specs.count == 3,
              let policy = Memory.allocationFootprintPolicy(),
              let auxiliary = cbv2ClusterAuxiliaryAllocationBytes(tokens: request.maximumTokens,
                  policy: policy, specs: specs), auxiliary > 0 else {
            throw ProbeError("MTP proposal lacks actual assistant allocator geometry")
        }
        base = try .derive(profile: target.profile, plan: plan, rank: 1,
            maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount),
            bound: QwenResidentResourceEnvironment.allocationBound)
        assistantStateBytes = auxiliary
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let p = request.promptCount, c = min(request.chunkSize, p), h = 4096, kv = 1024
        // F32 bounds cover BF16 intermediates conservatively. Whole-history
        // fusion is limited to the one-layer KV-only-prefix implementation:
        // concatenate history; embed+normalize; hidden normalize; concatenate
        // features; FC; layer norm; K projection+norm+rope; V projection.
        let arrays: [(count: Int, shape: [Int])] = [
            (2,[c,h,4]), (1,[p,h,4]), (2,[p,4]), (3,[p,h,4]),
            (1,[p,2,h,4]), (2,[p,h,4]), (4,[p,kv,4]),
            (8,[2,h,4]), (4,[12288,4]), (4,[16,p,4]), (1,[248320,4]), (1,[4]),
        ]
        captureAndProposalBytes = try sum(arrays.map { item in
            try product([item.count, QwenResidentResourceEnvironment.allocationBound(product(item.shape))])
        })
        // A growing KV allocation may coexist with its previous generation.
        // Retain a second complete assistant allowance until proposal disposal.
        additionalBytes = try sum([product([2, auxiliary]), captureAndProposalBytes])
        requiredReservationBytes = try sum([base.reservedBytes, additionalBytes])
        guard capacityLimitBytes >= requiredReservationBytes else {
            throw ProbeError("MTP proposal exceeds the caller's retained request reservation")
        }
        try requireLive()
    }

    func requireLive() throws { try base.requireLive(additionalNativeBytes: additionalBytes) }
}
