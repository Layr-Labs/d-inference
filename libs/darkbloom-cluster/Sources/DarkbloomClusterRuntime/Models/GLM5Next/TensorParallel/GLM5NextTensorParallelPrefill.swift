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
    /// (`GLM5NextRowCountInvarianceTests`, `GLM53_ROW_COUNT_PROBE=1`).
    static let rowCountInvariantRows = 2048
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
    static func make(promptCount: Int, start: Int, chunkTokens: Int, keepAt: Int, bulkTokens: Int,
                     microBatches: Int, mergedTokens: Int, microBatchTokens: Int? = nil,
                     coalescing: Bool = false) -> Self {
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
        var segments: [Segment] = []
        var offset = start
        let bulk = (bulkTokens / chunkTokens) * chunkTokens
        while offset < promptCount {
            // Bulk chunks while they end at or before the boundary kept for
            // prefixes (or the prompt's end), then chunk-aligned ones.
            let limit = keepAt > offset ? keepAt : promptCount
            let end = offset % chunkTokens == 0 && bulk > chunkTokens && offset + bulk <= limit
                ? offset + bulk : min(promptCount, (offset / chunkTokens + 1) * chunkTokens)
            if coalescing, let limit = microBatchTokens, invariant(end - offset), let last = segments.last,
               last.end != keepAt, invariant(last.end - last.start), end - last.start <= limit {
                // Joins the previous invariant chunk(s): one segment, re-cut.
                segments[segments.count - 1] = .init(start: last.start, end: end, microBatchRows: rows(end - last.start))
            } else {
                segments.append(.init(start: offset, end: end, microBatchRows: rows(end - offset)))
            }
            offset = end
        }
        // Kept after the segment that ends there, unless it is the last one.
        let kept = keepAt > start ? segments.dropLast().firstIndex { $0.end == keepAt } : nil
        let groups = group(segments.map { $0.end - $0.start }, microBatches: segments.map(\.microBatchRows.count),
            limit: mergedTokens)
        var chunks: [Chunk] = []
        var first = 0
        for count in groups {
            let range = first ..< first + count
            chunks.append(.init(segments: Array(segments[range]),
                keptAfter: kept.flatMap { range.contains($0) ? $0 - first + 1 : nil }))
            first += count
        }
        return .init(chunks: chunks)
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
                      microBatches: Int, microBatchTokens: Int? = nil, coalescing: Bool = false) throws -> Chunk {
        guard (start + 1 ... promptCount).contains(end) else {
            throw ProbeError("GLM tensor-parallel prefill frame \(start)..<\(end) is outside the prompt")
        }
        let plan = make(promptCount: promptCount, start: start, chunkTokens: chunkTokens, keepAt: keepAt,
            bulkTokens: bulkTokens, microBatches: microBatches, mergedTokens: 0, microBatchTokens: microBatchTokens,
            coalescing: coalescing)
        let segments = plan.chunks.map { $0.segments[0] }.prefix { $0.end <= end }
        guard segments.last?.end == end else {
            throw ProbeError("GLM tensor-parallel prefill frame \(start)..<\(end) is off the chunk grid")
        }
        let kept = plan.chunks.prefix(segments.count).firstIndex { $0.keptAfter != nil }.map { $0 + 1 }
        return .init(segments: Array(segments), keptAfter: kept)
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

        init(_ chunk: Chunk, stage: GLM5NextTextStage, cache: GLM5NextTextStageCache, prompt: [Int],
             speculation: GLM5NextTensorParallelSpeculation?, inputs: Inputs? = nil) throws {
            self.chunk = chunk; self.cache = cache; self.prompt = prompt; self.speculation = speculation
            self.inputs = inputs
            let segments = chunk.segments.map { GLM5NextPrefillSegment(microBatchRows: $0.microBatchRows) }
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
            try prefill.advance(layers: layers)
            guard layersBuilt < layerCount else { return }
            let frontier = prefill.frontier
            try MLX.withError { error in
                eval(frontier)
                try error.check()
            }
        }

        func finish(observe: ((Int, MLXArray) throws -> Void)? = nil) throws -> FrameResult {
            try complete(try prefill.finish(), chunk: chunk, cache: cache, prompt: prompt, speculation: speculation,
                inputs: inputs, observe: observe)
        }
    }

    /// A frame's rest once its candidate is built: NextN priming per segment
    /// (with the same input rows), the commit, the kept boundary.
    private static func complete(_ candidate: GLM5NextTextStageCandidate, chunk: Chunk, cache: GLM5NextTextStageCache,
                                 prompt: [Int], speculation: GLM5NextTensorParallelSpeculation?, inputs: Inputs?,
                                 observe: ((Int, MLXArray) throws -> Void)?) throws -> FrameResult {
        let last = chunk.end == prompt.count
        var checkpoint: GLM5NextMTPCheckpoint?
        if let speculation {
            for (index, segment) in chunk.segments.enumerated() {
                try speculation.primePrompt(prompt, from: segment.start, to: segment.end,
                    hidden: candidate.segmentHidden[index], inputs: inputs)
                if index + 1 == chunk.keptAfter { checkpoint = try speculation.checkpoint() }
            }
        }
        try candidate.commit { roots in
            eval(roots + (try speculation?.evaluationTargets() ?? []) + (checkpoint?.arrays ?? []))
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
