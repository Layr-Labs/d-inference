import Foundation

/// Compact target and assistant capture has a distinct live bank and two
/// resident banks. Full live pages, trusted history, restore destinations and
/// first-draft prompt workspace stay in the ordinary complete MTP quotation.
struct QwenTensorParallelMTPPrefixBudget {
    static let policy = "qwen-tp-mtp-grid-prefix-4096-v1"
    let maximumTokens: Int
    let targetCaptureBytes: Int
    let assistantCaptureBytes: Int
    let captureBytes: Int
    let residentBytes: Int

    static func derive(geometry: QwenLongPrefillBudgetGeometry, maximumTokens: Int,
                       allocationBound: (Int) throws -> Int) throws -> Self {
        let target = try QwenTensorParallelBatchPrefixBudget.derive(geometry: geometry,
            maximumTokens: maximumTokens, allocationBound: allocationBound)
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        func bound(_ bytes: Int) throws -> Int {
            let result = try allocationBound(bytes)
            guard bytes > 0, result >= bytes else { throw ProbeError("Qwen TP MTP prefix allocator bound differs") }
            return result
        }
        let count = target.maximumTokens
        let assistant = count < 2 ? 0 : try sum([
            bound(product([count - 1, geometry.hiddenSize, 2])),
            bound(product([count - 1, 4])), bound(product([geometry.hiddenSize, 2])),
        ])
        let capture = try sum([target.captureBytes, assistant])
        return try .init(maximumTokens: count, targetCaptureBytes: target.captureBytes,
            assistantCaptureBytes: assistant, captureBytes: capture, residentBytes: product([capture, 2]))
    }
}
