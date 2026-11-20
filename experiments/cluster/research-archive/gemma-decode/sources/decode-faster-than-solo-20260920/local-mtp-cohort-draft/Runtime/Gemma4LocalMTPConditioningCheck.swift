import Foundation
import MLX
import MLXLMCommon
@_spi(DarkbloomCluster) import MLXLLM

struct Gemma4LocalMTPConditioningReceipt: Encodable {
    let schema = "gemma4_local_mtp_conditioning_parity_v1"
    let frontier: Int, seedToken: Int
    let depths: [Int], exactTokenColumns: Int, exactHiddenColumns: Int
    let exactBatchedTokenColumns: Int, exactBatchedHiddenColumns: Int, negativeControls: Int
    let fullTargetEmbeddingUsed = true, targetForwardInvoked = false
    let targetBatchNumericsQualified = false, remoteExecutionQualified = false
    let outsideGenerationTiming = true
}

/// Compare the actual conditioning branch with the SDK's original CBv2 drafter.
/// All branches share one immutable actual capture and are retired sequentially.
/// Depth never exceeds the auxiliary's two-proposal/five-graph live allowance.
enum Gemma4LocalMTPConditioningCheck {
    private struct Column: Equatable {
        let tokens: Data, tokenShape: [Int]
        let hidden: Data, hiddenShape: [Int], hiddenDType: String
    }

    static func run(target: any Gemma4MTPTarget, assistant: Gemma4AssistantDraftModel,
        capture: Gemma4OwnedMTPConditioning, seedToken: Int, auxiliary: Gemma4MTPAuxiliaryOwner,
        check: () throws -> Void
    ) throws -> Gemma4LocalMTPConditioningReceipt {
        try check(); try auxiliary.requireGrant(count: 2, capture: capture)
        guard (0..<262_144).contains(seedToken), target.mtpConfiguration.vocabSize == 262_144 else {
            throw ProbeError("Local conditioning parity seed/target differs")
        }
        assistant.unbind(); defer { assistant.unbind() }
        return try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            func column(_ tokens: MLXArray, _ hidden: MLXArray) throws -> Column {
                try checked(); eval(tokens, hidden); Stream.gpu.synchronize(); try checked()
                guard tokens.dtype == .int32, tokens.shape == [1,1], hidden.shape == [1,1,2816] else {
                    throw ProbeError("Local conditioning parity returned unexpected columns")
                }
                let result = Column(tokens: tokens.asData(access: .copy).data, tokenShape: tokens.shape,
                    hidden: hidden.asData(access: .copy).data, hiddenShape: hidden.shape,
                    hiddenDType: String(describing: hidden.dtype))
                try checked(); return result
            }
            func refuses(_ body: () throws -> Void) throws {
                do { try body() } catch is Gemma4MTPError { try checked(); return }
                throw ProbeError("Local conditioning negative control accepted")
            }
            do {
                let row = CBv2MTPRowCapture(fullKeys: capture.fullKeys, fullValues: capture.fullValues,
                    slidingKeys: capture.slidingKeys, slidingValues: capture.slidingValues,
                    slidingStart: capture.frontier - capture.slidingKeys.dim(2), anchor: capture.frontier)
                let conditioning = Gemma4MTPConditioning(targetConfiguration: target.mtpConfiguration,
                    scaledEmbedding: { target.embedTokensForDrafter($0) })
                var wrong = row; wrong.anchor += 1
                try refuses { _ = try Gemma4MTPFrozenProposalBranch(drafter: assistant, conditioning: conditioning,
                    row: wrong, seedToken: seedToken, hidden: capture.hidden, maximumProposals: 2) }
                try refuses { _ = try Gemma4MTPFrozenProposalBranch(drafter: assistant, conditioning: conditioning,
                    row: row, seedToken: 262_144, hidden: capture.hidden, maximumProposals: 2) }
                try refuses { _ = try Gemma4MTPFrozenProposalBranch(drafter: assistant, conditioning: conditioning,
                    row: row, seedToken: seedToken, hidden: capture.hidden, maximumProposals: 0) }
                var exact = 0
                for depth in [1,2] {
                    let expected: [Column] = try autoreleasepool {
                        try auxiliary.requireGrant(count: depth, capture: capture); try checked()
                        let branch = try Gemma4MTPFrozenProposalBranch(drafter: assistant,
                            conditioning: conditioning, row: row, seedToken: seedToken,
                            hidden: capture.hidden, maximumProposals: depth)
                        var values: [Column] = []
                        for _ in 0..<depth {
                            let batch = try branch.build(grantedCount: 1)
                            values.append(try column(batch.tokens, batch.lastHidden))
                        }
                        try refuses { _ = try branch.build(grantedCount: 1) }
                        return values
                    }
                    Stream.gpu.synchronize(); try checked(); assistant.unbind()
                    try autoreleasepool {
                        try auxiliary.requireGrant(count: depth, capture: capture); try checked()
                        let branch = try Gemma4MTPFrozenProposalBranch(drafter: assistant,
                            conditioning: conditioning, row: row, seedToken: seedToken,
                            hidden: capture.hidden, maximumProposals: depth)
                        let batch = try branch.build(grantedCount: depth)
                        eval(batch.tokens, batch.lastHidden); Stream.gpu.synchronize(); try checked()
                        var tokenBytes = Data()
                        for value in expected { tokenBytes.append(value.tokens) }
                        guard let last = expected.last, batch.tokens.shape == [1,depth], batch.tokens.dtype == .int32,
                              batch.tokens.asData(access: .copy).data == tokenBytes,
                              batch.lastHidden.shape == last.hiddenShape,
                              String(describing: batch.lastHidden.dtype) == last.hiddenDType,
                              batch.lastHidden.asData(access: .copy).data == last.hidden else {
                            throw ProbeError("Batched local proposal columns differ from evaluated single steps")
                        }
                        try checked()
                    }
                    Stream.gpu.synchronize(); try checked(); assistant.unbind()
                    try autoreleasepool {
                        try auxiliary.requireGrant(count: depth, capture: capture); try checked()
                        let original = try Gemma4CBv2MTPDrafter(drafter: assistant, target: target)
                        let prepared = original.prepare(rows: [row])
                        var token = MLXArray([Int32(seedToken)]).reshaped([1,1]), hidden = capture.hidden
                        for index in 0..<depth {
                            let value = original.draftStep(tokens: token, hidden: hidden, prepared: prepared)
                            token = value.tokens.asType(.int32).reshaped([1,1]); hidden = value.hidden
                            guard try column(token, hidden) == expected[index] else {
                                throw ProbeError("Local conditioned branch differs from actual SDK CBv2 drafter")
                            }
                            exact += 1
                        }
                    }
                    Stream.gpu.synchronize(); try checked(); assistant.unbind()
                }
                return .init(frontier: capture.frontier, seedToken: seedToken, depths: [1,2],
                    exactTokenColumns: exact, exactHiddenColumns: exact,
                    exactBatchedTokenColumns: 3, exactBatchedHiddenColumns: 2, negativeControls: 5)
            } catch { try native.check(); throw error }
        }
    }
}
