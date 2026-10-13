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
    var bootstrapCompleted = false
    var nextAttempt: ContinuousClock.Instant?
    var interrupted = false
    var closed = false
}
