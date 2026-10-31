import Foundation

/// Shared decode rows and control envelopes beside every complete lane charge.
enum MiMoBatchMemory {
    struct Workspace { let native: Int; let host: Int }
    static func historyBytes(maximumTokens: Int) throws -> Int {
        guard maximumTokens > 0 else { throw ProbeError("MiMo token history has invalid scope") }
        return try QwenLongPrefillCheckedBytes.product([maximumTokens, MemoryLayout<Int>.stride, 2])
    }
    static func workspace(spec: MiMoRegisteredSpecification, localLayers: Int, rank: Int, lanes: Int,
                          bound: (Int) throws -> Int) throws -> Workspace {
        guard (2...8).contains(lanes), (0...1).contains(rank), (1..<spec.layers).contains(localLayers) else {
            throw ProbeError("MiMo batch workspace has invalid geometry")
        }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func charge(_ elements: [Int], copies: Int) throws -> Int {
            let raw = try product(elements), rounded = try bound(raw)
            guard raw > 0, rounded >= raw else { throw ProbeError("MiMo batch allocator bound is invalid") }
            return try product([rounded, copies])
        }
        let wire = try charge([max(QwenBatchWire.headerWords, QwenBatchWire.replyWords), 4], copies: 4)
        // Batched dense Q/K/V, attended rows, residuals and normalized carries.
        // Use the registered maximum (64) query heads and FP32 upper bounds.
        let attention = try charge([lanes, 64, max(spec.keyWidth, spec.valueWidth), 4], copies: 6 * localLayers)
        let residuals = try charge([lanes, spec.hidden, 4], copies: 4 * localLayers)
        let rows = rank == 1 ? try charge([lanes, spec.vocabulary, 4], copies: 2) : 0
        return .init(native: try sum([wire, attention, residuals, rows]), host: wire)
    }
}
