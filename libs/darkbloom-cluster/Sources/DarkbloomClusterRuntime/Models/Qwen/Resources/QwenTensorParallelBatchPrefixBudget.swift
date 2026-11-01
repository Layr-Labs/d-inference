import Foundation

/// Prefix copies are distinct from each lane's full live state and restore
/// workspace. Keep at most one original-grid frontier per lane, and two such
/// worst-case banks in the resident cache. The full unsliced geometry prices
/// either rank, including unequal shares. No shape estimate replaces LOAD's
/// canonical parameter quotation.
struct QwenTensorParallelBatchPrefixBudget {
    static let maximumTokens = 4096
    static let policy = "qwen-tp-batch-grid-prefix-4096-v1"
    let maximumTokens: Int
    let captureBytes: Int
    let residentBytes: Int

    static func derive(geometry g: QwenLongPrefillBudgetGeometry, maximumTokens: Int,
                       allocationBound: (Int) throws -> Int) throws -> Self {
        guard maximumTokens > 0 else { throw ProbeError("Invalid TP prefix context") }
        let tokens = min(Self.maximumTokens, maximumTokens)
        let b = try QwenLongPrefillTensorBudget.estimate(geometry: g, maximumTokens: tokens, chunkSize: 1)
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        func bound(_ bytes: Int, count: Int) throws -> Int {
            guard count > 0 else { return 0 }
            let allocated = try allocationBound(bytes)
            guard bytes > 0, allocated >= bytes else { throw ProbeError("Invalid TP prefix allocation bound") }
            return try product([allocated, count])
        }
        let capture = try sum([
            bound(b.convolutionBytesPerLayer, count: g.recurrentLayers),
            bound(b.ssmBytesPerLayer, count: g.recurrentLayers),
            bound(product([tokens, g.kvHeads, g.headDimension, 2]), count: 2 * g.attentionLayers),
        ])
        return try .init(maximumTokens: tokens, captureBytes: capture, residentBytes: product([capture, 2]))
    }
}
