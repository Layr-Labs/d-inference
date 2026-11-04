import Foundation

/// Compact target and assistant capture has a distinct live bank and two
/// resident banks. Full live pages, trusted history, restore destinations and
/// first-draft prompt workspace stay in the ordinary complete MTP quotation.
///
/// The assistant keeps one original-grid frontier per lane, at most
/// `maximumTokens` deep: its prompt history is held unflushed up to that
/// frontier (`QwenTensorParallelMTPBudget`'s checkpoint rows), so a deeper
/// frontier is a larger trusted-history bank in every assisted lane, not
/// only a larger capture. The plain lanes keep theirs to the request's
/// context (`QwenTensorParallelBatchPrefixBudget`).
struct QwenTensorParallelMTPPrefixBudget {
    static let policy = "qwen-tp-mtp-grid-prefix-4096-v1"
    static let maximumTokens = 4096
    let maximumTokens: Int
    let targetCaptureBytes: Int
    let assistantCaptureBytes: Int
    let captureBytes: Int
    let residentBytes: Int

    static func derive(geometry g: QwenLongPrefillBudgetGeometry, maximumTokens: Int,
                       allocationBound: (Int) throws -> Int) throws -> Self {
        guard maximumTokens > 0 else { throw ProbeError("Invalid TP prefix context") }
        let count = min(Self.maximumTokens, maximumTokens)
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let b = try QwenLongPrefillTensorBudget.estimate(geometry: g, maximumTokens: count, chunkSize: 1)
        func bound(_ bytes: Int, count: Int = 1) throws -> Int {
            guard count > 0 else { return 0 }
            let result = try allocationBound(bytes)
            guard bytes > 0, result >= bytes else { throw ProbeError("Qwen TP MTP prefix allocator bound differs") }
            return try product([result, count])
        }
        let target = try sum([
            bound(b.convolutionBytesPerLayer, count: g.recurrentLayers),
            bound(b.ssmBytesPerLayer, count: g.recurrentLayers),
            bound(product([count, g.kvHeads, g.headDimension, 2]), count: 2 * g.attentionLayers),
        ])
        let assistant = count < 2 ? 0 : try sum([
            bound(product([count - 1, g.hiddenSize, 2])),
            bound(product([count - 1, 4])), bound(product([g.hiddenSize, 2])),
        ])
        let capture = try sum([target, assistant])
        return try .init(maximumTokens: count, targetCaptureBytes: target,
            assistantCaptureBytes: assistant, captureBytes: capture, residentBytes: product([capture, 2]))
    }
}
