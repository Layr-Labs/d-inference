import Foundation

/// A tensor-parallel Qwen request's prompt-prefix capture and the boundaries
/// it keeps, on its own chunk grid, to the request's context.
///
/// Kept boundaries (`frontiers`), each strictly before the prompt's final
/// token and after what the request restored:
/// - the deepest whole chunk before the final token (an exact repeat);
/// - the deepest whole chunk at least `promptEndMarginTokens` before the
///   prompt end, from `marginFloorTokens` on (the next turn of a
///   conversation, whose template re-renders the generation prompt; one
///   Mac's `demandedLatestPromptEndMarginTokens` cut);
/// - every multiple of `stripeTokens` (one Mac's dense-Qwen solo stripe,
///   `EngineV2Factory.defaultDenseQwenSoloPrefillStripeTokens`: the first,
///   fork-target and stripe-end checkpoints one Mac can keep), so a prompt
///   sharing only a long system prompt finds one. Past the first, the stripe
///   doubles until at most `maximumStripeBoundaries` remain, the SSD
///   record's grid (`QwenStagePrefixDiskTier.maximumGridFrontiers`), so they
///   are also written to the record and a capture keeps at most eleven
///   recurrent states.
///
/// A capture copies the attention rows once, at its deepest kept boundary,
/// and the recurrent state at each kept boundary
/// (`QwenTensorParallelPrefixCapture`). Each request is charged its own
/// capture (`captureBytes(promptCount:chunkSize:)`); LOAD and the planner
/// charge one capture of the profile's longest prompt per lane. The memory
/// tier that keeps captures after their requests is charged nowhere: its
/// budget is half the room LOAD measures beside that charge
/// (`QwenStagePrefixCache.budget(roomBytes:)`), and its entries give way
/// before a reservation or a running batch is refused for memory.
///
/// The geometry prices what it is given: a rank's own heads at LOAD, the
/// full unsliced model (either rank, any shares) in the planner.
struct QwenTensorParallelBatchPrefixBudget {
    static let policy = "qwen-tp-batch-prefix-depth-v2"
    static let stripeTokens = 4096
    static let promptEndMarginTokens = 64
    static let marginFloorTokens = 1024
    static let maximumStripeBoundaries = 8

    /// The context LOAD derived `captureBytes` at (the memory plan's). It
    /// does not bound a request, whose boundaries go to its own context.
    let maximumTokens: Int
    /// The per-lane LOAD term: one capture of the profile's longest prompt.
    let captureBytes: Int
    /// What a request's own capture is priced on; nil keeps `captureBytes`
    /// for every request (fixtures).
    let geometry: QwenLongPrefillBudgetGeometry?

    init(maximumTokens: Int, captureBytes: Int, geometry: QwenLongPrefillBudgetGeometry? = nil) {
        self.maximumTokens = maximumTokens; self.captureBytes = captureBytes; self.geometry = geometry
    }

    /// The boundaries a request of `promptCount` tokens keeps, ascending.
    static func frontiers(promptCount: Int, chunkSize: Int, restored: Int = 0,
                          maximumTokens: Int = .max) -> [Int] {
        guard chunkSize > 0, promptCount > 1 else { return [] }
        let limit = min(promptCount - 1, maximumTokens)
        let deepest = limit / chunkSize * chunkSize
        guard deepest > restored, deepest > 0 else { return [] }
        var kept: Set<Int> = [deepest]
        let margin = (promptCount - 1 - promptEndMarginTokens) / chunkSize * chunkSize
        if margin >= marginFloorTokens, margin > restored, margin < deepest { kept.insert(margin) }
        let first = (stripeTokens + chunkSize - 1) / chunkSize * chunkSize
        if first > restored, first < deepest { kept.insert(first) }
        var stripe = first
        while (deepest - 1) / stripe > maximumStripeBoundaries { stripe *= 2 }
        for boundary in Swift.stride(from: stripe, to: deepest, by: stripe) where boundary > restored {
            kept.insert(boundary)
        }
        return kept.sorted()
    }

    /// The recurrent states a capture whose deepest boundary is `deepest`
    /// is charged: the deepest, a margin boundary whenever one can exist, and
    /// every stripe boundary below it, at most `maximumStripeBoundaries + 1`.
    /// At least what any prompt with that deepest boundary keeps, and never
    /// fewer for a deeper one, so the charge grows with the prompt.
    static func pricedStates(deepest: Int, chunkSize: Int) -> Int {
        guard deepest > 0, chunkSize > 0 else { return 0 }
        let first = (stripeTokens + chunkSize - 1) / chunkSize * chunkSize
        let margin = (deepest - promptEndMarginTokens) / chunkSize * chunkSize >= marginFloorTokens ? 1 : 0
        return 1 + margin + min((deepest - 1) / first, maximumStripeBoundaries + 1)
    }

    /// One capture of a prompt of `promptCount` tokens at the allocator's
    /// bound: every attention layer's keys and values to its deepest kept
    /// boundary, and every recurrent layer's convolution and SSM state for
    /// `pricedStates`; 0 when it keeps none.
    static func captureBytes(geometry g: QwenLongPrefillBudgetGeometry, promptCount: Int, chunkSize: Int,
                             maximumTokens: Int = .max, allocationBound: (Int) throws -> Int) throws -> Int {
        guard let deepest = frontiers(promptCount: promptCount, chunkSize: chunkSize, maximumTokens: maximumTokens).last else {
            return 0
        }
        let states = pricedStates(deepest: deepest, chunkSize: chunkSize)
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let b = try QwenLongPrefillTensorBudget.estimate(geometry: g, maximumTokens: 1, chunkSize: 1)
        func bound(_ bytes: Int, count: Int) throws -> Int {
            guard count > 0 else { return 0 }
            let allocated = try allocationBound(bytes)
            guard bytes > 0, allocated >= bytes else { throw ProbeError("Invalid TP prefix allocation bound") }
            return try product([allocated, count])
        }
        return try sum([
            bound(product([deepest, g.kvHeads, g.headDimension, 2]), count: 2 * g.attentionLayers),
            bound(b.convolutionBytesPerLayer, count: states * g.recurrentLayers),
            bound(b.ssmBytesPerLayer, count: states * g.recurrentLayers),
        ])
    }

    /// This request's own capture, as its reservation charged it
    /// (`QwenTensorParallelRequestCharge`): priced on `geometry`, else `captureBytes`.
    func captureBytes(promptCount: Int, chunkSize: Int, allocationBound: (Int) throws -> Int) throws -> Int {
        guard let geometry else { return captureBytes }
        return try Self.captureBytes(geometry: geometry, promptCount: promptCount, chunkSize: chunkSize,
            allocationBound: allocationBound)
    }

    /// LOAD's per-lane term: one capture of a `promptTokens` prompt (the
    /// profile's longest; nil: the longest a `maximumTokens` request holds).
    static func derive(geometry g: QwenLongPrefillBudgetGeometry, maximumTokens: Int, promptTokens: Int? = nil,
                       chunkSize: Int, allocationBound: (Int) throws -> Int) throws -> Self {
        guard maximumTokens > 0, chunkSize > 0 else { throw ProbeError("Invalid TP prefix context") }
        let prompt = min(promptTokens ?? maximumTokens - 1, maximumTokens - 1)
        let capture = try captureBytes(geometry: g, promptCount: prompt, chunkSize: chunkSize,
            allocationBound: allocationBound)
        return .init(maximumTokens: maximumTokens, captureBytes: capture, geometry: g)
    }
}
