import Foundation
import MLX
import MLXLLM

/// How a GLM tensor-parallel rank prefills a prompt: which chunks it runs,
/// and in which graphs.
///
/// The chunks ("segments") are the product's: from the restored prefix,
/// bulk chunks of `bulkTokens` while they end at or before the prompt-prefix
/// boundary kept for the request (or the prompt's end), then chunks aligned
/// to `chunkTokens`; each runs as `microBatches` near-equal micro-batches
/// (`GLM5NextPrefillSegment.chunk`). Their micro-batches fix every row's
/// arithmetic: a rank computes each micro-batch with the same rows, positions,
/// shapes and cache as before, so a schedule with the same segments gives
/// the same tokens and cache bits.
///
/// Consecutive segments then run together in one graph (`Chunk`), up to
/// `mergedTokens` tokens (`GLM5NextTextStage.prepareForward(tokens:cache:segments:readout:snapshotAfter:)`):
/// a chunk's last micro-batches wait for the link with nothing left to
/// overlap, and the next chunk's first ones start from an idle GPU, so
/// fewer, longer graphs leave fewer sums exposed, and each sum overlaps more
/// micro-batches. The prompt-prefix boundary may fall inside a graph: the
/// stage then keeps a copy of its cache at that segment's end
/// (`GLM5NextTextStageCandidate.snapshot`), so prefixes are still kept at
/// every `chunkTokens`. `mergedTokens` 0 runs every segment alone, as before
/// segmented prefill. A graph is a lane's prefill frame
/// (`GLM5NextTensorParallelResidentRuntime.prefillFrameEnd`,
/// `runPrefillFrame`); beside decoding lanes the lane loop runs a frame in
/// layer slices (`Slices`), so a decoding lane never waits behind a long frame.
struct GLM5NextTensorParallelPrefillPlan: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let start: Int
        let end: Int
        let microBatchRows: [Int]
        /// The product's micro-batches over these rows when this segment is
        /// cut otherwise (`GLM5NextPrefillSegment.selectionRows`): every row's
        /// DSA top-k pools are chosen among the candidates its product
        /// micro-batch has, so the cut keeps the product's selections. nil:
        /// the product's own micro-batches, or selections not kept.
        let selectionRows: [Int]?

        init(start: Int, end: Int, microBatchRows: [Int], selectionRows: [Int]? = nil) {
            self.start = start; self.end = end; self.microBatchRows = microBatchRows
            self.selectionRows = selectionRows == microBatchRows ? nil : selectionRows
        }
    }

    struct Chunk: Equatable, Sendable {
        let segments: [Segment]
        /// The number of this chunk's segments that end at the kept prompt-prefix
        /// boundary (the last of them ends there), when it ends in this chunk.
        let keptAfter: Int?
        var start: Int { segments[0].start }
        var end: Int { segments[segments.count - 1].end }
        var tokens: Int { end - start }
        var microBatches: Int { segments.reduce(0) { $0 + $1.microBatchRows.count } }
        /// Where the kept boundary falls when it is inside the chunk (the
        /// stage's `snapshotAfter`); nil when it is the chunk's end (the
        /// committed cache is kept) or absent.
        var snapshotAfter: Int? { keptAfter.flatMap { $0 < segments.count ? $0 : nil } }
    }

    let chunks: [Chunk]

    /// Micro-batches of at least this many rows give every row the same bits
    /// whatever their size: measured on one rank's KDA sublayer, DSA attention
    /// (history 0 and 4,096), MoE layer (NVFP4 and affine), dense NVFP4 MLP and
    /// readout at the serving policy (8,192 rows as one call against
    /// 4,096 + 4,096, 4 x 2,048, 3,766 + 4,426, 1,000 + 7,192: bitwise; the mHC
    /// prefill site has its own chunking test). The router's FP32 GEMM
    /// changes its K order below about 1,400 rows (1,280: 91 % of logits differ
    /// by up to 7e-6; 1,414 and up: bitwise), so the bound keeps a margin
    /// (`GLM5NextRowCountInvarianceTests`, `GLM53_ROW_COUNT_PROBE=1`). One
    /// exception, after a history: the DSA selector's order among exactly
    /// tied scores at the top-k boundary depends on the call's candidate
    /// count (on the model, layers 19 and 35 past 16K tokens), which a re-cut
    /// keeps the product's through `Segment.selectionRows`.
    static let rowCountInvariantRows = 2048
    /// The fewest rows measured to give every op the same bits as a bigger
    /// call, without `rowCountInvariantRows`' margin: the router's FP32 GEMM
    /// is bitwise from 1,414 rows (1,280 is not; `GLM5NextRowCountInvarianceTests.routerThreshold`),
    /// the other ops from 1,000. With kept selections the bulk grid's tail
    /// runs as one chunk only when its micro-batches and the product's over
    /// it all have at least this many (31.5K: 2 x 3,462 for 2 x 2,048 +
    /// 2 x 1,414); otherwise it keeps the product's chunks.
    static let tailInvariantRows = 1414
    /// The kept prompt-prefix boundary, when the plan crosses it.
    var keptBoundary: Int? {
        chunks.lazy.compactMap { chunk in chunk.keptAfter.map { chunk.segments[$0 - 1].end } }.first
    }

    /// The plan for prompt positions `start ..< promptCount`. `keepAt` is the
    /// boundary kept for prefixes (0: none); it is kept only when it lies
    /// after `start` and before the last segment. `start` and a nonzero
    /// `keepAt` lie on the `chunkTokens` grid.
    ///
    /// `microBatchTokens`: a chunk whose micro-batches all have at least
    /// `rowCountInvariantRows` rows runs instead as the fewest near-equal
    /// micro-batches of at most that many rows, when those have at least as
    /// many too (others keep their micro-batches). Every row of such a chunk
    /// computes the same bits in a micro-batch of any size in that range
    /// (`rowCountInvariantRows`), so only the GEMM sizes change. With
    /// `coalescing` (a merging frame), consecutive such chunks first join into
    /// one segment of up to `microBatchTokens` tokens (never across the kept
    /// boundary), re-cut the same way, so a micro-batch may span chunks.
    ///
    /// `tailTokens`: past the kept boundary (or with none kept), a rest of at
    /// most this many tokens that starts on the `chunkTokens` grid runs as one
    /// chunk (`GLM5NextTensorParallelResidentRuntime.prefixOnBulkGrid`) instead
    /// of chunk-aligned pieces; with `pinsSelections`, only when every
    /// micro-batch on either side has at least `tailInvariantRows` rows.
    ///
    /// Either cut computes every row's DSA top-k selection differently from
    /// the product's only through the selector's tie order, which depends on
    /// the call's candidate count (`GLM5NextSparseAttention.selectTokens(selectionHistories:)`);
    /// with `pinsSelections` every re-cut segment carries the product's
    /// micro-batches over its rows (`Segment.selectionRows`: the plan from
    /// `start` without either option, kept at `selectionKeepAt`, the
    /// product's boundary, when the bulk grid moves it), so its rows keep the
    /// product's selections and so its bits. Without, a re-cut changes bits.
    ///
    /// `hidesSums`: in each graph a re-cut segment keeps its micro-batches
    /// only where none holds more than half the graph's rows (`hidingSums`),
    /// else it runs as the product's segments; so a frame alone keeps the
    /// product's cut.
    static func make(promptCount: Int, start: Int, chunkTokens: Int, keepAt: Int, bulkTokens: Int,
                     microBatches: Int, mergedTokens: Int, microBatchTokens: Int? = nil,
                     coalescing: Bool = false, tailTokens: Int? = nil, selectionKeepAt: Int? = nil,
                     pinsSelections: Bool = true, hidesSums: Bool = true) -> Self {
        precondition(promptCount > 0 && (0 ..< promptCount).contains(start) && chunkTokens > 0 && microBatches > 0
            && keepAt >= 0 && mergedTokens >= 0 && (microBatchTokens ?? 1) > 0, "GLM tensor-parallel prefill plan bounds")
        func invariant(_ tokens: Int) -> Bool {
            GLM5NextPrefillSegment.chunk(tokens: tokens, microBatches: microBatches).microBatchRows
                .allSatisfy { $0 >= rowCountInvariantRows }
        }
        func rows(_ tokens: Int) -> [Int] {
            let product = GLM5NextPrefillSegment.chunk(tokens: tokens, microBatches: microBatches).microBatchRows
            guard let limit = microBatchTokens, invariant(tokens) else { return product }
            let parts = (tokens + limit - 1) / limit
            let rows = (0 ..< parts).map { (($0 + 1) * tokens / parts) - ($0 * tokens / parts) }
            return rows.allSatisfy { $0 >= rowCountInvariantRows } ? rows : product
        }
        /// The tail from `offset` as one chunk computes the product's bits
        /// (its selections kept): every micro-batch on either side is in the
        /// measured invariant range.
        func tailKeepsBits(_ offset: Int) -> Bool {
            let product = make(promptCount: promptCount, start: offset, chunkTokens: chunkTokens,
                keepAt: selectionKeepAt ?? keepAt, bulkTokens: bulkTokens, microBatches: microBatches, mergedTokens: 0)
            let own = GLM5NextPrefillSegment.chunk(tokens: promptCount - offset, microBatches: microBatches).microBatchRows
            return (own + product.chunks.flatMap(\.segments).flatMap(\.microBatchRows)).allSatisfy { $0 >= tailInvariantRows }
        }
        var segments: [Segment] = []
        var offset = start
        let bulk = (bulkTokens / chunkTokens) * chunkTokens
        while offset < promptCount {
            // Bulk chunks while they end at or before the boundary kept for
            // prefixes (or the prompt's end), then chunk-aligned ones.
            let limit = keepAt > offset ? keepAt : promptCount
            let end: Int
            if let tail = tailTokens, keepAt <= offset, offset % chunkTokens == 0, promptCount - offset <= tail,
               !pinsSelections || tailKeepsBits(offset) {
                end = promptCount
            } else {
                end = offset % chunkTokens == 0 && bulk > chunkTokens && offset + bulk <= limit
                    ? offset + bulk : min(promptCount, (offset / chunkTokens + 1) * chunkTokens)
            }
            if coalescing, let limit = microBatchTokens, invariant(end - offset), let last = segments.last,
               last.end != keepAt, invariant(last.end - last.start), end - last.start <= limit {
                // Joins the previous invariant chunk(s): one segment, re-cut.
                segments[segments.count - 1] = .init(start: last.start, end: end, microBatchRows: rows(end - last.start))
            } else {
                segments.append(.init(start: offset, end: end, microBatchRows: rows(end - offset)))
            }
            offset = end
        }
        let recut = microBatchTokens != nil || tailTokens != nil
        let product = recut ? make(promptCount: promptCount, start: start, chunkTokens: chunkTokens,
            keepAt: selectionKeepAt ?? keepAt, bulkTokens: bulkTokens, microBatches: microBatches, mergedTokens: 0)
            .chunks.flatMap(\.segments) : []
        if pinsSelections, recut {
            segments = pinned(segments, to: product)
        }
        // Kept after the segment that ends there, unless it is the last one.
        let kept = keepAt > start ? segments.dropLast().firstIndex { $0.end == keepAt } : nil
        let groups = group(segments.map { $0.end - $0.start }, microBatches: segments.map(\.microBatchRows.count),
            limit: mergedTokens)
        var chunks: [Chunk] = []
        var first = 0
        for count in groups {
            let range = first ..< first + count
            var graph = Array(segments[range])
            var keptAfter = kept.flatMap { range.contains($0) ? $0 - first + 1 : nil }
            if hidesSums, recut {
                graph = hidingSums(graph, product: product)
                keptAfter = keptAfter.flatMap { _ in graph.firstIndex { $0.end == keepAt }.map { $0 + 1 } }
            }
            chunks.append(.init(segments: graph, keptAfter: keptAfter))
            first += count
        }
        return .init(chunks: chunks)
    }

    /// One graph's segments, each re-cut one (unlike the product's
    /// `product` segments) kept only where every micro-batch of it holds at
    /// most half the graph's rows, else replaced by the product's segments
    /// over its rows. A micro-batch's two sealed sums a layer overlap the
    /// graph's other micro-batches; one bigger than the rest of its graph
    /// leaves its sums exposed. Pair: 10.5K as [8,192 | 1,154, 1,154] ran
    /// 16.6 % slower than the product's [4,096, 4,096 | 1,154, 1,154] (the
    /// 8,192-row sums behind 2,308 rows); 31.5K as [8,192 x 3, 4,096, 1,414 x 2]
    /// ran 4.2 % faster. A frame alone (no merging) keeps the product's.
    static func hidingSums(_ graph: [Segment], product: [Segment]) -> [Segment] {
        let rows = graph.reduce(0) { $0 + $1.end - $1.start }
        return graph.flatMap { segment -> [Segment] in
            let own = product.contains { $0.start == segment.start && $0.end == segment.end
                && $0.microBatchRows == segment.microBatchRows }
            guard !own, segment.microBatchRows.contains(where: { 2 * $0 > rows }) else { return [segment] }
            let members = product.filter { $0.start >= segment.start && $0.end <= segment.end }
            guard members.first?.start == segment.start, members.last?.end == segment.end,
                  zip(members.dropFirst(), members).allSatisfy({ $0.start == $1.end }) else { return [segment] }
            return members
        }
    }

    /// `segments` each with the micro-batches `product` cuts its rows into
    /// (`Segment.selectionRows`). Both plans start at the same position, and
    /// every segment starts and ends where a product micro-batch does (a
    /// segment that did not would keep its own selections).
    static func pinned(_ segments: [Segment], to product: [Segment]) -> [Segment] {
        let rows = product.flatMap(\.microBatchRows)
        let ends = rows.reduce(into: [segments.first?.start ?? 0]) { $0.append($0[$0.count - 1] + $1) }
        return segments.map { segment in
            let inside = ends.filter { $0 >= segment.start && $0 <= segment.end }
            guard inside.first == segment.start, inside.last == segment.end else { return segment }
            return .init(start: segment.start, end: segment.end, microBatchRows: segment.microBatchRows,
                selectionRows: zip(inside.dropFirst(), inside).map { $0 - $1 })
        }
    }

    /// Consecutive groups of segments (their counts), each at most `limit`
    /// tokens or a single segment: the fewest groups; among those, the most
    /// micro-batches in the group with the fewest (every sum is overlapped by
    /// the group's other micro-batches); then the smallest largest group.
    static func group(_ tokens: [Int], microBatches: [Int], limit: Int) -> [Int] {
        let n = tokens.count
        guard n > 0 else { return [] }
        struct Best { var groups: Int; var fewest: Int; var largest: Int; var next: Int }
        func better(_ a: Best, _ b: Best) -> Bool {
            if a.groups != b.groups { return a.groups < b.groups }
            if a.fewest != b.fewest { return a.fewest > b.fewest }
            return a.largest < b.largest
        }
        // best[i]: segments i..<n.
        var best = [Best?](repeating: nil, count: n + 1)
        best[n] = Best(groups: 0, fewest: Int.max, largest: 0, next: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var size = 0, batches = 0
            for j in i + 1 ... n {
                size += tokens[j - 1]; batches += microBatches[j - 1]
                guard j == i + 1 || size <= limit, let rest = best[j] else { break }
                let candidate = Best(groups: rest.groups + 1, fewest: min(batches, rest.fewest),
                    largest: max(size, rest.largest), next: j)
                if best[i].map({ better(candidate, $0) }) ?? true { best[i] = candidate }
            }
        }
        var counts: [Int] = []
        var i = 0
        while i < n, let step = best[i] { counts.append(step.next - i); i = step.next }
        return counts
    }

    /// The frame `start ..< end` of the plan from `start` without merging
    /// (the product's chunks): its segments, which must end exactly at `end`,
    /// and the kept boundary when one of them ends there. Both ranks derive a
    /// frame's segments from its bounds alone.
    static func frame(start: Int, end: Int, promptCount: Int, chunkTokens: Int, keepAt: Int, bulkTokens: Int,
                      microBatches: Int, microBatchTokens: Int? = nil, coalescing: Bool = false,
                      tailTokens: Int? = nil, selectionKeepAt: Int? = nil, pinsSelections: Bool = true,
                      hidesSums: Bool = true) throws -> Chunk {
        guard (start + 1 ... promptCount).contains(end) else {
            throw ProbeError("GLM tensor-parallel prefill frame \(start)..<\(end) is outside the prompt")
        }
        let plan = make(promptCount: promptCount, start: start, chunkTokens: chunkTokens, keepAt: keepAt,
            bulkTokens: bulkTokens, microBatches: microBatches, mergedTokens: 0, microBatchTokens: microBatchTokens,
            coalescing: coalescing, tailTokens: tailTokens, selectionKeepAt: selectionKeepAt,
            pinsSelections: pinsSelections, hidesSums: false)
        var segments = Array(plan.chunks.map { $0.segments[0] }.prefix { $0.end <= end })
        guard segments.last?.end == end else {
            throw ProbeError("GLM tensor-parallel prefill frame \(start)..<\(end) is off the chunk grid")
        }
        let kept = plan.chunks.prefix(segments.count).contains { $0.keptAfter != nil }
        if hidesSums, microBatchTokens != nil || tailTokens != nil {
            // The frame is one graph: the plan's rule over the same segments.
            segments = hidingSums(segments, product: make(promptCount: promptCount, start: start,
                chunkTokens: chunkTokens, keepAt: selectionKeepAt ?? keepAt, bulkTokens: bulkTokens,
                microBatches: microBatches, mergedTokens: 0).chunks.flatMap(\.segments))
        }
        return .init(segments: segments, keptAfter: kept ? segments.firstIndex { $0.end == keepAt }.map { $0 + 1 } : nil)
    }

    /// Command-buffer limits every frame's GPU work is encoded under (this
    /// thread's MLX override), or nil for the process's own (a worker's
    /// `MLX_MAX_OPS_PER_BUFFER` guard, 16 operations; tp-check's MLX default,
    /// 50 on an Ultra). Only where MLX commits a buffer changes, never what
    /// the GPU computes. Set before the first frame (runtime load, bench).
    nonisolated(unsafe) static var commandBuffers: GPU.CommandBufferLimits?

    static func encoding<R>(_ body: () throws -> R) rethrows -> R {
        guard let limits = commandBuffers else { return try body() }
        return try GPU.withCommandBufferLimits(limits, body)
    }

    /// Diagnostic, `DARKBLOOM_GLM_PREFILL_FRAME_TIMING=1`: every prefill frame
    /// writes one `glm-prefill-frame-v1` line to stderr: its rows and
    /// micro-batches, the time building its layers (each sum issued as it is
    /// built, so the GPU runs meanwhile), finishing (the readout and NextN
    /// priming built), and the commit's evaluation; MLX's active memory at
    /// its start and end, its peak and the memory limit (GB); the operation
    /// limit it encoded under. A tp-check rank and a serving rank print the
    /// same line for the same frame. A serving rank also turns it on when the
    /// file `frameTimingSwitch` exists under its home at load (read once,
    /// `enableFrameTimingFromSwitch`; no environment needed). Never on in
    /// production.
    nonisolated(unsafe) static var frameTiming =
        ProcessInfo.processInfo.environment["DARKBLOOM_GLM_PREFILL_FRAME_TIMING"] == "1"
    static let frameTimingSwitch = ".darkbloom/cluster-setup/prefill-frame-timing"

    /// Turns frame timing on when `frameTimingSwitch` exists under this
    /// process's home; returns the source (`env`, `file` or `off`) for the
    /// load line. Call once, before the first frame.
    static func enableFrameTimingFromSwitch() -> String {
        if frameTiming { return "env" }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(frameTimingSwitch)
        guard FileManager.default.fileExists(atPath: file.path) else { return "off" }
        frameTiming = true
        return "file"
    }

    final class FrameClock {
        var build: UInt64 = 0
        var finish: UInt64 = 0
        var commit: UInt64 = 0
        var started: UInt64 = 0
        var activeAtStart = 0

        static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

        func line(_ chunk: Chunk) -> String {
            func ms(_ n: UInt64) -> String { String(format: "%.1f", Double(n) / 1e6) }
            func gb(_ b: Int) -> String { String(format: "%.2f", Double(b) / 1e9) }
            let total = Self.now() - started
            return "glm-prefill-frame-v1 start=\(chunk.start) end=\(chunk.end)"
                + " micro_batches=\(chunk.segments.map { $0.microBatchRows.map(String.init).joined(separator: "+") }.joined(separator: "|"))"
                + " build_ms=\(ms(build)) finish_ms=\(ms(finish)) commit_ms=\(ms(commit)) total_ms=\(ms(total))"
                + " active_gb=\(gb(activeAtStart))->\(gb(Memory.activeMemory)) peak_gb=\(gb(Memory.peakMemory))"
                + " limit_gb=\(gb(Memory.memoryLimit)) cache_gb=\(gb(Memory.cacheMemory))"
                + " ops=\(GLM5NextTensorParallelPrefillPlan.commandBuffers.map { String($0.operations) } ?? "process")"
        }
    }

    /// One frame (`chunk`) on `stage` from `cache` (at the frame's start):
    /// its segments in one graph, each segment's hidden rows priming
    /// `speculation`'s NextN history in that evaluation as one prefill per
    /// segment would; `observe`, when given, gets each segment's start and
    /// evaluated hidden rows `[1, tokens, hidden]`. Returns the last prompt
    /// token's logits `[1, vocabulary]` and hidden row `[1, 1, hidden]` when
    /// the frame ends the prompt, and the kept boundary with the stage cache at
    /// it (evaluated) and the NextN history at it.
    ///
    /// `inputs` (a media prompt, `GLM5NextTensorParallelMedia.embeddings`):
    /// the input embeddings `[1, n, hidden]` of prompt positions
    /// `lower ..< upper` with media rows replaced by their features, or nil
    /// where those positions hold none. A frame with media rows runs from its
    /// embeddings through the same segments and micro-batches
    /// (`GLM5NextTextStage.prepareForward(embeddings:cache:segments:readout:snapshotAfter:)`:
    /// the token path's rows with those inputs, so merging stays bitwise), and
    /// the NextN history is primed with the same rows.
    static func run(_ chunk: Chunk, stage: GLM5NextTextStage, cache: GLM5NextTextStageCache, prompt: [Int],
                    speculation: GLM5NextTensorParallelSpeculation?, observe: ((Int, MLXArray) throws -> Void)? = nil,
                    inputs: Inputs? = nil) throws -> FrameResult {
        let slices = try Slices(chunk, stage: stage, cache: cache, prompt: prompt, speculation: speculation,
            inputs: inputs)
        try slices.advance(layers: slices.layerCount)
        return try slices.finish(observe: observe)
    }

    /// A media prompt's input embeddings for prompt positions `lower ..< upper`
    /// (`run`'s `inputs`), nil where they hold no media rows.
    typealias Inputs = (_ lower: Int, _ upper: Int) throws -> MLXArray?
    typealias FrameResult = (final: (logits: MLXArray, lastHidden: MLXArray)?,
                             kept: (end: Int, cache: GLM5NextTextStageCache, history: GLM5NextMTPCheckpoint?)?)

    /// A frame (`chunk`, from its tokens or, with media rows, its `inputs`)
    /// run in layer slices (`GLM5NextTextStage.beginForward`): `advance(layers:)`
    /// builds and evaluates the next layers of every micro-batch, so other
    /// lanes may run their units between slices; `finish()` reads out, primes
    /// NextN, commits and keeps the boundary. `run` is all layers then
    /// `finish`, so a sliced frame's micro-batches, ops and their order are
    /// `run`'s and its results `run`'s bits; only when the GPU runs each part
    /// changes. `cache` must not change until `finish` (no other lane touches it).
    final class Slices {
        let chunk: Chunk
        private let prefill: GLM5NextSlicedPrefill
        private let cache: GLM5NextTextStageCache
        private let prompt: [Int]
        private let speculation: GLM5NextTensorParallelSpeculation?
        private let inputs: Inputs?
        var layersBuilt: Int { prefill.layersBuilt }
        var layerCount: Int { prefill.layerCount }
        private let clock = FrameClock()

        init(_ chunk: Chunk, stage: GLM5NextTextStage, cache: GLM5NextTextStageCache, prompt: [Int],
             speculation: GLM5NextTensorParallelSpeculation?, inputs: Inputs? = nil) throws {
            self.chunk = chunk; self.cache = cache; self.prompt = prompt; self.speculation = speculation
            self.inputs = inputs
            let segments = chunk.segments.map {
                GLM5NextPrefillSegment(microBatchRows: $0.microBatchRows, selectionRows: $0.selectionRows)
            }
            let readout: GLM5NextTextStageReadout = chunk.end == prompt.count ? .lastToken : .none
            if let embedded = try inputs?(chunk.start, chunk.end) {
                prefill = try stage.beginForward(embeddings: embedded, cache: cache, segments: segments,
                    readout: readout, snapshotAfter: chunk.snapshotAfter)
            } else {
                prefill = try stage.beginForward(
                    tokens: MLXArray(prompt[chunk.start ..< chunk.end].map(Int32.init), [1, chunk.tokens]),
                    cache: cache, segments: segments, readout: readout, snapshotAfter: chunk.snapshotAfter)
            }
        }

        /// Builds the next `layers` layers; evaluates them unless they are the
        /// frame's last (`finish` evaluates those with the readout).
        func advance(layers: Int) throws {
            let timing = GLM5NextTensorParallelPrefillPlan.frameTiming
            if timing, clock.started == 0 {
                clock.started = FrameClock.now(); clock.activeAtStart = Memory.activeMemory
                Memory.peakMemory = 0
            }
            let began = timing ? FrameClock.now() : 0
            defer { if timing { clock.build += FrameClock.now() - began } }
            try GLM5NextTensorParallelPrefillPlan.encoding {
                try prefill.advance(layers: layers)
                guard layersBuilt < layerCount else { return }
                let frontier = prefill.frontier
                try MLX.withError { error in
                    eval(frontier)
                    try error.check()
                }
            }
        }

        func finish(observe: ((Int, MLXArray) throws -> Void)? = nil) throws -> FrameResult {
            let timing = GLM5NextTensorParallelPrefillPlan.frameTiming
            let finishing = FrameClock.now()
            let result = try GLM5NextTensorParallelPrefillPlan.encoding {
                try complete(try prefill.finish(), chunk: chunk, cache: cache, prompt: prompt,
                    speculation: speculation, inputs: inputs, observe: observe,
                    clock: timing ? (clock, finishing) : nil)
            }
            if timing { FileHandle.standardError.write(Data((clock.line(chunk) + "\n").utf8)) }
            return result
        }
    }

    /// A frame's rest once its candidate is built: NextN priming per segment
    /// (with the same input rows), the commit, the kept boundary.
    private static func complete(_ candidate: GLM5NextTextStageCandidate, chunk: Chunk, cache: GLM5NextTextStageCache,
                                 prompt: [Int], speculation: GLM5NextTensorParallelSpeculation?, inputs: Inputs?,
                                 observe: ((Int, MLXArray) throws -> Void)?,
                                 clock: (FrameClock, UInt64)? = nil) throws -> FrameResult {
        let last = chunk.end == prompt.count
        var checkpoint: GLM5NextMTPCheckpoint?
        if let speculation {
            for (index, segment) in chunk.segments.enumerated() {
                try speculation.primePrompt(prompt, from: segment.start, to: segment.end,
                    hidden: candidate.segmentHidden[index], inputs: inputs)
                if index + 1 == chunk.keptAfter { checkpoint = try speculation.checkpoint() }
            }
        }
        let committing = FrameClock.now()
        try candidate.commit { roots in
            eval(roots + (try speculation?.evaluationTargets() ?? []) + (checkpoint?.arrays ?? []))
        }
        if let (clock, finishing) = clock {
            clock.finish += committing - finishing
            clock.commit += FrameClock.now() - committing
        }
        if let observe {
            for (segment, hidden) in zip(chunk.segments, candidate.segmentHidden) { try observe(segment.start, hidden) }
        }
        var final: (logits: MLXArray, lastHidden: MLXArray)?
        if last, case .final(let output) = candidate.output {
            final = (output.logits[0..., -1, 0...], output.hidden[0..., (-1)..., 0...])
        }
        let kept = chunk.keptAfter.map { (chunk.segments[$0 - 1].end, candidate.snapshot ?? cache, checkpoint) }
        return (final, kept)
    }

    /// Every frame of the plan, in order (`run(_:stage:cache:prompt:speculation:observe:)`);
    /// `keep` receives the kept boundary. Returns the last prompt token's
    /// logits and hidden row.
    func run(stage: GLM5NextTextStage, cache: GLM5NextTextStageCache, prompt: [Int],
             speculation: GLM5NextTensorParallelSpeculation?,
             observe: ((Int, MLXArray) throws -> Void)? = nil,
             inputs: ((_ lower: Int, _ upper: Int) throws -> MLXArray?)? = nil,
             keep: (Int, GLM5NextTextStageCache, GLM5NextMTPCheckpoint?) throws -> Void)
        throws -> (logits: MLXArray, lastHidden: MLXArray) {
        var result: (logits: MLXArray, lastHidden: MLXArray)?
        for chunk in chunks {
            let frame = try Self.run(chunk, stage: stage, cache: cache, prompt: prompt, speculation: speculation,
                observe: observe, inputs: inputs)
            if let final = frame.final { result = final }
            if let kept = frame.kept { try keep(kept.end, kept.cache, kept.history) }
        }
        guard let result else { throw ProbeError("GLM tensor-parallel prefill produced no logits") }
        return result
    }
}
