import Foundation
import MLX

/// One reservation charges simultaneous target, assistant, provisional outputs,
/// native transfers and CPU evidence. No sum of independently passing gates is
/// treated as a combined allowance. Loaded weights/caches remain in MLX active.
struct QwenMTPAcceptedResources {
    let base: QwenResidentRequestAllowance
    let assistant: QwenResidentMTPRequestResources?
    let verification: QwenTargetVerificationBudget
    let recording: QwenResidentRecordingCharge
    let additionalNativeBytes: Int
    let additionalHostBytes: Int
    let reservedBytes: Int

    init(loaded: QwenResidentLoadedStage, assets: QwenResidentStageWithMTPAssets?,
         agreement: QwenLayerStageGenerationAgreement, plan: QwenLayerStagePlan) throws {
        let rank = loaded.loaded.stageIndex, request = agreement.request
        guard loaded.profile.model == .qwen35NineB, plan.stages.count == 2,
              plan.stages[0].sourceRange == 0..<4, (0...1).contains(rank),
              (assets != nil) == (rank == 1), loaded.loaded.activationDType == .bfloat16,
              agreement.prefillPolicy == .serial, (1...32).contains(request.promptCount),
              request.chunkSize <= 16, (2...8).contains(request.outputCount), request.stopTokenIDs.isEmpty else {
            throw ProbeError("Accepted MTP requires exact registered cut4/BF16/serial9B P<=32/C<=16/O2...8")
        }
        if let assets {
            guard assets.target.loaded.model === loaded.loaded.model,
                  sha256(try canonicalJSONData(assets.target.loaded.receipt)) == sha256(try canonicalJSONData(loaded.loaded.receipt)) else {
                throw ProbeError("MTP assistant assets belong to another native target owner")
            }
        }
        base = try .derive(profile: loaded.profile, plan: plan, rank: rank,
            maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount),
            bound: QwenResidentResourceEnvironment.allocationBound)
        assistant = try assets.map { try QwenResidentMTPRequestResources(assets: $0, plan: plan, agreement: agreement, capacityLimitBytes: Int.max) }
        verification = try .derive(hiddenSize: request.profile.hiddenSize,
            vocabularySize: request.profile.vocabularySize, dtypeBytes: 2, rank: rank, steps: 2,
            bound: QwenResidentResourceEnvironment.allocationBound)
        recording = try .derive(base: base, rank: rank, vocabularySize: request.profile.vocabularySize,
            activationDType: request.profile.activationDType, bound: QwenResidentResourceEnvironment.allocationBound)
        let sum = QwenLongPrefillCheckedBytes.sum, bound = QwenResidentResourceEnvironment.allocationBound
        // Additional carry/finalization roots coexist with the two target rows
        // and retained assistant roots until the final bilateral reconciliation.
        // Eight short hidden roots conservatively cover both dtype promotions.
        let finalization = rank == 1 ? try QwenLongPrefillCheckedBytes.product([8, bound(request.profile.hiddenSize * 4)]) : 0
        // The original single-proposal ledger uses prompt length. Later rounds
        // can attend beyond that frontier, and P1 can retain two feed rows.
        // Charge another complete graph at maximum context; do not subtract
        // the original prompt graph or assume its roots have already retired.
        let repeated = rank == 1 ? try Self.repeatedAssistantBytes(
            maximumInputs: request.maximumTokens, bound: bound) : 0
        additionalNativeBytes = try sum([assistant?.additionalBytes ?? 0, repeated,
            verification.additionalNativeBytes, recording.capture.extraNativeBytes,
            finalization, bound(4096), bound(4096), bound(64), bound(4)])
        // Retain the diagnostic row plus bounded control/round descriptors and
        // a 16MiB JSON publication allowance through encoding and sink return.
        additionalHostBytes = try sum([verification.additionalHostBytes,
            recording.capture.extraHostBytes, 65_536, 16_777_216])
        reservedBytes = try sum([base.reservedBytes, additionalNativeBytes, additionalHostBytes])
        try requireLive()
    }
    private static func repeatedAssistantBytes(maximumInputs n: Int,
        bound: (Int) throws -> Int) throws -> Int {
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let h = 4096, kv = 1024
        let arrays: [(count: Int, shape: [Int])] = [
            (2,[n,h,4]), (1,[n,h,4]), (2,[n,4]), (3,[n,h,4]),
            (1,[n,2,h,4]), (2,[n,h,4]), (4,[n,kv,4]),
            (8,[2,h,4]), (4,[12288,4]), (4,[16,n,4]), (1,[248320,4]), (1,[4]),
        ]
        return try sum(arrays.map { item in try product([item.count, bound(product(item.shape))]) })
    }
    func requireLive() throws {
        try base.requireLive(additionalNativeBytes: additionalNativeBytes, additionalHostBytes: additionalHostBytes)
    }
    func requireVerification(_ value: QwenTargetVerificationBudget) throws {
        guard value.additionalNativeBytes <= verification.additionalNativeBytes,
              value.additionalHostBytes <= verification.additionalHostBytes else {
            throw ProbeError("MTP transaction exceeds the retained combined reservation")
        }
        try requireLive()
    }
}
