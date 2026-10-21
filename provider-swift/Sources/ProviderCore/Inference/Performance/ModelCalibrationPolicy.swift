import Foundation

/// Work bounds, never a throughput/concurrency qualification. The production
/// engine, KV gate, actual context and existing concurrency cap remain final.
enum ModelCalibrationPolicy {
    static let refreshAge: Duration = .seconds(90)
    static let failureBackoff: Duration = .seconds(120)
    static let interruptionBackoff: Duration = .seconds(30)
    static let maximumGroupSeconds = 15.0

    struct Cell: Sendable, Equatable {
        let promptTokens: Int
        let outputTokens: Int
        let width: Int
        var warmup = false
        /// Draw with the artifact's default sampling instead of greedy.
        var sampled = false
    }

    /// `0` / `false` / `no` / `off` restores the plain startup cells; `always`
    /// runs the shape cells without the shader-cache probe.
    static let shapeWarmupEnvironmentKey = "DARKBLOOM_TTFT_SHAPE_WARMUP"
    /// Wall bound for the probe and shape cells together; each cell's timer gets the remainder.
    static let shapeWarmupBudgetSeconds = 20.0
    /// A request that triggered the load submits during this pause and
    /// preempts the session before any stripe-sized step is in flight.
    static let shapeWarmupGraceSeconds = 0.5
    /// MLX switches softmax rows to the looped kernel above this many keys.
    static let attentionLoopedKeys = 4_096
    /// Bound on waiting for the startup self-test's service charge to retire.
    static let shapeWarmupSettle: Duration = .seconds(2)

    enum ShapeWarmupMode: Sendable, Equatable {
        case off
        /// Shape cells only when the shader-cache probe finds compiles.
        case probed
        case always
    }

    static func shapeWarmupMode(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ShapeWarmupMode {
        guard let raw = environment[shapeWarmupEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty
        else { return .probed }
        if ["0", "false", "no", "off"].contains(raw) { return .off }
        return raw == "always" ? .always : .probed
    }

    /// Run twice before the shape cells. MLX compiles each kernel from source
    /// on first use in a process; the OS caches the result per app, keyed by
    /// source and GPU compiler. With a warm cache the first run costs about as
    /// much as the repeat and the shape cells would only spend GPU time.
    /// Greedy, so both runs decode the same tokens; one decode step reaches
    /// the decode kernels while prefill dominates the probe's cost.
    static let shaderCacheProbe = Cell(promptTokens: 128, outputTokens: 2, width: 1, warmup: true)
    /// The first probe must exceed the repeat by this much and by the repeat
    /// itself. On an M5 Ultra cold caches cost 2.3-2.6 s; a fresh engine's other
    /// first-use work under a warm cache cost at most ~340 ms.
    static let shaderCacheColdMargin: Duration = .milliseconds(750)

    static func shaderCacheLooksCold(first: Duration, repeated: Duration) -> Bool {
        first - repeated > max(shaderCacheColdMargin, repeated)
    }

    /// Excluded first-use shapes for an ordinary engine, before its measured
    /// cells. MLX JIT-compiles one kernel per specialization on first use, and
    /// the 128/512-token cells never reach stripe-height expert tiles, keys past
    /// the looped-softmax limit, a plain chunk beside decoding rows, decode or
    /// MTP verify at the served width, or the default-sampling kernels.
    static func shapeWarmup(stripeTokens: Int?, chunkTokens: Int, width: Int,
        contextTokens: Int?) -> [Cell] {
        let chunk = max(1, chunkTokens)
        // Stripe-wide chunks up to and past the looped-softmax key limit,
        // then an unaligned tail chunk.
        var cells = [Cell(promptTokens: max(stripeTokens ?? chunk, attentionLoopedKeys) + chunk + 188,
            outputTokens: 16, width: 1, warmup: true, sampled: true)]
        if width > 1 {
            // Each later row prefills a plain chunk plus a tail beside the
            // decoding rows; the first row is still decoding when the last joins.
            cells.append(Cell(promptTokens: chunk + 64, outputTokens: 2 * width + 8,
                width: width, warmup: true, sampled: true))
        }
        return cells.compactMap { cell in
            let fitting = min(cell.promptTokens, (contextTokens ?? Int.max) - cell.outputTokens)
            guard fitting >= chunk else { return nil }
            return Cell(promptTokens: fitting, outputTokens: cell.outputTokens, width: cell.width,
                warmup: true, sampled: true)
        }
    }

    /// One bounded solo bootstrap for native models. The tiny first-use run is
    /// excluded, then two cold requests measure both prefill and decode. MiMo
    /// keeps its existing wider bootstrap and periodic maintenance below.
    static let startup = [Cell(promptTokens: 128, outputTokens: 8, width: 1, warmup: true),
        Cell(promptTokens: 512, outputTokens: 32, width: 1),
        Cell(promptTokens: 512, outputTokens: 32, width: 1)]

    static func bootstrap(maximumConcurrency: Int) -> [Cell] {
        var cells = [Cell(promptTokens: 128, outputTokens: 8, width: 1, warmup: true),
            Cell(promptTokens: 512, outputTokens: 32, width: 1),
            Cell(promptTokens: 512, outputTokens: 32, width: 1),
            Cell(promptTokens: 4_096, outputTokens: 32, width: 1),
            Cell(promptTokens: 4_096, outputTokens: 32, width: 1)]
        for width in [2, 4, 8, 16] where width <= maximumConcurrency {
            cells.append(Cell(promptTokens: 512, outputTokens: 32, width: width))
        }
        // Leave a fresh solo decode estimate after the contention sweep.
        cells.append(Cell(promptTokens: 512, outputTokens: 32, width: 1))
        return cells
    }

    // Keep the longer prompt bucket fresh too, when the measured work fits.
    // Finish short so the ordinary aggregate remains the solo baseline.
    static let maintenance = [Cell(promptTokens: 512, outputTokens: 32, width: 1),
        Cell(promptTokens: 4_096, outputTokens: 32, width: 1),
        Cell(promptTokens: 512, outputTokens: 32, width: 1)]

    static func affordable(_ cell: Cell, prefill: Double?, decode: Double?) -> Bool {
        guard cell.promptTokens > 512 || cell.width > 1 else { return true }
        guard let prefill, let decode, prefill.isFinite, decode.isFinite,
            prefill > 0, decode > 0 else { return false }
        // A refusal/skip never expands a deadline or lowers a memory floor.
        return Double(cell.width) * (Double(cell.promptTokens) / prefill
            + Double(cell.outputTokens) / decode) <= maximumGroupSeconds
    }
}

struct ModelCalibrationState {
    var task: Task<Void, Never>?
    var requests: [String: ModelCalibrationPolicy.Cell] = [:]
    var pendingObservations: [String: [EngineRateObservation]] = [:]
    var bootstrapCompleted = false
    /// Set by any attempt foreground work did not preempt.
    var shapeWarmupCompleted = false
    /// Shape cells already run; a preempted attempt resumes after them.
    var shapeWarmupCellsCompleted = 0
    /// Attempts started on this engine, for the outcome log.
    var shapeWarmupAttempts = 0
    /// Finished shader-cache probe runs on this engine: first, then repeat.
    var shaderCacheProbe: [Duration] = []
    /// Undecided until both probes finish. A first probe interrupted after it
    /// was submitted may have compiled kernels, so it decides cold.
    var shaderCacheCold: Bool?
    /// Tests pin the mode; production reads the process environment.
    var shapeWarmupModeOverride: ModelCalibrationPolicy.ShapeWarmupMode?
    var nextAttempt: ContinuousClock.Instant?
    var interrupted = false
    var closed = false
}
