import Foundation
import MLX
import MLXLMCommon
@_spi(DarkbloomCluster) import MLXLLM

struct Gemma4MTPConditioningQualification: Encodable {
    let embeddingIdentitySHA256: String
    let checkedEmbeddingTokens: [Int]
    let checkedDepths: [Int]
    let exactTokenColumns: Int, exactHiddenColumns: Int
    let negativeControls: Int
    let targetStateMutated = false
    let targetNumericalAcceptanceQualified = false
    let remoteExecutionQualified = false
}

/// Actual-weight parity probe, deliberately separate from timed generation.
/// Call only under the existing native owner, reserved probe arrays/host copies
/// and checked lifetime. Uses an already loaded real target and assistant.
/// It changes the assistant binding and returns it unbound; the caller may not
/// have another active assistant branch. No target forward/cache mutation.
func qualifyGemma4MTPConditioning(target: any Gemma4MTPTarget,
    embedding: Gemma4RegisteredDraftEmbedding, drafter: Gemma4AssistantDraftModel,
    row: CBv2MTPRowCapture, seedToken: Int, hidden: MLXArray,
    check: () throws -> Void
) throws -> Gemma4MTPConditioningQualification {
    struct ExactColumn: Equatable { let tokenShape: [Int], tokenBytes: Data, hiddenShape: [Int], hiddenDType: String, hiddenBytes: Data }
    let depths = [2,4,8]
    let tokenIDs = [0,1,seedToken,2047,65535,target.mtpConfiguration.vocabSize-1]
    guard target.mtpConfiguration.vocabSize == 262144,
          (0..<target.mtpConfiguration.vocabSize).contains(seedToken) else {
        throw ProbeError("Conditioning parity target or seed differs")
    }
    return try withoutActuallyEscaping(check) { borrowed in
        try MLX.withError { native in
            func checked() throws { try native.check(); try borrowed(); try native.check() }
            func capture(_ tokens: MLXArray, _ h: MLXArray) throws -> ExactColumn {
                try checked(); eval(tokens,h); Stream.gpu.synchronize(); try checked()
                let result = ExactColumn(tokenShape: tokens.shape, tokenBytes: tokens.asData(access: .copy).data,
                    hiddenShape: h.shape, hiddenDType: String(describing:h.dtype), hiddenBytes:h.asData(access:.copy).data)
                try checked(); return result
            }
            func refuses(_ operation: () throws -> Void) throws {
                do { try operation() }
                catch is Gemma4MTPError { try checked(); return }
                throw ProbeError("Conditioning negative control unexpectedly accepted")
            }
            do {
                try checked()
                let tokens = MLXArray(tokenIDs.map(Int32.init)).reshaped([1,tokenIDs.count])
                let original = target.embedTokensForDrafter(tokens), selected = embedding.lookup(tokens)
                eval(original,selected); Stream.gpu.synchronize(); try checked()
                guard original.shape == selected.shape, original.dtype == selected.dtype,
                      original.asData(access:.copy).data == selected.asData(access:.copy).data else {
                    throw ProbeError("Selected target embedding differs from actual full target bytes")
                }
                try checked()
                let conditioning = embedding.conditioning()
                var wrongFullFrontier = row; wrongFullFrontier.anchor += 1
                var wrongSlidingStart = row; wrongSlidingStart.slidingStart += 1
                try refuses { _ = try Gemma4MTPFrozenProposalBranch(drafter:drafter,conditioning:conditioning,
                    row:wrongFullFrontier,seedToken:seedToken,hidden:hidden,maximumProposals:8) }
                try refuses { _ = try Gemma4MTPFrozenProposalBranch(drafter:drafter,conditioning:conditioning,
                    row:wrongSlidingStart,seedToken:seedToken,hidden:hidden,maximumProposals:8) }
                try refuses { _ = try Gemma4MTPFrozenProposalBranch(drafter:drafter,conditioning:conditioning,
                    row:row,seedToken:262144,hidden:hidden,maximumProposals:8) }
                try refuses { _ = try Gemma4MTPFrozenProposalBranch(drafter:drafter,conditioning:conditioning,
                    row:row,seedToken:seedToken,hidden:hidden,maximumProposals:0) }
                try drafter.bind(conditioning:conditioning)
                try drafter.bind(conditioning:conditioning) // Same identity is idempotent.
                try refuses { try drafter.bind(conditioning:embedding.conditioning()) }
                drafter.unbind()
                var columns = 0, batchColumns = 0
                for depth in depths {
                    // A helper scope retires each selected branch before rebinding.
                    func selectedColumns() throws -> [ExactColumn] {
                        let conditioning = embedding.conditioning()
                        let branch = try Gemma4MTPFrozenProposalBranch(drafter:drafter,
                            conditioning:conditioning, row:row, seedToken:seedToken, hidden:hidden,
                            maximumProposals:depth)
                        try refuses { _ = try branch.build(grantedCount:0) }
                        try refuses { _ = try branch.build(grantedCount:9) }
                        var result: [ExactColumn] = []
                        for _ in 0..<depth {
                            try checked(); let batch = try branch.build(grantedCount:1)
                            result.append(try capture(batch.tokens,batch.lastHidden))
                        }
                        try refuses { _ = try branch.build(grantedCount:1) }
                        return result
                    }
                    let selectedResult = try selectedColumns()
                    try checked(); drafter.unbind()
                    func batchedColumn() throws -> ExactColumn {
                        let branch = try Gemma4MTPFrozenProposalBranch(drafter:drafter,
                            conditioning:embedding.conditioning(),row:row,seedToken:seedToken,
                            hidden:hidden,maximumProposals:depth)
                        let batch = try branch.build(grantedCount:depth)
                        // Actual bounded submission as used for remote lookahead;
                        // this probe does not claim another device overlapped it.
                        asyncEval(batch.tokens,batch.lastHidden)
                        return try capture(batch.tokens,batch.lastHidden)
                    }
                    let batch = try batchedColumn()
                    var tokenBytes = Data()
                    for column in selectedResult { tokenBytes.append(column.tokenBytes) }
                    guard let last = selectedResult.last, batch.tokenShape == [1,depth],
                          batch.tokenBytes == tokenBytes, batch.hiddenShape == last.hiddenShape,
                          batch.hiddenDType == last.hiddenDType, batch.hiddenBytes == last.hiddenBytes else {
                        throw ProbeError("Batched async proposal chain differs from evaluated per-step chain")
                    }
                    batchColumns += depth
                    try checked(); drafter.unbind()
                    let adapter = try Gemma4CBv2MTPDrafter(drafter:drafter,target:target)
                    let prepared = adapter.prepare(rows:[row])
                    var token = MLXArray([Int32(seedToken)]).reshaped([1,1]), carried = hidden
                    for index in 0..<depth {
                        try checked()
                        let output = adapter.draftStep(tokens:token,hidden:carried,prepared:prepared)
                        token = output.tokens.reshaped([1,1]); carried = output.hidden
                        guard try capture(token,carried) == selectedResult[index] else {
                            throw ProbeError("Standalone conditioned proposal differs from original CBv2 assistant arithmetic")
                        }
                        columns += 1
                    }
                    try checked(); drafter.unbind()
                }
                try checked()
                return .init(embeddingIdentitySHA256:embedding.receipt.embeddingIdentitySHA256,
                    checkedEmbeddingTokens:tokenIDs,checkedDepths:depths,
                    exactTokenColumns:columns+batchColumns,exactHiddenColumns:columns+depths.count,negativeControls:14)
            } catch { try native.check(); throw error }
        }
    }
}
