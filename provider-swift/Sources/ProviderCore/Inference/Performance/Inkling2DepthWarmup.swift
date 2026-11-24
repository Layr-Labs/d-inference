// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon

/// Inkling 2's per-depth load warm-up (measured on the M5 Max): before the
/// provider admits traffic, every verify width the served drafter can reach
/// is compiled in the process, so a first request
/// does not pay the first-use compiles mid-stream (a fresh k = 4 request went
/// from 43.3 to 61.4 tok/s, adaptive 30.7 to 62.3).
///
/// A fixed draft depth cannot be asked of the serving engine (its adaptive
/// policy picks one per round), so each depth k in 0 (drafter off) ... 7 runs
/// on a private engine over the loaded model with its own scratch paged pool
/// (the serving pool's geometry and segment size, a small grant) and the
/// drafter's fixed-depth profile (`Inkling2DSparkDrafter.defaultMTPConfig(
/// maxDraftTokens: k, adaptive: false)`):
/// - one row, a 4,224-token prompt (history past 2,048 tokens: the split and
///   merge attention pass and the one-row 4K pool class), 12 output tokens;
/// - 2 and 8 rows of 256-token prompts where the served width allows (the
///   widest served width below 8 otherwise), 12 output tokens;
/// - with the drafter, one 2-row cell of unequal prompts (256 and 1,100) for
///   the drafter's padded-context mask.
/// The paged attention binds one of two segment counts per pass (2, or the
/// pass's maximum: 8 fused, 16 otherwise), so each depth also runs one wide
/// cell (8 rows of 256) and one long cell (4,224 tokens) on a second scratch
/// pool with small segments, where those calls touch more than two segments
/// and compile the large binding; the serving-size pool's calls compile the
/// small one. The certified head's kernels for 1-64 rows compile when each
/// engine starts (SDK, `cbv2WarmCertifiedTokens`).
/// Every request is greedy with the prefix cache off; the engine has no
/// prefix or checkpoint store, no tenant scope, no network and no rate or
/// ledger state, and its pool is released after its depth. Outputs are
/// discarded. The existing shape cells (`ModelCalibrationPolicy.inkling2Warmup`)
/// still run first.
enum Inkling2DepthWarmup {
    static let depths = 0...7
    static let longPromptTokens = 4_224
    static let shortPromptTokens = 256
    static let paddedPromptTokens = [256, 1_100]
    static let outputTokens = 12
    /// The scratch pool's grant; the largest cell holds a few hundred MB.
    static let scratchGrantBytes = 2 << 30
    /// Segment size of the small-segment scratch pool: a 256-token row of one
    /// full-attention slot is 1 MiB, so 8 such rows span 4 segments (fused
    /// binding 8) and a 4,224-token row spans 9 (binding 16).
    static let smallSegmentBytes = 2 << 20
    /// A depth's cells stop when the warm-up has run this long.
    static let budgetSeconds = 180.0
    /// `DARKBLOOM_INKLING2_DEPTH_WARMUP=0` skips the per-depth warm-up (the
    /// shape cells still run); `DARKBLOOM_TTFT_SHAPE_WARMUP=0` skips both.
    static let environmentKey = "DARKBLOOM_INKLING2_DEPTH_WARMUP"

    static func enabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return true }
        return !["0", "false", "no", "off"].contains(raw)
    }

    struct Cell: Equatable, Sendable {
        let depth: Int
        /// One prompt length per row.
        let promptTokens: [Int]
        /// Runs on the small-segment pool (the large segment bindings).
        var smallSegments = false
        var rows: Int { promptTokens.count }
    }

    /// The cells for a served width (`servedRows`, the engine's running-row
    /// cap), the drafter's speculating-row limit and the served context. A
    /// depth past 0 runs only with the drafter loaded.
    static func plan(
        servedRows: Int, speculativeRows: Int, drafterAvailable: Bool, contextTokens: Int?
    ) -> [Cell] {
        let context = contextTokens ?? Int.max
        func fits(_ prompt: Int) -> Bool { prompt + outputTokens <= context }
        var cells: [Cell] = []
        for depth in depths where depth == 0 || drafterAvailable {
            let allowed = depth == 0 ? max(1, servedRows) : max(1, min(servedRows, speculativeRows))
            if fits(longPromptTokens) { cells.append(Cell(depth: depth, promptTokens: [longPromptTokens])) }
            var widths: [Int] = []
            for rows in [2, min(8, allowed)] where rows >= 2 && rows <= allowed && !widths.contains(rows) {
                widths.append(rows)
            }
            if fits(shortPromptTokens) {
                for rows in widths {
                    cells.append(Cell(depth: depth, promptTokens: Array(repeating: shortPromptTokens, count: rows)))
                }
            }
            if depth > 0, allowed >= 2, paddedPromptTokens.allSatisfy(fits) {
                cells.append(Cell(depth: depth, promptTokens: paddedPromptTokens))
            }
            if let widest = widths.last, fits(shortPromptTokens) {
                cells.append(Cell(depth: depth, promptTokens: Array(repeating: shortPromptTokens, count: widest),
                                  smallSegments: true))
            }
            if fits(longPromptTokens) {
                cells.append(Cell(depth: depth, promptTokens: [longPromptTokens], smallSegments: true))
            }
        }
        return cells
    }

    /// Row `row`'s prompt of exactly `tokens` tokens, read cyclically from
    /// `base` (a rendered calibration prompt) at an offset per row, so rows
    /// differ and any length can be drawn from one render.
    static func prompt(from base: [Int], tokens: Int, row: Int) -> [Int] {
        guard !base.isEmpty, tokens > 0 else { return [] }
        let offset = (row * 31) % base.count
        return (0..<tokens).map { base[(offset + $0) % base.count] }
    }

    /// Builds the private engine for a depth sized for `rows` running rows,
    /// on the serving-size pool or the small-segment one.
    typealias MakeEngine = @Sendable (_ depth: Int, _ rows: Int, _ smallSegments: Bool) throws -> any CBv2Engine

    /// What the serving slot hands its bridge: the engine builder and the
    /// served limits (`EngineV2Factory.inkling2DepthWarmup`).
    struct Runner: Sendable {
        let makeEngine: MakeEngine
        let servedRows: Int
        let speculativeRows: Int
        let drafterAvailable: Bool
        /// Whether the Mac has room for a scratch pool now.
        let memoryPermits: @Sendable () -> Bool
    }

    struct Outcome: Equatable, Sendable {
        var cellsRun = 0
        var cellsPlanned = 0
        var milliseconds = 0
        /// "complete", "budget", "cancelled", "memory", or the failure.
        var summary = "complete"
    }

    /// Runs `cells` depth by depth, one private engine per depth. A failure
    /// ends the warm-up (the serving engine is untouched); cancellation ends it
    /// between cells.
    static func run(
        _ cells: [Cell], runner: Runner, basePrompt: [Int],
        budgetSeconds: Double = budgetSeconds
    ) async -> Outcome {
        let clock = ContinuousClock()
        let started = clock.now
        var outcome = Outcome(cellsPlanned: cells.count)
        var requestID: UInt64 = 1
        struct Group: Hashable { let depth: Int; let smallSegments: Bool }
        let groups = Dictionary(grouping: cells) { Group(depth: $0.depth, smallSegments: $0.smallSegments) }
        let order = groups.keys.sorted { ($0.depth, $0.smallSegments ? 1 : 0) < ($1.depth, $1.smallSegments ? 1 : 0) }
        depthLoop: for group in order {
            guard let depthCells = groups[group], let rows = depthCells.map(\.rows).max() else { continue }
            if Task.isCancelled { outcome.summary = "cancelled"; break }
            guard runner.memoryPermits() else { outcome.summary = "memory"; break }
            let engine: any CBv2Engine
            do { engine = try runner.makeEngine(group.depth, rows, group.smallSegments) } catch {
                outcome.summary = "engine (\(type(of: error)))"
                break
            }
            for cell in depthCells {
                if Task.isCancelled { outcome.summary = "cancelled"; break }
                guard WedgeMonitor.seconds(clock.now - started) < budgetSeconds else {
                    outcome.summary = "budget"; break
                }
                do {
                    try await runCell(cell, engine: engine, basePrompt: basePrompt, firstID: requestID)
                    outcome.cellsRun += 1
                } catch {
                    outcome.summary = "cell (\(type(of: error)))"
                }
                requestID += UInt64(cell.rows)
                if outcome.summary != "complete" { break }
            }
            await engine.shutdown()
            if outcome.summary != "complete" { break depthLoop }
        }
        // The scratch pools' buffers go back to the system, not to MLX's cache.
        MLX.Memory.clearCache()
        outcome.milliseconds = Int((WedgeMonitor.seconds(clock.now - started) * 1_000).rounded())
        return outcome
    }

    /// One cell: its rows submitted together so they batch, each greedy with
    /// the prefix cache off, and awaited to the end. Outputs are discarded.
    private static func runCell(
        _ cell: Cell, engine: any CBv2Engine, basePrompt: [Int], firstID: UInt64
    ) async throws {
        var streams: [AsyncStream<CBv2Event>] = []
        for (row, tokens) in cell.promptTokens.enumerated() {
            let prompt = prompt(from: basePrompt, tokens: tokens, row: row + cell.depth * 8)
            streams.append(try engine.submit(.init(
                id: .init(firstID + UInt64(row)), promptTokens: prompt, sampling: .init(temperature: 0),
                maxTokens: outputTokens, prefixCacheEnabled: false)))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for stream in streams {
                group.addTask {
                    for await event in stream {
                        guard case .finished(let reason, _) = event else { continue }
                        switch reason {
                        case .stop, .length: break
                        case .cancelled: throw WarmupCellError(message: "cancelled")
                        case .error(let message): throw WarmupCellError(message: message)
                        case .terminal(let cause, _): throw WarmupCellError(message: "\(cause)")
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    struct WarmupCellError: Error { let message: String }
}
