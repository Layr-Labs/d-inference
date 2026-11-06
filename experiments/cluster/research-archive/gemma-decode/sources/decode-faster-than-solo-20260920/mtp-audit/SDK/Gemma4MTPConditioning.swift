import Foundation
import MLX
import MLXLMCommon

/// A target's verified configuration and scaled embedding lookup, without a
/// target decoder or target KV owner. The caller supplies actual storage/source
/// identity, capacity and lifetime authority. This object creates none of them.
/// Access is serialized by that existing owner; no Sendable promise is made.
@_spi(DarkbloomCluster) public final class Gemma4MTPConditioning {
    public let targetConfiguration: Gemma4TextConfiguration
    fileprivate let scaledEmbedding: (MLXArray) -> MLXArray

    public init(targetConfiguration: Gemma4TextConfiguration,
                scaledEmbedding: @escaping (MLXArray) -> MLXArray) {
        self.targetConfiguration = targetConfiguration
        self.scaledEmbedding = scaledEmbedding
    }
}

extension Gemma4AssistantDraftModel {
    /// Additive conditioning-only binding. Uses the original compatibility and
    /// no-rebind rules. It cannot impersonate a CBv2 target ObjectIdentifier.
    @_spi(DarkbloomCluster) public func bind(conditioning: Gemma4MTPConditioning) throws {
        let identity = ObjectIdentifier(conditioning)
        if let existing = boundTargetID {
            guard existing == identity else { throw Gemma4MTPError.rebindForbidden }
            return
        }
        try Gemma4MTPCompatibilityValidator.validate(
            drafter: config, target: conditioning.targetConfiguration)
        targetEmbed = { [conditioning] tokens in conditioning.scaledEmbedding(tokens) }
        boundTargetID = identity
    }
}

/// One immutable, externally fenced target snapshot and an intentionally stale
/// assistant hidden chain. This is a proposal generator, NOT a target forward,
/// accepted-prefix transaction, CBv2 drafter or communication implementation.
/// No eval, host readback, async submission or stream fence occurs here.
@_spi(DarkbloomCluster) public final class Gemma4MTPFrozenProposalBranch {
    public struct Batch {
        public let firstProposalIndex: Int
        public let count: Int
        public let tokens: MLXArray       // [1, count], Int32; proposals only
        public let lastHidden: MLXArray   // [1, 1, target hidden width]
    }
    private let drafter: Gemma4AssistantDraftModel
    private let conditioning: Gemma4MTPConditioning
    private let sharedKV: Gemma4SharedKV
    private let masks: Gemma4DrafterMasks
    private let positionOffset: Gemma4.PositionOffset
    public let anchor: Int
    public let maximumProposals: Int
    public private(set) var generatedProposals = 0
    private var token: MLXArray
    private var hidden: MLXArray

    /// The owner must first prove actual snapshot-copy/transfer completion and
    /// immutable backing, pre-norm target hidden provenance and their admitted
    /// byte ledger. Shape validation below cannot establish those facts.
    public init(drafter: Gemma4AssistantDraftModel,
                conditioning: Gemma4MTPConditioning, row: CBv2MTPRowCapture,
                seedToken: Int, hidden: MLXArray, maximumProposals: Int) throws {
        let cfg = conditioning.targetConfiguration
        let fullHeads = cfg.numGlobalKeyValueHeads ?? cfg.numKeyValueHeads
        let arrays = [row.fullKeys, row.fullValues, row.slidingKeys, row.slidingValues]
        let floating: [DType] = [.bfloat16, .float16, .float32]
        // All host-only validation precedes bind mutation or graph creation.
        guard row.anchor > 0, row.anchor < min(cfg.maxPositionEmbeddings, 32_768),
              maximumProposals > 0,
              maximumProposals <= min(cfg.maxPositionEmbeddings, 32_768) - row.anchor,
              (0..<cfg.vocabSize).contains(seedToken),
              hidden.shape == [1, 1, cfg.hiddenSize], floating.contains(hidden.dtype),
              arrays.allSatisfy({ $0.ndim == 4 && floating.contains($0.dtype) }),
              arrays.allSatisfy({ $0.dtype == row.fullKeys.dtype }),
              row.fullKeys.shape == [1, fullHeads, row.anchor, cfg.globalHeadDim],
              row.fullValues.shape == row.fullKeys.shape,
              row.slidingKeys.shape == [1, cfg.numKeyValueHeads,
                  min(row.anchor, cfg.slidingWindow), cfg.headDim],
              row.slidingValues.shape == row.slidingKeys.shape,
              row.slidingStart == row.anchor - row.slidingKeys.dim(2) else {
            throw Gemma4MTPError.invalidConfiguration(
                field: "frozenProposalBranch", reason: "capture, hidden, seed or context geometry differs")
        }
        try drafter.bind(conditioning: conditioning)
        self.drafter = drafter; self.conditioning = conditioning
        self.anchor = row.anchor; self.maximumProposals = maximumProposals
        self.sharedKV = Gemma4SharedKV(fullAttention: (row.fullKeys, row.fullValues),
            slidingAttention: (row.slidingKeys, row.slidingValues))
        let sliding = Gemma4CBv2MTPDrafter.slidingMask(rows: [row],
            tMax: row.slidingKeys.dim(2), window: cfg.slidingWindow, dtype: row.slidingKeys.dtype)
        self.masks = Gemma4DrafterMasks(full: .none, sliding: sliding.map { .array($0) } ?? .none)
        // The frozen anchor remains constant even across a continuation batch.
        self.positionOffset = .batch(MLXArray([Int32(row.anchor)]))
        self.token = MLXArray([Int32(seedToken)]).reshaped([1, 1])
        self.hidden = hidden
    }

    /// Only invoke for an actual outstanding serialized ledger grant. The owner
    /// bounds outstanding graphs/packets separately; a per-call bound is not a
    /// live-memory ledger. It may asyncEval the returned arrays, perform the
    /// first batch's needed CPU readback, then use host-only consume/pull while
    /// a later submitted batch runs. No concurrent Collective P2P is required.
    public func build(grantedCount: Int) throws -> Batch {
        guard (1...8).contains(grantedCount),
              grantedCount <= maximumProposals - generatedProposals,
              drafter.boundTargetID == ObjectIdentifier(conditioning), drafter.targetEmbed != nil else {
            throw Gemma4MTPError.invalidConfiguration(
                field: "frozenProposalCredit", reason: "grant exceeds branch bound or binding changed")
        }
        var currentToken = token, currentHidden = hidden
        var proposals: [MLXArray] = []
        proposals.reserveCapacity(grantedCount)
        for _ in 0..<grantedCount {
            let embedded = conditioning.scaledEmbedding(currentToken)
            let inputs = concatenated([embedded, currentHidden], axis: -1)
            let output = drafter(inputsEmbeds: inputs, sharedKV: sharedKV,
                positionOffset: positionOffset, masks: masks)
            currentToken = output.logits.squeezed(axis: 1).argMax(axis: -1)
                .asType(.int32).reshaped([1, 1])
            currentHidden = output.lastHidden
            proposals.append(currentToken)
        }
        let result = Batch(firstProposalIndex: generatedProposals + 1, count: grantedCount,
            tokens: concatenated(proposals, axis: 1), lastHidden: currentHidden)
        token = currentToken; hidden = currentHidden; generatedProposals += grantedCount
        return result
    }
}
