import Foundation
import MLX

/// What one request costs a tensor-parallel Qwen rank at its own context
/// (prompt plus output tokens), so a row that serves its native context
/// (`QwenDenseRegisteredSpecification.nativeOutputTokens`) needs no
/// service-level cap: LOAD and the planner quote every lane at the memory
/// plan's request (`QwenResidentAdmission.memoryProfile`, the standard
/// 32,768 + 32,768 tokens), and each rank's live memory gate admits a longer
/// request when its charge fits now and refuses it alone otherwise
/// (`reserveLane`, `servingContextTokens`).
///
/// The terms are LOAD's (`QwenTensorParallelBatchBudget`, with the resident
/// assistant `QwenTensorParallelBatchMTPBudget`), at the request's context
/// instead of the memory plan's:
/// - the lane's own state: its KV pages (this rank's heads, BF16), the
///   replacement pages, recurrent state, prefix capture and, with the
///   assistant, its history and gathers;
/// - the workspaces every lane shares, at the longest context any held
///   request has and never below LOAD's: the full-history gather bank of one
///   prompt frame (the batch driver runs at most one a step), the frame's
///   attention scores and the decode and verify transients grow with the
///   context; the pool slack, logits, casts and prefix banks do not.
///
/// The pages themselves grow with the request (`CBv2OwnedRequestState.growReservation`);
/// the charge is the whole request's, admitted once at reservation and held
/// to by every live check that follows.
struct QwenTensorParallelRequestCharge {
    /// One request's charge: its lane and the shared workspaces it needs.
    struct Charge: Equatable {
        let laneBytes: Int
        let sharedBytes: Int
    }

    let geometry: QwenLongPrefillBudgetGeometry
    let plan: QwenTensorParallelPlan
    let tensors: [QwenDenseCanonicalTensor]
    let lanes: Int
    let paged: Bool
    /// The resident assistant's depth and widest cohort; nil without one.
    let assistant: (depth: Int, maximumSpeculativeWidth: Int)?
    let rank: Int?
    let allocationBound: (Int) throws -> Int
    /// LOAD's quote at the memory plan's request: the least every request is charged.
    let loadSharedBytes: Int
    let collectiveScratchBytes: Int

    /// `prompt`/`chunk` are the request's own; `maximumTokens` its prompt plus output.
    func charge(maximumTokens: Int, promptTokens: Int, chunkSize: Int) throws -> Charge {
        let lane: Int, shared: Int
        if let assistant {
            let quote = try QwenTensorParallelBatchMTPBudget.derive(geometry: geometry, plan: plan, tensors: tensors,
                maximumTokens: maximumTokens, promptTokens: promptTokens, chunkSize: chunkSize, lanes: lanes,
                depth: assistant.depth, maximumSpeculativeWidth: assistant.maximumSpeculativeWidth, rank: rank,
                allocationBound: allocationBound)
            lane = quote.perLaneStateBytes; shared = quote.sharedBytesExcludingCollectives
        } else {
            let quote = try QwenTensorParallelBatchBudget.derive(geometry: geometry, plan: plan, tensors: tensors,
                maximumTokens: maximumTokens, chunkSize: chunkSize, lanes: lanes, paged: paged, rank: rank,
                allocationBound: allocationBound)
            lane = quote.perLaneStateBytes; shared = quote.sharedBytesExcludingCollectives
        }
        return .init(laneBytes: lane, sharedBytes: max(loadSharedBytes, shared))
    }

    /// The longest request of `contextTokens` within `profile`: its longest
    /// prompt that leaves an output token, in the profile's chunks.
    func charge(contextTokens: Int, profile: QwenLayerStageGenerationProfile) throws -> Charge {
        guard (2...profile.maximumContextTokens).contains(contextTokens) else {
            throw ProbeError("Qwen tensor-parallel charge needs a context within the profile")
        }
        let prompt = min(profile.maximumPromptTokens, contextTokens - 1)
        return try charge(maximumTokens: contextTokens, promptTokens: prompt,
            chunkSize: min(profile.maximumChunkTokens, prompt))
    }

    /// All of one request's charge on an idle rank, collective scratch included.
    func bytes(contextTokens: Int, profile: QwenLayerStageGenerationProfile) throws -> Int {
        let value = try charge(contextTokens: contextTokens, profile: profile)
        return try QwenLongPrefillCheckedBytes.sum([value.laneBytes, value.sharedBytes, collectiveScratchBytes])
    }

    /// What the reservation gate reads, once: the host's pages and MLX's allocator.
    struct GateObservation {
        let os: QwenDenseStageLoadOSObservation
        let uptimeNanoseconds: UInt64
        let activeBytes: Int, cacheBytes: Int, memoryLimitBytes: Int

        static func live() throws -> GateObservation {
            let os = try QwenDenseStageLoadResources.observeOS()
            return .init(os: os, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                activeBytes: Memory.activeMemory, cacheBytes: Memory.cacheMemory, memoryLimitBytes: Memory.memoryLimit)
        }
    }

    /// Whether an idle rank's reservation gate admits one request of
    /// `contextTokens` on `observation`, with that gate's arithmetic
    /// (`requireBatchMemory`, entering): what this owner already allocated
    /// since LOAD's baseline (`grownBytes`: kept prefix entries, retained
    /// casts) is part of the charge; MLX's freed buffers are not free.
    func admits(contextTokens: Int, profile: QwenLayerStageGenerationProfile, grownBytes: Int,
                on observation: GateObservation) throws -> Bool {
        let sum = QwenLongPrefillCheckedBytes.sum
        let headroom = QwenDenseStageLoadPolicy.loadingHeadroomBytes(physicalMemoryBytes: observation.os.physicalMemoryBytes)
        let remaining = try QwenResidentRequestAllowance.continuingRequirement(
            reservedBytes: bytes(contextTokens: contextTokens, profile: profile), additionalBytes: 0, grownBytes: grownBytes)
        guard observation.memoryLimitBytes >= (try sum([observation.activeBytes, observation.cacheBytes, remaining,
            QwenDenseStageLoadPolicy.allocatorHeadroomBytes])) else { return false }
        return try QwenDenseStageLoadPolicy.decide(observation.os, requiredBytes: sum([remaining, headroom]),
            purpose: "Qwen tensor-parallel context of \(contextTokens) tokens", now: observation.uptimeNanoseconds,
            floor: headroom).admitted
    }

    /// The longest context (prompt plus output) the gate admits on one
    /// observation (`admits`). Nil when not even one chunk and one output
    /// token fit.
    func servingContextTokens(profile: QwenLayerStageGenerationProfile, grownBytes: Int,
                              on observation: GateObservation) throws -> Int? {
        let minimum = min(profile.maximumContextTokens, profile.maximumChunkTokens + 1)
        // Charges grow with the context: the search is over a monotone gate.
        return try QwenResidentContextAdmission.largest(minimum: minimum, maximum: profile.maximumContextTokens) {
            try admits(contextTokens: $0, profile: profile, grownBytes: grownBytes, on: observation)
        }
    }
}
