import Foundation
import MLX

struct QwenLayerStageMTPProbeResult: Encodable {
    let schema = "qwen_stage_single_unaccepted_mtp_proposal_v1"
    let rank: Int
    let probeReadinessFingerprint: String
    let execution: QwenLayerStageGenerationResult
    let proposal: QwenResidentMTPProposal?
    let assistantInputsBeforeProposal: Int?
    let assistantInputsAfterProposal: Int?
    let assistantRequestReleased: Bool?
    let targetSecondToken: Int
    let proposalMatchesTarget: Bool?
    let proposalWasConsumedAsTargetInput = false
    let speculativeAcceptanceImplemented = false
}

/// Private hook over the existing serial driver/transport. It owns no second
/// collective, token channel, supervisor or model copy.
final class QwenLayerStageMTPProbe {
    let readinessFingerprint: String
    private let rank: Int
    private let assets: QwenResidentStageWithMTPAssets?
    private let capacity: Int
    private let deadline: UInt64
    private let agreement: QwenLayerStageGenerationAgreement
    private var owner: QwenResidentMTPRequest?
    private var proposal: QwenResidentMTPProposal?
    private var inputsBeforeProposal: Int?
    private var inputsAfterProposal: Int?

    init(rank: Int, assets: QwenResidentStageWithMTPAssets?, agreement: QwenLayerStageGenerationAgreement,
         capacityLimitBytes: Int, deadlineUptimeNanoseconds: UInt64) throws {
        let request = agreement.request
        guard (0...1).contains(rank), (assets != nil) == (rank == 1), capacityLimitBytes > 0,
              agreement.prefillPolicy == .serial, (1...32).contains(request.promptCount),
              request.chunkSize <= 16, request.outputCount == 2, request.stopTokenIDs.isEmpty else {
            throw ProbeError("Registered MTP probe requires P1...32/C<=16/O2/empty stops and final-rank assets")
        }
        self.rank = rank; self.assets = assets; capacity = capacityLimitBytes
        deadline = deadlineUptimeNanoseconds; self.agreement = agreement
        // Both ranks must explicitly select this probe. An ordinary generation
        // driver presents the unwrapped agreement fingerprint and must disagree.
        readinessFingerprint = sha256(try canonicalJSONData([
            "registered-qwen35-9b-single-unaccepted-proposal-v1", agreement.fingerprint,
            "head-rank1", "replicated-input-embedding", "depth1", "ordinary-target-seed-decode"
        ]))
    }

    func makeSession(loaded: LoadedQwenLayerStage, plan: QwenLayerStagePlan,
                     check: () throws -> Void) throws -> QwenLayerStageSession {
        guard owner == nil else { throw ProbeError("MTP probe was started twice") }
        if rank == 0 { return try .init(stage: loaded, plan: plan, generationRequest: agreement.request) }
        guard let assets, assets.target.loaded.stageIndex == loaded.stageIndex,
              assets.target.loaded.model === loaded.model else { throw ProbeError("MTP probe selected another target owner") }
        let value = try QwenResidentMTPRequest(assets: assets, plan: plan, agreement: agreement,
            capacityLimitBytes: capacity, deadlineUptimeNanoseconds: deadline, check: check)
        owner = value
        return value.probeSession
    }

    func forward(tokens: [Int], frame: QwenLayerStageFrame,
                 incoming: QwenLayerStageBoundary, check: () throws -> Void) throws -> QwenLayerStageOutput {
        guard rank == 1, let owner else { throw ProbeError("MTP probe consumer was not constructed") }
        if frame.phase == .prefill { return try owner.prefill(tokens: tokens, frame: frame, incoming: incoming, check: check) }
        guard tokens.count == 1, proposal != nil else { throw ProbeError("MTP target seed decode precedes proposal") }
        return try owner.decodeSeedForProbe(tokens[0], frame: frame, incoming: incoming, check: check)
    }

    func observedFrame(_ frame: QwenLayerStageFrame, generation: QwenLayerStageGenerationControl,
                       check: () throws -> Void) throws {
        if rank == 1, frame.phase == .prefill {
            guard let owner else { throw ProbeError("MTP history lacks its request owner") }
            try owner.observeCommitted(generation: generation, check: check)
        }
    }

    func afterDecision(generation: QwenLayerStageGenerationControl, check: () throws -> Void) throws {
        if generation.selectedTokenCount == 1 {
            guard generation.phase == .frame else { throw ProbeError("MTP probe stopped before ordinary seed decode") }
            if rank == 1 {
                guard proposal == nil, let owner else { throw ProbeError("MTP probe proposal is duplicated or unowned") }
                guard owner.probeAssistantInputCount == agreement.request.promptCount - 1 else {
                    throw ProbeError("MTP probe history lacks its actual pre-proposal assistant frontier")
                }
                inputsBeforeProposal = owner.probeAssistantInputCount
                proposal = try owner.propose(generation: generation, roundID: UUID(), check: check)
                guard owner.probeAssistantInputCount == agreement.request.promptCount else {
                    throw ProbeError("MTP probe assistant frontier did not consume exactly the seed")
                }
                inputsAfterProposal = owner.probeAssistantInputCount
            }
        }
    }

    func finish(session: QwenLayerStageSession, reason: QwenLayerStageGenerationFinishReason,
                count: Int, lastToken: Int, check: () throws -> Void) throws {
        if let owner { try owner.finishProbe(reason: reason, selectedTokenCount: count, lastTokenID: lastToken, check: check) }
        else { try session.finishGeneration(reason, selectedTokenCount: count, lastTokenID: lastToken) }
    }
    func cancel(session: QwenLayerStageSession?, primary: Error) throws {
        var failures = [String]()
        do { try owner?.retire(failed: true) }
        catch { failures.append("assistant owner: \(error)") }
        // The request owner normally cancels its target too, but its failure
        // must not skip this independently owned driver cleanup obligation.
        do { try session?.cancel() }
        catch { failures.append("target session: \(error)") }
        guard failures.isEmpty else {
            throw ProbeError("Generation failed (\(primary)); local retirement also failed (\(failures.joined(separator: "; ")))")
        }
    }

    func result(_ execution: QwenLayerStageGenerationResult) throws -> QwenLayerStageMTPProbeResult {
        guard execution.bothRequestStatesRetired, execution.selectedTokenIDs.count == 2,
              execution.finishReason == .length, execution.committedTokens == agreement.request.promptCount + 1,
              (rank == 0 && proposal == nil) || (rank == 1 && proposal != nil && owner?.probeAssistantRequestReleased == true) else {
            throw ProbeError("MTP probe result precedes clean ordinary target and assistant retirement")
        }
        let second = execution.selectedTokenIDs[1]
        return .init(rank: rank, probeReadinessFingerprint: readinessFingerprint,
            execution: execution, proposal: proposal,
            assistantInputsBeforeProposal: inputsBeforeProposal, assistantInputsAfterProposal: inputsAfterProposal,
            assistantRequestReleased: owner?.probeAssistantRequestReleased, targetSecondToken: second,
            proposalMatchesTarget: proposal.map { $0.proposedTokenID == second })
    }
}

func probeQwenLayerStageMTPRequest(loaded: LoadedQwenLayerStage, assets: QwenResidentStageWithMTPAssets?,
    plan: QwenLayerStagePlan, agreement: QwenLayerStageGenerationAgreement, collective: Collective,
    capacityLimitBytes: Int, deadlineUptimeNanoseconds: UInt64,
    onCommittedToken: (Int) throws -> Bool, check: () throws -> Void
) throws -> QwenLayerStageMTPProbeResult {
    let probe = try QwenLayerStageMTPProbe(rank: collective.rank, assets: assets, agreement: agreement,
        capacityLimitBytes: capacityLimitBytes, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
    let result = try runQwenLayerStageGenerationCore(loaded: loaded, plan: plan, agreement: agreement,
        collective: collective, diagnostics: nil, probe: probe, onCommittedToken: onCommittedToken, check: check)
    return try probe.result(result)
}
