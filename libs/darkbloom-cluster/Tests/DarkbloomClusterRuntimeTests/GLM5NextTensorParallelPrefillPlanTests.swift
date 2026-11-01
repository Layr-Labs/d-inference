import Foundation
import MLX
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// The GLM tensor-parallel prefill schedule: run alone, its chunks are the
/// product's (the loop the runtime ran before merging, transcribed below);
/// merged, the same chunks with the same micro-batches run in fewer graphs,
/// and on a tiny stage the merged prefill is bit for bit the chunk-by-chunk
/// one (logits, last hidden row, cache, NextN history, kept prefix), for a
/// text prompt and for one whose media rows are features.
@Suite("GLM tensor-parallel prefill plan", .serialized)
struct GLM5NextTensorParallelPrefillPlanTests {
    typealias Plan = GLM5NextTensorParallelPrefillPlan

    /// The runtime's prefill loop before merging: each chunk's range, its
    /// micro-batch rows, and whether the prefix is kept after it.
    static func productChunks(promptCount: Int, start: Int, chunk: Int, keepAt: Int, bulk bulkTokens: Int,
                              microBatches: Int) -> [(start: Int, end: Int, rows: [Int], kept: Bool)] {
        var chunks: [(start: Int, end: Int, rows: [Int], kept: Bool)] = []
        var offset = start
        while offset < promptCount {
            let bulk = (bulkTokens / chunk) * chunk
            let limit = keepAt > offset ? keepAt : promptCount
            let end = offset % chunk == 0 && bulk > chunk && offset + bulk <= limit
                ? offset + bulk : min(promptCount, (offset / chunk + 1) * chunk)
            let last = end == promptCount
            let tokens = end - offset
            let parts = min(microBatches, tokens / GLM5NextTextStage.minimumMicroBatchTokens)
            let rows = parts > 1
                ? (0 ..< parts).map { (($0 + 1) * tokens / parts) - ($0 * tokens / parts) } : [tokens]
            chunks.append((offset, end, rows, !last && end == keepAt && keepAt > start))
            offset = end
        }
        return chunks
    }

    static func runtimePlan(promptCount: Int, start: Int = 0, prefix: Bool = true, merged: Int) -> Plan {
        let chunk = GLM5NextTensorParallelResidentRuntime.prefillChunkTokens
        return Plan.make(promptCount: promptCount, start: start, chunkTokens: chunk,
            keepAt: prefix ? ((promptCount - 1) / chunk) * chunk : 0,
            bulkTokens: GLM5NextTensorParallelResidentRuntime.bulkPrefillChunkTokens,
            microBatches: GLM5NextTensorParallelResidentRuntime.prefillMicroBatches, mergedTokens: merged)
    }

    @Test func unmergedPlansAreTheProductsChunks() {
        let chunk = GLM5NextTensorParallelResidentRuntime.prefillChunkTokens
        var lengths = Array(1 ... 40) + [255, 256, 511, 512, 513, 2_700, 4_095, 4_096, 4_097, 8_191, 8_192, 8_193,
            10_500, 12_288, 12_289, 15_724, 16_384, 16_385, 20_000, 24_000, 31_500, 31_600, 32_768, 65_536, 131_072]
        lengths += stride(from: 1_000, through: 70_000, by: 3_331).map { $0 }
        for count in lengths {
            for prefix in [true, false] {
                for start in stride(from: 0, to: count, by: chunk).prefix(4) {
                    let keepAt = prefix ? ((count - 1) / chunk) * chunk : 0
                    let expected = Self.productChunks(promptCount: count, start: start, chunk: chunk, keepAt: keepAt,
                        bulk: GLM5NextTensorParallelResidentRuntime.bulkPrefillChunkTokens,
                        microBatches: GLM5NextTensorParallelResidentRuntime.prefillMicroBatches)
                    let plan = Self.runtimePlan(promptCount: count, start: start, prefix: prefix, merged: 0)
                    #expect(plan.chunks.count == expected.count, "prompt \(count) from \(start)")
                    for (chunk, want) in zip(plan.chunks, expected) {
                        #expect(chunk.segments.count == 1)
                        #expect(chunk.start == want.start && chunk.end == want.end
                            && chunk.segments[0].microBatchRows == want.rows, "prompt \(count) from \(start)")
                        #expect((chunk.keptAfter == 1) == want.kept && chunk.snapshotAfter == nil)
                    }
                }
            }
        }
    }

    @Test func mergedPlansKeepEverySegmentAndFitTheLimit() {
        let chunk = GLM5NextTensorParallelResidentRuntime.prefillChunkTokens
        for count in [1, 300, 2_700, 4_096, 8_193, 10_500, 15_724, 20_000, 24_000, 31_500, 65_536, 131_072]
            + stride(from: 2_000, through: 70_000, by: 2_777).map({ $0 }) {
            for start in stride(from: 0, to: count, by: chunk).prefix(3) {
                for limit in [4_096, 12_288, 16_384, 32_768] {
                    let alone = Self.runtimePlan(promptCount: count, start: start, merged: 0)
                    let merged = Self.runtimePlan(promptCount: count, start: start, merged: limit)
                    // The same segments in the same order: the same micro-batches.
                    #expect(merged.chunks.flatMap(\.segments) == alone.chunks.flatMap(\.segments))
                    #expect(merged.keptBoundary == alone.keptBoundary)
                    for chunk in merged.chunks {
                        #expect(chunk.tokens <= limit || chunk.segments.count == 1)
                        if let kept = chunk.keptAfter {
                            #expect(chunk.segments[kept - 1].end == merged.keptBoundary)
                        }
                    }
                    // No two neighbours would have fitted one graph together.
                    let fewest = Plan.group(alone.chunks.map(\.tokens), microBatches: alone.chunks.map(\.microBatches),
                        limit: limit).count
                    #expect(merged.chunks.count == fewest)
                    var greedy = 0, used = 0
                    for tokens in alone.chunks.map(\.tokens) {
                        if greedy == 0 || used + tokens > limit { greedy += 1; used = tokens } else { used += tokens }
                    }
                    #expect(merged.chunks.count <= greedy)
                }
            }
        }
    }

    /// Re-cut chunks keep their tokens and every micro-batch on both sides of
    /// the re-cut is in the row-count invariant range; other chunks are unchanged.
    @Test func largerMicroBatchesStayInTheInvariantRange() {
        let floor = Plan.rowCountInvariantRows
        for count in stride(from: 1_000, through: 70_000, by: 1_237) {
            let alone = Self.runtimePlan(promptCount: count, merged: 0).chunks.flatMap(\.segments)
            for limit in [2_048, 4_096, 6_000, 8_192, 16_384] {
                let chunk = GLM5NextTensorParallelResidentRuntime.prefillChunkTokens
                let recut = Plan.make(promptCount: count, start: 0, chunkTokens: chunk,
                    keepAt: ((count - 1) / chunk) * chunk,
                    bulkTokens: GLM5NextTensorParallelResidentRuntime.bulkPrefillChunkTokens, microBatches: 2,
                    mergedTokens: 0, microBatchTokens: limit).chunks.flatMap(\.segments)
                #expect(recut.count == alone.count)
                for (a, b) in zip(alone, recut) {
                    #expect(a.start == b.start && a.end == b.end)
                    if a.microBatchRows != b.microBatchRows {
                        #expect(a.microBatchRows.allSatisfy { $0 >= floor } && b.microBatchRows.allSatisfy { $0 >= floor })
                        #expect(b.microBatchRows.allSatisfy { $0 <= limit })
                    }
                }
            }
        }
    }

    /// Coalescing joins consecutive invariant chunks (never across the kept
    /// boundary) into segments of at most the micro-batch size, re-cut; the
    /// same rows in the same order; frames rebuilt from their bounds agree.
    @Test func coalescedChunksShareMicroBatchesOnlyInTheInvariantRange() throws {
        let floor = Plan.rowCountInvariantRows
        let chunk = GLM5NextTensorParallelResidentRuntime.prefillChunkTokens
        let bulk = GLM5NextTensorParallelResidentRuntime.bulkPrefillChunkTokens
        func plan(_ count: Int, start: Int = 0, limit: Int, merged: Int) -> Plan {
            Plan.make(promptCount: count, start: start, chunkTokens: chunk, keepAt: ((count - 1) / chunk) * chunk,
                bulkTokens: bulk, microBatches: 2, mergedTokens: merged, microBatchTokens: limit, coalescing: true)
        }
        // 16,384 rows hold more than half the graph's 31,500: the product's segments there.
        #expect(plan(31_500, limit: 16_384, merged: 32_768).chunks.map { $0.segments.map(\.microBatchRows) }
            == [[[4_096, 4_096], [4_096, 4_096], [12_288], [1_414, 1_414]]])
        #expect(plan(31_500, limit: 8_192, merged: 32_768).chunks.map { $0.segments.map(\.microBatchRows) }
            == [[[8_192], [8_192], [8_192], [4_096], [1_414, 1_414]]])
        // The kept boundary (28,672) stays a segment end.
        #expect(plan(31_500, limit: 16_384, merged: 32_768).keptBoundary == 28_672)
        for count in stride(from: 1_500, through: 70_000, by: 1_733) {
            let keepAt = ((count - 1) / chunk) * chunk
            let alone = Self.runtimePlan(promptCount: count, merged: 0).chunks.flatMap(\.segments)
            for limit in [8_192, 12_288, 16_384] {
                for merged in [16_384, 32_768] {
                    let value = plan(count, limit: limit, merged: merged)
                    let segments = value.chunks.flatMap(\.segments)
                    #expect(segments.first?.start == 0 && segments.last?.end == count)
                    #expect(value.keptBoundary == alone.firstIndex { $0.end == keepAt && $0.end < count }.map { _ in keepAt })
                    for segment in segments {
                        let members = alone.filter { $0.start >= segment.start && $0.end <= segment.end }
                        #expect(members.first?.start == segment.start && members.last?.end == segment.end)
                        if members.count > 1 || members[0].microBatchRows != segment.microBatchRows {
                            #expect(members.allSatisfy { $0.microBatchRows.allSatisfy { $0 >= floor } })
                            #expect(segment.microBatchRows.allSatisfy { $0 >= floor && $0 <= limit })
                            #expect(!members.dropLast().contains { $0.end == keepAt })
                        }
                    }
                    // Frames rebuilt from their bounds are the plan's graphs.
                    var offset = 0
                    for graph in value.chunks {
                        let end = Plan.make(promptCount: count, start: offset, chunkTokens: chunk, keepAt: keepAt,
                            bulkTokens: bulk, microBatches: 2, mergedTokens: merged, microBatchTokens: limit,
                            coalescing: true).chunks[0].end
                        #expect(end == graph.end)
                        let frame = try Plan.frame(start: offset, end: end, promptCount: count, chunkTokens: chunk,
                            keepAt: keepAt, bulkTokens: bulk, microBatches: 2, microBatchTokens: limit, coalescing: true)
                        #expect(frame == graph, "prompt \(count) limit \(limit) merged \(merged)")
                        offset = end
                    }
                }
            }
        }
    }

    /// The endpoint's prompt sizes under the runtime's constants.
    /// `prefixOnBulkGrid` (owner decision, off): prefixes kept every 8,192
    /// tokens and the rest past the kept boundary as one chunk.
    @Test func theBulkGridKeepsPrefixesEvery8KAndRunsTheRestAsOneChunk() {
        func plan(_ count: Int, merged: Int = 0) -> Plan {
            let grid = 8192
            return Plan.make(promptCount: count, start: 0, chunkTokens: 4096, keepAt: ((count - 1) / grid) * grid,
                bulkTokens: 8192, microBatches: 2, mergedTokens: merged, tailTokens: 8192)
        }
        let p = plan(31_500)
        #expect(p.chunks.map { $0.segments.map(\.microBatchRows) } == [[[4096, 4096]], [[4096, 4096]],
            [[4096, 4096]], [[3462, 3462]]])
        #expect(p.keptBoundary == 24_576)
        #expect(plan(16_384).chunks.map(\.tokens) == [8192, 8192] && plan(16_384).keptBoundary == 8192)
        #expect(plan(10_500).chunks.map(\.tokens) == [8192, 2308])
        #expect(plan(24_577).chunks.map(\.tokens) == [8192, 8192, 8192, 1])
        #expect(plan(3_931).chunks.map(\.tokens) == [3931])
        #expect(plan(31_500, merged: 16_384).chunks.map(\.tokens) == [16_384, 15_116])
        // Off: the product's chunks.
        let product = Plan.make(promptCount: 31_500, start: 0, chunkTokens: 4096, keepAt: 28_672, bulkTokens: 8192,
            microBatches: 2, mergedTokens: 0)
        #expect(product.chunks.map(\.tokens) == [8192, 8192, 8192, 4096, 2828])
    }

    /// Re-cut plans keep the product's DSA selections: every segment cut
    /// unlike the product's micro-batches carries those over its rows
    /// (`Segment.selectionRows`), with larger micro-batches, coalesced chunks
    /// and the bulk grid (whose product keeps prefixes every chunk), from a
    /// cold or a restored start; frames rebuilt from their bounds carry the
    /// same; without `pinsSelections` none does.
    @Test func reCutSegmentsKeepTheProductsSelections() throws {
        let chunk = 4096, bulk = 8192
        func make(_ count: Int, start: Int, bulkGrid: Bool, limit: Int?, coalescing: Bool, merged: Int,
                  pins: Bool = true) -> Plan {
            let keepAt = ((count - 1) / (bulkGrid ? bulk : chunk)) * (bulkGrid ? bulk : chunk)
            return Plan.make(promptCount: count, start: start, chunkTokens: chunk, keepAt: keepAt, bulkTokens: bulk,
                microBatches: 2, mergedTokens: merged, microBatchTokens: limit, coalescing: coalescing,
                tailTokens: bulkGrid ? bulk : nil, selectionKeepAt: ((count - 1) / chunk) * chunk, pinsSelections: pins)
        }
        func selections(_ plan: Plan) -> [[Int]?] { plan.chunks.flatMap(\.segments).map(\.selectionRows) }
        // 31.5K: 8K micro-batches keep the bulk chunks' 4K halves and the boundary chunk's 2K ones
        // (in 16K graphs the third bulk chunk would hold more than half of its graph: the product's).
        #expect(selections(make(31_500, start: 0, bulkGrid: false, limit: 8_192, coalescing: false, merged: 32_768))
            == [[4_096, 4_096], [4_096, 4_096], [4_096, 4_096], [2_048, 2_048], nil])
        #expect(selections(make(31_500, start: 0, bulkGrid: false, limit: 8_192, coalescing: false, merged: 16_384))
            == [[4_096, 4_096], [4_096, 4_096], nil, [2_048, 2_048], nil])
        // The bulk grid's tail (2 x 3,462) keeps the product's 2 x 2,048 + 2 x 1,414.
        #expect(selections(make(31_500, start: 0, bulkGrid: true, limit: nil, coalescing: false, merged: 0))
            == [nil, nil, nil, [2_048, 2_048, 1_414, 1_414]])
        // A tail over product halves under the measured bound (14,000: 2 x 856) keeps the product's chunks.
        let short = make(14_000, start: 0, bulkGrid: true, limit: nil, coalescing: false, merged: 0)
        #expect(short.chunks.map(\.tokens) == [8_192, 4_096, 1_712] && selections(short).allSatisfy { $0 == nil })
        #expect(make(14_000, start: 0, bulkGrid: true, limit: nil, coalescing: false, merged: 0, pins: false)
            .chunks.map(\.tokens) == [8_192, 5_808])
        for count in stride(from: 1_500, through: 70_000, by: 1_733) {
            let keepAt = ((count - 1) / chunk) * chunk
            // Cold, and restored on the 8K and the 4K grid.
            for start in Set([0, ((count - 1) / bulk) * bulk, ((count - 1) / chunk) * chunk, min(chunk, keepAt)]).sorted() {
                let productPlan = Plan.make(promptCount: count, start: start, chunkTokens: chunk, keepAt: keepAt,
                    bulkTokens: bulk, microBatches: 2, mergedTokens: 0)
                let product = productPlan.chunks.flatMap(\.segments)
                let productEnds = Set(product.flatMap { segment in
                    segment.microBatchRows.reduce(into: [segment.start]) { $0.append($0[$0.count - 1] + $1) } })
                for (bulkGrid, limit, coalescing, merged) in [(false, 8_192, false, 16_384), (false, 16_384, true, 32_768),
                        (true, nil, false, 16_384), (true, 8_192, true, 16_384)] as [(Bool, Int?, Bool, Int)]
                        where !bulkGrid || start % bulk == 0 {   // the bulk grid restores only on its grid
                    let label = "prompt \(count) start \(start) grid \(bulkGrid) limit \(limit ?? 0) merged \(merged)"
                    let plan = make(count, start: start, bulkGrid: bulkGrid, limit: limit, coalescing: coalescing,
                        merged: merged)
                    // On the chunk grid the prompt prefix is kept where the product keeps it (a micro-batch edge).
                    if !bulkGrid { #expect(plan.keptBoundary == productPlan.keptBoundary, "\(label)") }
                    for segment in plan.chunks.flatMap(\.segments) {
                        if segment.selectionRows != nil, bulkGrid, limit == nil {
                            #expect((segment.microBatchRows + segment.selectionRows!).allSatisfy {
                                $0 >= Plan.tailInvariantRows }, "\(label) tail \(segment.start)")
                        }
                        let rows = segment.selectionRows ?? segment.microBatchRows
                        let ends = rows.reduce(into: [segment.start]) { $0.append($0[$0.count - 1] + $1) }
                        #expect(ends == productEnds.filter { (segment.start ... segment.end).contains($0) }.sorted(),
                            "\(label) segment \(segment.start)..<\(segment.end)")
                    }
                    #expect(selections(make(count, start: start, bulkGrid: bulkGrid, limit: limit,
                        coalescing: coalescing, merged: merged, pins: false)).allSatisfy { $0 == nil }, "\(label)")
                    // Frames rebuilt from their bounds are the plan's graphs, selections included.
                    var offset = start
                    for graph in plan.chunks {
                        let frame = try Plan.frame(start: offset, end: graph.end, promptCount: count, chunkTokens: chunk,
                            keepAt: ((count - 1) / (bulkGrid ? bulk : chunk)) * (bulkGrid ? bulk : chunk),
                            bulkTokens: bulk, microBatches: 2, microBatchTokens: limit, coalescing: coalescing,
                            tailTokens: bulkGrid ? bulk : nil, selectionKeepAt: keepAt)
                        #expect(frame.segments == graph.segments, "\(label) frame \(offset)")
                        offset = graph.end
                    }
                }
            }
        }
    }

    /// The runtime's merging plan (its micro-batch size, coalescing).
    static func servingPlan(promptCount: Int, start: Int = 0) -> Plan {
        let runtime = GLM5NextTensorParallelResidentRuntime.self
        let chunk = runtime.prefillChunkTokens
        return Plan.make(promptCount: promptCount, start: start, chunkTokens: chunk,
            keepAt: ((promptCount - 1) / chunk) * chunk, bulkTokens: runtime.bulkPrefillChunkTokens,
            microBatches: runtime.prefillMicroBatches, mergedTokens: runtime.mergedPrefillTokens,
            microBatchTokens: runtime.prefillMicroBatchTokens, coalescing: true,
            selectionKeepAt: ((promptCount - 1) / chunk) * chunk)
    }

    /// Bigger micro-batches only where their sums stay hidden: none may hold
    /// more than half its graph's rows (`Plan.hidingSums`); a frame alone,
    /// and frames rebuilt from their bounds, follow the same rule.
    @Test func reCutMicroBatchesKeepTheirSumsHidden() throws {
        let chunk = 4096, bulk = 8192
        func shape(_ count: Int, merged: Int = 32_768, all: Bool = false) -> [[Int]] {
            let keepAt = ((count - 1) / chunk) * chunk
            return Plan.make(promptCount: count, start: 0, chunkTokens: chunk, keepAt: keepAt, bulkTokens: bulk,
                microBatches: 2, mergedTokens: merged, microBatchTokens: 8_192, coalescing: merged > 0,
                selectionKeepAt: keepAt, hidesSums: !all).chunks.map { $0.segments.flatMap(\.microBatchRows) }
        }
        // The pair's two points: 10.5K lost 16.6 % as [8,192 | 1,154 x 2], 31.5K gained 4.2 %.
        #expect(shape(10_500, all: true) == [[8_192, 1_154, 1_154]])
        #expect(shape(10_500) == [[4_096, 4_096, 1_154, 1_154]])
        #expect(shape(31_500) == [[8_192, 8_192, 8_192, 4_096, 1_414, 1_414]])
        #expect(shape(6_000) == [[2_048, 2_048, 952, 952]])
        #expect(shape(16_384) == [[8_192, 4_096, 4_096]])
        #expect(shape(24_000) == [[8_192, 8_192, 4_096, 1_760, 1_760]])
        #expect(shape(2_700) == [[1_350, 1_350]])
        // Frames alone keep the product's cut.
        #expect(shape(31_500, merged: 0) == [[4_096, 4_096], [4_096, 4_096], [4_096, 4_096], [2_048, 2_048],
            [1_414, 1_414]])
        for count in stride(from: 1_500, through: 70_000, by: 977) {
            let keepAt = ((count - 1) / chunk) * chunk
            for merged in [0, 16_384, 32_768] {
                let plan = Plan.make(promptCount: count, start: 0, chunkTokens: chunk, keepAt: keepAt,
                    bulkTokens: bulk, microBatches: 2, mergedTokens: merged, microBatchTokens: 8_192,
                    coalescing: merged > 0, selectionKeepAt: keepAt)
                var offset = 0
                for graph in plan.chunks {
                    let rows = graph.tokens
                    for segment in graph.segments where segment.selectionRows != nil {
                        #expect(segment.microBatchRows.allSatisfy { 2 * $0 <= rows }, "prompt \(count) merged \(merged)")
                    }
                    let frame = try Plan.frame(start: offset, end: graph.end, promptCount: count, chunkTokens: chunk,
                        keepAt: keepAt, bulkTokens: bulk, microBatches: 2, microBatchTokens: 8_192,
                        coalescing: merged > 0, selectionKeepAt: keepAt)
                    #expect(frame == graph, "prompt \(count) merged \(merged) frame \(offset)")
                    offset = graph.end
                }
                #expect(plan.keptBoundary == (keepAt > 0 ? keepAt : nil), "prompt \(count) merged \(merged)")
            }
        }
    }

    @Test func endpointPromptsRunInFewGraphs() {
        func shape(_ count: Int) -> [[Int]] {
            Self.servingPlan(promptCount: count).chunks.map { $0.segments.flatMap(\.microBatchRows) }
        }
        #expect(shape(2_700) == [[1_350, 1_350]])
        // 10.5K: an 8,192-row micro-batch would hold more than half the graph: the product's cut,
        // the prefix kept at 8,192 inside the graph.
        #expect(shape(10_500) == [[4_096, 4_096, 1_154, 1_154]])
        let plan = Self.servingPlan(promptCount: 10_500)
        #expect(plan.chunks[0].snapshotAfter == 1 && plan.keptBoundary == 8_192)
        // 31.5K: one graph of 8,192-row micro-batches, each row keeping its product selection.
        #expect(shape(31_500) == [[8_192, 8_192, 8_192, 4_096, 1_414, 1_414]])
        #expect(Self.servingPlan(promptCount: 31_500).chunks[0].segments.map(\.selectionRows)
            == [[4_096, 4_096], [4_096, 4_096], [4_096, 4_096], [2_048, 2_048], nil])
        #expect(Self.servingPlan(promptCount: 31_500).keptBoundary == 28_672)
        #expect(Self.runtimePlan(promptCount: 31_500, merged: 0).chunks.count == 5)
        // Larger micro-batches re-cut only chunks whose rows are all in the
        // row-count invariant range; the tail's small halves stay.
        func cut(_ count: Int, _ tokens: Int) -> [[Int]] {
            let chunk = GLM5NextTensorParallelResidentRuntime.prefillChunkTokens
            return Plan.make(promptCount: count, start: 0, chunkTokens: chunk, keepAt: ((count - 1) / chunk) * chunk,
                bulkTokens: GLM5NextTensorParallelResidentRuntime.bulkPrefillChunkTokens, microBatches: 2,
                mergedTokens: 16_384, microBatchTokens: tokens).chunks.map { $0.segments.map(\.microBatchRows) }.flatMap { $0 }
        }
        #expect(cut(31_500, 4_096) == [[4_096, 4_096], [4_096, 4_096], [4_096, 4_096], [4_096], [1_414, 1_414]])
        // In 16K graphs the third bulk chunk's 8,192 rows would hold more than half its graph.
        #expect(cut(31_500, 8_192) == [[8_192], [8_192], [4_096, 4_096], [4_096], [1_414, 1_414]])
        #expect(cut(10_500, 3_000) == [[2_730, 2_731, 2_731], [1_154, 1_154]])
        // A restored prefix starts on the chunk grid.
        #expect(Self.servingPlan(promptCount: 31_500, start: 28_672).chunks.map(\.tokens) == [2_828])
    }

    /// A frame rebuilt from its bounds (as `runPrefillFrame` and a lane's
    /// peer do) is the plan's graph: the same chunks and kept boundary; the
    /// runtime's merging frames walk the merged plan from any restored start.
    @Test func framesRebuiltFromTheirBoundsAreThePlansGraphs() throws {
        let runtime = GLM5NextTensorParallelResidentRuntime.self
        let chunk = runtime.prefillChunkTokens
        for count in [1, 2_700, 8_192, 10_500, 15_724, 20_000, 24_000, 31_500, 65_536]
            + stride(from: 3_000, through: 70_000, by: 4_111).map({ $0 }) {
            let keepAt = runtime.prefixKeepAt(promptCount: count, chunk: chunk, prefixEnabled: true)
            for start in stride(from: 0, to: count, by: chunk).prefix(3) {
                for merging in [false, true] {
                    let plan = Plan.make(promptCount: count, start: start, chunkTokens: chunk, keepAt: keepAt,
                        bulkTokens: runtime.bulkPrefillChunkTokens, microBatches: runtime.prefillMicroBatches,
                        mergedTokens: merging ? runtime.mergedPrefillTokens : 0,
                        microBatchTokens: runtime.prefillMicroBatchTokens, coalescing: merging, selectionKeepAt: keepAt)
                    var offset = start
                    for graph in plan.chunks {
                        let end = runtime.prefillFrameEnd(offset: offset, promptCount: count, chunk: chunk,
                            keepAt: keepAt, merging: merging, selectionKeepAt: keepAt)
                        #expect(end == graph.end, "prompt \(count) from \(start)")
                        let frame = try Plan.frame(start: offset, end: end, promptCount: count, chunkTokens: chunk,
                            keepAt: keepAt, bulkTokens: runtime.bulkPrefillChunkTokens,
                            microBatches: runtime.prefillMicroBatches, microBatchTokens: runtime.prefillMicroBatchTokens,
                            coalescing: merging, selectionKeepAt: keepAt)
                        #expect(frame == graph, "prompt \(count) from \(start)")
                        offset = end
                    }
                    #expect(offset == count)
                }
            }
            // A frame off the chunk grid or outside the prompt is refused.
            if count > 5_000 {
                #expect(throws: ProbeError.self) {
                    try Plan.frame(start: 0, end: 4_097, promptCount: count, chunkTokens: chunk, keepAt: keepAt,
                        bulkTokens: runtime.bulkPrefillChunkTokens, microBatches: runtime.prefillMicroBatches)
                }
            }
            #expect(throws: ProbeError.self) {
                try Plan.frame(start: 0, end: count + 1, promptCount: count, chunkTokens: chunk, keepAt: keepAt,
                    bulkTokens: runtime.bulkPrefillChunkTokens, microBatches: runtime.prefillMicroBatches)
            }
        }
    }

    // MARK: - Tiny stage on the GPU

    static func bytes(_ array: MLXArray) -> Data { array.asData(access: .copy).data }

    static func fence(_ arrays: [MLXArray]) throws {
        try MLX.withError { error in
            eval(arrays); Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
        }
    }

    struct Prefilled {
        let logits: MLXArray
        let lastHidden: MLXArray
        let cache: GLM5NextTextStageCache
        let history: [MLXArray]
        let kept: [(Int, [MLXArray], [MLXArray])]
    }

    /// Prefill of a tiny whole-model stage with a NextN layer, either by the
    /// runtime's loop before merging (`legacy`) or by `plan`; with
    /// `sliceLayers`, each frame in layer slices of that many layers
    /// (`Plan.Slices`), another request's one-token step between slices.
    static func prefill(_ stage: GLM5NextTextStage, mtp: GLM5NextMTP, prompt: [Int], chunk: Int, bulk: Int,
                        merged: Int, legacy: Bool = false, prefix: Bool = true,
                        inputs: ((Int, Int) throws -> MLXArray?)? = nil, sliceLayers: Int? = nil) throws -> Prefilled {
        let speculation = try GLM5NextTensorParallelSpeculation(mtp: mtp, depth: 1, rank: 0, ranks: 1,
            primeRows: 3, agree: { $0 })
        let cache = stage.newCache()
        let keepAt = prefix ? ((prompt.count - 1) / chunk) * chunk : 0
        var kept: [(Int, [MLXArray], [MLXArray])] = []
        func keep(_ end: Int, _ cache: GLM5NextTextStageCache, _ history: GLM5NextMTPCheckpoint?) throws {
            let state = cache.copy().layers.flatMap { $0.state }, arrays = history?.arrays ?? []
            try fence(state + arrays)
            kept.append((end, state, arrays))
        }
        if legacy {
            var logits: MLXArray?, lastHidden: MLXArray?
            for chunk in Self.productChunks(promptCount: prompt.count, start: 0, chunk: chunk, keepAt: keepAt,
                                            bulk: bulk, microBatches: 2) {
                let last = chunk.end == prompt.count
                let tokens = MLXArray(prompt[chunk.start ..< chunk.end].map(Int32.init), [1, chunk.end - chunk.start])
                // A media chunk as the runtime ran it before merging: its embeddings.
                let candidate = try inputs?(chunk.start, chunk.end).map {
                    try stage.prepareForward(embeddings: $0, cache: cache, readout: last ? .lastToken : .none)
                } ?? stage.prepareForward(tokens: tokens, cache: cache, readout: last ? .lastToken : .none)
                switch candidate.output {
                case .final(let output):
                    try speculation.primePrompt(prompt, from: chunk.start, to: chunk.end, hidden: output.hidden,
                        inputs: inputs)
                case .hidden(let hidden):
                    try speculation.primePrompt(prompt, from: chunk.start, to: chunk.end, hidden: hidden, inputs: inputs)
                case .streams: throw ProbeError("tiny stage returned streams")
                }
                try candidate.commit { roots in try fence(roots + (try speculation.evaluationTargets())) }
                if last, case .final(let output) = candidate.output {
                    logits = output.logits[0..., -1, 0...]; lastHidden = output.hidden[0..., (-1)..., 0...]
                }
                if chunk.kept { try keep(chunk.end, cache, try speculation.checkpoint()) }
            }
            let history = try speculation.evaluationTargets()
            try fence(history + [try #require(logits), try #require(lastHidden)])
            return .init(logits: logits!, lastHidden: lastHidden!, cache: cache, history: history, kept: kept)
        }
        let plan = Plan.make(promptCount: prompt.count, start: 0, chunkTokens: chunk, keepAt: keepAt,
            bulkTokens: bulk, microBatches: 2, mergedTokens: merged)
        if let sliceLayers {
            let other = stage.newCache()
            var result: (logits: MLXArray, lastHidden: MLXArray)?
            for (index, chunk) in plan.chunks.enumerated() {
                let slices = try Plan.Slices(chunk, stage: stage, cache: cache, prompt: prompt, speculation: speculation,
                    inputs: inputs)
                while slices.layersBuilt < slices.layerCount {
                    try slices.advance(layers: min(sliceLayers, slices.layerCount - slices.layersBuilt))
                    let step = try stage.prepareForward(tokens: MLXArray([Int32(5 + index)], [1, 1]), cache: other,
                        readout: .lastToken)
                    try step.commit { try fence($0) }
                }
                let frame = try slices.finish()
                if let final = frame.final { result = final }
                if let kept = frame.kept { try keep(kept.end, kept.cache, kept.history) }
            }
            let history = try speculation.evaluationTargets()
            let final = try #require(result)
            try fence(history + [final.logits, final.lastHidden])
            return .init(logits: final.logits, lastHidden: final.lastHidden, cache: cache, history: history, kept: kept)
        }
        let result = try plan.run(stage: stage, cache: cache, prompt: prompt, speculation: speculation, inputs: inputs,
            keep: keep)
        let history = try speculation.evaluationTargets()
        try fence(history + [result.logits, result.lastHidden])
        return .init(logits: result.logits, lastHidden: result.lastHidden, cache: cache, history: history, kept: kept)
    }

    static func same(_ a: [MLXArray], _ b: [MLXArray]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.shape == $1.shape && bytes($0) == bytes($1) }
    }

    /// The bench's divergence probe on the tiny stage: one line per layer and
    /// a verdict; the same cut never differs.
    @Test func theDivergenceProbeComparesEveryLayer() throws {
        defer {
            do { try MLX.withError { error in Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check() } }
            catch { Issue.record(error, "GLM prefill plan fixture cleanup fence failed") }
        }
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let c = loader.configuration.textConfig
        let stage = try loader.loadTextStage(plan: .init(configuration: c, layers: 0 ..< c.hiddenLayers))
        let prompt = (0 ..< 37).map { 4 + ($0 * 7) % 23 }
        for (start, count, rows) in [(0, 37, 37), (0, 37, 20), (16, 21, 21), (16, 21, 11)] {
            var lines: [String] = []
            try GLM5NextTensorParallelBench.divergenceProbe(stage: stage, prompt: prompt, start: start, count: count,
                microBatchTokens: rows, microBatches: 2, log: { lines.append($0) })
            let layerLines = lines.filter { $0.hasPrefix("divergence layer=") }
            #expect(layerLines.count == c.hiddenLayers)
            #expect(lines.contains { $0.hasPrefix("divergence readout ") })
            #expect(lines.contains { $0.hasPrefix("divergence prefix ") } == (start > 0))
            if rows == count { #expect(lines.last == "divergence first_layer=none") }
            #expect(lines.last?.hasPrefix("divergence first_layer=") == true)
        }
    }

    @Test func mergedPrefillIsTheChunkByChunkPrefillBitForBit() throws {
        defer {
            do { try MLX.withError { error in Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check() } }
            catch { Issue.record(error, "GLM prefill plan fixture cleanup fence failed") }
        }
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let c = loader.configuration.textConfig
        let stage = try loader.loadTextStage(plan: .init(configuration: c, layers: 0 ..< c.hiddenLayers))
        let mtp = try loader.loadMTP(stage: stage)
        let prompt = (0 ..< 37).map { 4 + ($0 * 7) % 23 }
        // Segments 8, 8, 8, 8, 4 (kept at 36), 1: merged as [8, 8] [8, 8] [4 | 1].
        let plan = Plan.make(promptCount: prompt.count, start: 0, chunkTokens: 4, keepAt: 36, bulkTokens: 8,
            microBatches: 2, mergedTokens: 16)
        #expect(plan.chunks.map(\.tokens) == [16, 16, 5] && plan.chunks[2].snapshotAfter == 1)
        let legacy = try Self.prefill(stage, mtp: mtp, prompt: prompt, chunk: 4, bulk: 8, merged: 0, legacy: true)
        // Whole frames, and frames in layer slices with another request's steps between.
        for (merged, slices) in [(0, nil), (16, nil), (64, nil), (16, 1), (64, 2), (0, 3)] as [(Int, Int?)] {
            let value = try Self.prefill(stage, mtp: mtp, prompt: prompt, chunk: 4, bulk: 8, merged: merged,
                sliceLayers: slices)
            #expect(Self.same([value.logits, value.lastHidden], [legacy.logits, legacy.lastHidden]), "merged \(merged) slices \(slices ?? 0)")
            let (a, b) = (value.cache.layers.flatMap(\.state), legacy.cache.layers.flatMap(\.state))
            try Self.fence(a + b)
            #expect(value.cache.offset == prompt.count && Self.same(a, b), "merged \(merged) slices \(slices ?? 0)")
            #expect(Self.same(value.history, legacy.history), "merged \(merged) slices \(slices ?? 0)")
            #expect(value.kept.count == 1 && legacy.kept.count == 1)
            for (x, y) in zip(value.kept, legacy.kept) {
                #expect(x.0 == y.0 && Self.same(x.1, y.1) && Self.same(x.2, y.2), "merged \(merged) slices \(slices ?? 0)")
            }
        }
    }

    /// A media prompt (`GLM5NextTensorParallelMedia`: no prompt prefix, feature
    /// rows spliced over its media positions, the NextN history primed with
    /// them): merged frames are the chunk-by-chunk media prefill bit for bit,
    /// with media spans that cross chunk and graph boundaries.
    @Test func mergedMediaPrefillIsTheChunkByChunkPrefillBitForBit() throws {
        defer {
            do { try MLX.withError { error in Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check() } }
            catch { Issue.record(error, "GLM prefill plan fixture cleanup fence failed") }
        }
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let c = loader.configuration.textConfig
        let stage = try loader.loadTextStage(plan: .init(configuration: c, layers: 0 ..< c.hiddenLayers))
        let mtp = try loader.loadMTP(stage: stage)
        let embedding = try #require(stage.embedding)
        let prompt = (0 ..< 37).map { 4 + ($0 * 7) % 23 }
        // Segments 8, 8, 8, 8, 4, 1 (no kept prefix); media 5..<9 crosses the
        // first segment boundary, 14..<19 the first merged graph's end (16).
        let media: [Range<Int>] = [5 ..< 9, 14 ..< 19]
        let dtype = embedding(MLXArray([Int32(4)], [1, 1])).dtype
        let features = MLXRandom.normal([prompt.count, c.hiddenSize], key: MLXRandom.key(11)).asType(dtype)
        try Self.fence([features])
        let inputs: (Int, Int) throws -> MLXArray? = { lower, upper in
            let rows = media.compactMap { span -> (Range<Int>, MLXArray)? in
                let lo = max(span.lowerBound, lower), hi = min(span.upperBound, upper)
                return lo < hi ? (lo ..< hi, features[lo ..< hi]) : nil
            }
            guard !rows.isEmpty else { return nil }
            let tokens = MLXArray(prompt[lower ..< upper].map(Int32.init), [1, upper - lower])
            return GLM5NextTensorParallelMedia.splice(text: embedding(tokens), start: lower, rows: rows)
        }
        let legacy = try Self.prefill(stage, mtp: mtp, prompt: prompt, chunk: 4, bulk: 8, merged: 0, legacy: true,
            prefix: false, inputs: inputs)
        let text = try Self.prefill(stage, mtp: mtp, prompt: prompt, chunk: 4, bulk: 8, merged: 0, legacy: true,
            prefix: false)
        #expect(!Self.same([legacy.logits], [text.logits]), "the media rows change the result")
        // Whole frames, and frames in layer slices with another request's steps between.
        for (merged, slices) in [(0, nil), (16, nil), (64, nil), (16, 1), (64, 2)] as [(Int, Int?)] {
            let value = try Self.prefill(stage, mtp: mtp, prompt: prompt, chunk: 4, bulk: 8, merged: merged,
                prefix: false, inputs: inputs, sliceLayers: slices)
            #expect(Self.same([value.logits, value.lastHidden], [legacy.logits, legacy.lastHidden]), "merged \(merged) slices \(slices ?? 0)")
            let (a, b) = (value.cache.layers.flatMap(\.state), legacy.cache.layers.flatMap(\.state))
            try Self.fence(a + b)
            #expect(value.cache.offset == prompt.count && Self.same(a, b), "merged \(merged) slices \(slices ?? 0)")
            #expect(Self.same(value.history, legacy.history), "merged \(merged) slices \(slices ?? 0)")
            #expect(value.kept.isEmpty && legacy.kept.isEmpty)
        }
    }
}
