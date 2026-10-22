import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM

/// What one request costs a tensor-parallel rank, at its own context (prompt
/// plus output tokens), so the pair admits the model's native context with no
/// service-level cap: each rank's live memory gate admits a request whose
/// charge fits now, and refuses one that does not (`reserve`, `reserveLane`,
/// `servingContextTokens`).
///
/// The terms are the load's (`GLM5NextTensorParallelResidentRuntime.load`),
/// at the request's context instead of the profile's:
/// - both pipeline stages' request state (`GLM5NextRequestStateBudget`, the
///   whole model's latent histories, replicated under TP, and all its KDA
///   state), with every DSA history charged at the request's own length:
///   the runtime caps each history's growth there
///   (`GLM5NextDSACache.capacityLimit`, `boundHistories`), so the charge is
///   the history and the one fresh buffer an append writes, never the
///   doubling's spare half;
/// - the NextN layer's history at the same bound (three copies: a round's
///   checkpoint and two draft appends) and its work (`speculationRequestBytes`);
/// - the DSA indexer's prefill scores beyond the memory scope's context
///   (`indexScoreBytes`): FP32 `[rows, pools]` of both micro-batches of a bulk
///   frame, the one prefill transient that grows with the context and that
///   the conservative workspace was not sized for;
/// - beside them, the same at every context: the sealed sums' buffers at the
///   largest chunk and the bulk prefill's further workspaces (`fixedBytes`).
///
/// Per DSA layer and token: (512 + 128 + 128) x 4 + 1 = 3,073 bytes of
/// history, twice; 11 DSA layers and the NextN layer's three copies make
/// about 77 KB a token, about 81 GB at 1,048,576 tokens, plus the KDA state,
/// workspaces and scores (`GLM5NextRequestChargeTests`).
struct GLM5NextTensorParallelRequestCharge {
    let descriptor: GLM5NextResidentDescriptor
    /// Rank 0's and rank 1's stage envelopes at the descriptor's cut: TP
    /// charges each rank both, the whole model.
    let envelopes: [GLM5NextResidentResourceEnvelope]
    let fixedBytes: Int
    let speculativeDepth: Int
    let maximumBufferBytes: Int
    let allocationBound: (Int) throws -> Int

    /// History columns a request of `contextTokens` may hold: its prompt and
    /// outputs, and one verification window's proposals past its last output.
    func historyTokens(contextTokens: Int) -> Int { contextTokens + speculativeDepth + 1 }

    func bytes(contextTokens context: Int) throws -> Int {
        typealias Bytes = QwenLongPrefillCheckedBytes
        let p = descriptor.profile, c = descriptor.configuration.textConfig
        guard (2...p.maximumContextTokens).contains(context), envelopes.map(\.rank) == [0, 1] else {
            throw ProbeError("GLM tensor-parallel charge needs a context within the profile")
        }
        let prompt = min(p.maximumPromptTokens, context - 1)
        let scope = GLM5NextRequestStateBudget.Scope(maximumContextTokens: context, maximumPromptTokens: prompt,
            maximumOutputTokens: min(p.maximumOutputTokens, context - 1),
            maximumChunkTokens: min(p.maximumChunkTokens, prompt))
        let history = GLM5NextRequestStateBudget.HistoryBound.reserved(tokens: historyTokens(contextTokens: context))
        var terms = [fixedBytes]
        for envelope in envelopes {
            try envelope.requireExecutionEnvironment(envelope.executionEnvironmentSHA256)
            let layers = envelope.rank == 0 ? 0 ..< descriptor.cut : descriptor.cut ..< c.hiddenLayers
            terms.append(try GLM5NextRequestStateBudget.estimate(inventory: envelope.inventory, layers: layers,
                rank: envelope.rank, scope: scope, executionPolicy: descriptor.executionPolicy,
                executionEnvironmentSHA256: envelope.executionEnvironmentSHA256, workspace: envelope.workspace,
                transport: GLM5NextResidentResourceEnvelope.transportTerms, maximumBufferBytes: maximumBufferBytes,
                allocationBound: allocationBound, hostAllocationBound: envelope.hostAllocationBound,
                history: history).reservedBytes)
        }
        terms.append(try GLM5NextTensorParallelResidentRuntime.speculationRequestBytes(configuration: c, profile: p,
            depth: speculativeDepth, executionPolicy: descriptor.executionPolicy, allocationBound: allocationBound,
            contextTokens: context, history: history))
        terms.append(try Self.indexScoreBytes(configuration: c, contextTokens: context,
            referenceContextTokens: descriptor.memoryProfile.maximumContextTokens))
        return try Bytes.sum(terms)
    }

    /// The DSA indexer's FP32 prefill scores of one bulk frame (both
    /// micro-batches, `bulkPrefillChunkTokens` rows) over a context's pools
    /// (`index_kpool` tokens each), beyond those at `referenceContextTokens`,
    /// which the conservative workspace covers.
    static func indexScoreBytes(configuration c: GLM5NextTextConfiguration, contextTokens: Int,
                                referenceContextTokens: Int) throws -> Int {
        guard c.indexKPool > 0, contextTokens > referenceContextTokens else { return 0 }
        func scores(_ context: Int) throws -> Int {
            try QwenLongPrefillCheckedBytes.product([GLM5NextTensorParallelResidentRuntime.bulkPrefillChunkTokens,
                (context + c.indexKPool - 1) / c.indexKPool, 4])
        }
        return try scores(contextTokens) - scores(referenceContextTokens)
    }

    /// The longest context (prompt plus output) whose charge the host's memory
    /// gate admits now, judged on one observation (no reclaim): `reclaimable`
    /// bytes (prompt-prefix entries and MLX's freed buffers, which a
    /// reservation releases before it is refused) count as free. Nil when not
    /// even one chunk and one output token fit.
    func servingContextTokens(reclaimableBytes: Int) throws -> Int? {
        let p = descriptor.profile
        let os = try QwenDenseStageLoadResources.observeOS()
        let now = DispatchTime.now().uptimeNanoseconds
        func admits(_ context: Int) throws -> Bool {
            let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
                try QwenLongPrefillCheckedBytes.sum([try bytes(contextTokens: context),
                    QwenDenseStageLoadPolicy.loadingHeadroomBytes]) - max(0, reclaimableBytes))
            return try QwenDenseStageLoadPolicy.decide(os, requiredBytes: free,
                purpose: "GLM tensor-parallel context of \(context) tokens", now: now).admitted
        }
        let minimum = min(p.maximumContextTokens, p.maximumChunkTokens + 1)
        // Charges grow with the context: the search is over a monotone gate.
        return try QwenResidentContextAdmission.largest(minimum: minimum, maximum: p.maximumContextTokens,
            admits: admits)
    }
}

extension GLM5NextTensorParallelResidentRuntime {
    /// Caps every DSA history of `cache` at `tokens` columns
    /// (`GLM5NextDSACache.capacityLimit`): the request's charge is its own
    /// length (`GLM5NextTensorParallelRequestCharge`). Values are unchanged:
    /// columns past a history's offset are never read.
    static func boundHistories(_ cache: GLM5NextTextStageCache, tokens: Int) {
        for case let history as GLM5NextDSACache in cache.layers { history.capacityLimit = tokens }
    }
}
