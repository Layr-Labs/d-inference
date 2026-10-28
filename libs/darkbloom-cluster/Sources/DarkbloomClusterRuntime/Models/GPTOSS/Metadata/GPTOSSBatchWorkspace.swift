import Foundation

/// Additional batch allocations beside every lane's WHOLE existing request
/// allowance. The qualified model LOAD floor is unchanged; decode has at most
/// eight token rows versus its existing maximum prefill chunk. No state charge
/// or full/sliding score allowance is shared away to make another lane fit.
struct GPTOSSBatchWorkspace: Equatable {
    let native: Int, host: Int
    static func estimate(spec: GPTOSSRegisteredSpecification, localLayers: Int, rank: Int, lanes: Int,
                         bound: (Int) throws -> Int) throws -> Self {
        guard (2...8).contains(lanes), (0...1).contains(rank), (1..<spec.layers).contains(localLayers) else {
            throw ProbeError("Invalid GPT-OSS batch workspace geometry")
        }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func charge(_ elements: [Int], copies: Int = 1) throws -> Int {
            let raw = try product(elements), rounded = try bound(raw)
            guard raw > 0, rounded >= raw else { throw ProbeError("Invalid GPT-OSS batch allocator bound") }
            return try product([rounded, copies])
        }
        let wire = try charge([max(QwenBatchWire.headerWords, QwenBatchWire.replyWords), 4], copies: 4)
        let offsets = try charge([lanes, 4], copies: 2 * localLayers)
        let attentionRows = try charge([spec.queryHeads, spec.headDimension, 4], copies: lanes * localLayers)
        let concatenations = try charge([lanes, spec.queryHeads, spec.headDimension, 4], copies: localLayers)
        let boundary = try charge([lanes, spec.hidden, 4], copies: 2)
        let rows = rank == 1 ? try charge([lanes, spec.vocabulary, 4], copies: 2) : 0
        let limits = try spec.contextLimits()
        // Driver token histories and fixed control envelopes are host-owned.
        let host = try sum([try product([lanes, limits.maximumContextTokens, MemoryLayout<Int>.stride]), wire])
        return .init(native: try sum([wire, offsets, attentionRows, concatenations, boundary, rows]), host: host)
    }
}
