import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// A GLM tensor-parallel rank's prompt prefix through the SSD tier
/// (`GLM5NextTensorParallelPrefixDisk`), on a real stage and NextN layer: a
/// request prefills on the chunk grid and the memory tier keeps its boundary
/// as `runPrefillFrame` does; the record is captured from that entry as
/// `persistPrefix` does (its pages read on the writer), written, found by a
/// new tier on the same directory, read and checked as
/// `restoreAgreedFromEitherTier` does, and written into a fresh request's own
/// pages. Every layer's history and KDA state and the NextN history are the
/// entry's bytes, and the request continues (the rest of the prompt and a
/// speculative round) exactly as the request that prefilled, and as one
/// restored from memory. The tiny synthetic stage, paged (pages of four
/// tokens) and contiguous histories.
///
/// Opt-in (`GLM53_PREFIX_SSD=1`, GPU, about 1 GB of synthetic weights): the
/// same on the synthetic serving-policy stage at the artifact's widths
/// (`GLM5NextTensorParallelSpeculationRowsTests`), paged at the runtime's
/// page size, with prompt and boundary of hundreds of tokens.
@Suite("GLM tensor-parallel prefix SSD restore", .serialized)
struct GLM5NextTensorParallelPrefixRestoreTests {
    typealias Record = GLM5NextTensorParallelPrefixRecord
    typealias Plan = GLM5NextTensorParallelPrefillPlan
    static let servingEnabled = ProcessInfo.processInfo.environment["GLM53_PREFIX_SSD"] == "1"

    static func fence(_ arrays: [MLXArray]) throws {
        try MLX.withError { error in eval(arrays); try error.check() }
    }

    static func bytes(_ array: MLXArray) -> Data { array.asData(access: .copy).data }

    static func same(_ a: [MLXArray], _ b: [MLXArray]) throws -> Bool {
        try fence(a + b)
        return a.count == b.count
            && zip(a, b).allSatisfy { $0.shape == $1.shape && $0.dtype == $1.dtype && bytes($0) == bytes($1) }
    }

    /// A request's page reservation as the runtime makes it: every DSA and
    /// the NextN history at its prompt and a few outputs.
    static func reserve(_ pool: GLM5NextDSAPagePool?, stage: GLM5NextTextStage, tokens: Int) throws
        -> GLM5NextPageReservation? {
        try pool.map { pool in
            GLM5NextPageReservation(pool: pool, account: try pool.reserve(pages: GLM5NextTensorParallelResidentRuntime
                .historyPages(pool: pool, configuration: stage.plan.configuration, contextTokens: tokens, speculative: true)))
        }
    }

    /// One request as the runtime runs it on one rank: its pages, its NextN
    /// state, its start (cold, a memory entry's copy, or an SSD record written
    /// into its own state), then its prefill on the chunk grid; the memory
    /// tier keeps the boundary the prefill crosses.
    final class Request {
        enum Start {
            case cold
            case memory((cache: GLM5NextTextStageCache, mtp: GLM5NextMTPCheckpoint?))
            case ssd(Record.Restorable, Record.Layout)
        }

        let pages: GLM5NextPageReservation?
        let speculation: GLM5NextTensorParallelSpeculation
        let cache: GLM5NextTextStageCache
        let logits: MLXArray
        let hidden: MLXArray

        init(stage: GLM5NextTextStage, mtp: GLM5NextMTP, pool: GLM5NextDSAPagePool?, prompt: [Int], chunk: Int,
             bulk: Int, boundary: Int, start: Start, memory: GLM5NextTensorParallelPrefixCache? = nil) throws {
            pages = try GLM5NextTensorParallelPrefixRestoreTests.reserve(pool, stage: stage, tokens: prompt.count + 16)
            speculation = try GLM5NextTensorParallelSpeculation(mtp: mtp, depth: 2, rank: 0, ranks: 1, primeRows: 64,
                pagePool: pool, pageAccount: pages?.account, agree: { $0 })
            var cache = stage.newCache(account: pages?.account), offset = 0
            switch start {
            case .cold: break
            case .memory(let entry):
                cache = entry.cache
                cache.bindPages(to: pages?.account)
                try speculation.restore(entry.mtp)
                offset = boundary
            case .ssd(let record, let layout):
                try record.write(into: cache, layout: layout, speculation: speculation)
                offset = boundary
            }
            self.cache = cache
            let plan = Plan.make(promptCount: prompt.count, start: offset, chunkTokens: chunk, keepAt: boundary,
                bulkTokens: bulk, microBatches: 2, mergedTokens: 0)
            let result = try plan.run(stage: stage, cache: cache, prompt: prompt, speculation: speculation,
                keep: { end, kept, history in
                    memory?.store(scope: "session", prompt: prompt, length: end, cache: kept, mtp: history)
                })
            logits = result.logits; hidden = result.lastHidden
            try fence([logits, hidden] + (try speculation.evaluationTargets()))
        }

        /// Every layer's state (a paged history gathered from a copy, so
        /// nothing of this request changes) and the NextN history.
        func state() -> [MLXArray] { cache.copy().layers.flatMap(\.state) + speculation.state.history }
    }

    /// Captures the memory tier's entry at `boundary` as `persistPrefix`
    /// does, writes it, and reads it back from a new tier on the same
    /// directory (another session) as `restoreAgreedFromEitherTier` does.
    static func throughTheSSD(_ memory: GLM5NextTensorParallelPrefixCache, prompt: [Int], chunk: Int, boundary: Int,
                              layout: Record.Layout) throws -> Record.Restorable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glm-prefix-restore-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = QwenStagePrefixDiskConfiguration(mode: .on(root: root, key: Data(repeating: 0x2c, count: 32)))
        configuration.minimumTokens = 1; configuration.minimumFreeBytes = 1
        let planScope = GLM5NextTensorParallelPrefixDisk.planScope(artifactAggregateSHA256: String(repeating: "a", count: 64),
            inventorySHA256: String(repeating: "b", count: 64),
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)], mtpDepth: 2)
        func open() throws -> GLM5NextTensorParallelPrefixDisk {
            let tier = try #require(QwenStagePrefixDiskTier.open(configuration: configuration, planScope: planScope,
                rank: 0, stagingEpoch: UUID().uuidString.lowercased()))
            return .init(tier: tier, planScope: planScope, layout: layout)
        }
        let entry = try #require(memory.entry(scope: "session", prompt: prompt, length: boundary))
        do {
            let disk = try open()
            let record = try Record.capture(cache: entry.cache, history: entry.mtp, layout: layout, frontier: boundary)
            #expect(record.state.attention.isEmpty && record.rows.count == layout.dsaLayers.count + 1)
            disk.tier.persist(scope: disk.scope(chunk: chunk), tokens: prompt, states: [record.state], blockTokens: chunk,
                attentionRows: record.rows)
            #expect(disk.tier.drain(timeoutSeconds: 60))
            #expect(disk.tier.stats.persisted == 1)
            disk.tier.close()
        }
        let disk = try open()
        #expect(disk.tier.stats.loadedRecords == 1)
        #expect(disk.boundaries(scope: disk.scope(chunk: chunk), prompt: prompt,
            candidates: QwenTensorParallelPrefixCache.candidates(promptCount: prompt.count, chunk: chunk)) == [boundary])
        let restorable = try #require(disk.read(boundary: boundary, prompt: prompt, scope: disk.scope(chunk: chunk),
            stop: { false }))
        disk.tier.close()
        return restorable
    }

    /// The whole check on `stage`: the record holds the entry's bytes, and
    /// the restored request continues exactly as the prefilled one.
    static func check(stage: GLM5NextTextStage, mtp: GLM5NextMTP, pool: GLM5NextDSAPagePool?, prompt: [Int], chunk: Int,
                      bulk: Int, boundary: Int) throws {
        let saved = stage.dsaPagePool
        stage.dsaPagePool = pool
        defer { stage.dsaPagePool = saved }
        let layout = try Record.Layout(stage: stage, mtp: mtp)
        #expect(layout.paged == (pool != nil) && layout.nextNLayer == stage.plan.configuration.hiddenLayers)
        let memory = GLM5NextTensorParallelPrefixCache(budgetBytes: 8 << 30)
        let prefilled = try Request(stage: stage, mtp: mtp, pool: pool, prompt: prompt, chunk: chunk, bulk: bulk,
            boundary: boundary, start: .cold, memory: memory)
        #expect(memory.count == 1)
        let entry = try #require(memory.entry(scope: "session", prompt: prompt, length: boundary))
        let record = try throughTheSSD(memory, prompt: prompt, chunk: chunk, boundary: boundary, layout: layout)

        // Written into a fresh request state, within its page reservation:
        // the entry's bytes, layer by layer.
        let pages = try reserve(pool, stage: stage, tokens: prompt.count + 16)
        let written = stage.newCache(account: pages?.account)
        let history = try GLM5NextTensorParallelSpeculation(mtp: mtp, depth: 2, rank: 0, ranks: 1, primeRows: 64,
            pagePool: pool, pageAccount: pages?.account, agree: { $0 })
        try record.write(into: written, layout: layout, speculation: history)
        if let account = pages?.account {
            #expect(written.heldPages > 0 && account.allocatedPages > 0 && account.allocatedPages <= account.reservedPages)
        }
        let reference = try GLM5NextTensorParallelSpeculation(mtp: mtp, depth: 2, rank: 0, ranks: 1, primeRows: 64,
            pagePool: pool, pageAccount: nil, agree: { $0 })
        try reference.restore(entry.mtp)
        for (index, (a, b)) in zip(written.copy().layers, entry.cache.copy().layers).enumerated() {
            #expect(a.offset == boundary && b.offset == boundary)
            #expect(try same(a.state, b.state), "layer \(index)")
        }
        #expect(try same(history.state.history, reference.state.history), "NextN history")

        // Restored from the SSD and from memory, both continue as the prefilled request.
        let fromDisk = try Request(stage: stage, mtp: mtp, pool: pool, prompt: prompt, chunk: chunk, bulk: bulk,
            boundary: boundary, start: .ssd(record, layout))
        let restored = try #require(memory.restore(scope: "session", prompt: prompt, length: boundary))
        let fromMemory = try Request(stage: stage, mtp: mtp, pool: pool, prompt: prompt, chunk: chunk, bulk: bulk,
            boundary: boundary, start: .memory(restored))
        for (label, request) in [("ssd", fromDisk), ("memory", fromMemory)] {
            #expect(try same([request.logits, request.hidden], [prefilled.logits, prefilled.hidden]), "\(label) prefill")
            #expect(try same(request.state(), prefilled.state()), "\(label) state")
        }
        // A control: another prompt leaves other bits, so the comparisons above compare something.
        let other = try Request(stage: stage, mtp: mtp, pool: pool,
            prompt: prompt.map { ($0 + 1) % stage.plan.configuration.vocabularySize }, chunk: chunk, bulk: bulk,
            boundary: boundary, start: .cold)
        #expect(try !same(other.state(), prefilled.state()) && !prefilled.state().isEmpty)
        let first = Int(argMax(prefilled.logits.asType(.float32), axis: -1).item(Int32.self))
        var rounds: [GLM5NextTensorParallelSpeculation.Round] = []
        for request in [prefilled, fromDisk, fromMemory] {
            try request.speculation.begin(carry: first, lastHidden: request.hidden)
            rounds.append(try request.speculation.round(stage: stage, cache: request.cache, last: first, window: 2, stop: 0))
        }
        #expect(rounds[1] == rounds[0] && rounds[2] == rounds[0], "rounds \(rounds)")
        #expect(try same(fromDisk.state(), prefilled.state()), "ssd state after a round")
    }

    @Test(arguments: [true, false])
    func aPrefilledRankRestoresFromTheSSDExactly(paged: Bool) throws {
        defer {
            do { try MLX.withError { error in Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check() } }
            catch { Issue.record(error, "GLM prefix restore fixture cleanup fence failed") }
        }
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let c = loader.configuration.textConfig
        let stage = try loader.loadTextStage(plan: .init(configuration: c, layers: 0 ..< c.hiddenLayers))
        let mtp = try loader.loadMTP(stage: stage)
        // Pages of four tokens: the boundary ends a page, the frames' ends fall inside them.
        let pool = paged ? try stage.makeDSAPagePool(pageSize: 4) : nil
        try Self.check(stage: stage, mtp: mtp, pool: pool, prompt: (0 ..< 37).map { 4 + ($0 * 7) % 23 }, chunk: 8,
            bulk: 16, boundary: 32)
    }

    /// What the SSD writer reads of a memory entry's pages while its record
    /// is queued: the same rows after the pool's slabs grew (another request
    /// reserved) and after they were trimmed (every request gone), since the
    /// reader holds the entry's pages and takes the slabs at each read. A
    /// capture without the NextN history where the rank speculates, or at
    /// another frontier, is refused.
    @Test func aHeldHistoryReadsTheSameRowsWhileThePoolGrowsAndTrims() throws {
        defer {
            do { try MLX.withError { error in Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check() } }
            catch { Issue.record(error, "GLM prefix restore fixture cleanup fence failed") }
        }
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let c = loader.configuration.textConfig
        let stage = try loader.loadTextStage(plan: .init(configuration: c, layers: 0 ..< c.hiddenLayers))
        let mtp = try loader.loadMTP(stage: stage)
        let pool = try stage.makeDSAPagePool(pageSize: 4)
        stage.dsaPagePool = pool
        defer { stage.dsaPagePool = nil }
        let layout = try Record.Layout(stage: stage, mtp: mtp)
        let prompt = (0 ..< 37).map { 4 + ($0 * 5) % 23 }
        let memory = GLM5NextTensorParallelPrefixCache(budgetBytes: 1 << 30)
        do {
            _ = try Request(stage: stage, mtp: mtp, pool: pool, prompt: prompt, chunk: 8, bulk: 16, boundary: 32,
                start: .cold, memory: memory)
        }
        let entry = try #require(memory.entry(scope: "session", prompt: prompt, length: 32))
        #expect(throws: (any Error).self) {
            try Record.capture(cache: entry.cache, history: nil, layout: layout, frontier: 32)
        }
        #expect(throws: (any Error).self) {
            try Record.capture(cache: entry.cache, history: entry.mtp, layout: layout, frontier: 24)
        }
        let record = try Record.capture(cache: entry.cache, history: entry.mtp, layout: layout, frontier: 32)
        let expected = try entry.cache.copy().layers.filter { $0 is GLM5NextDSACache }.map { layer -> [Data] in
            let state = layer.state
            try Self.fence(state)
            return [Self.bytes(state[0]), Self.bytes(concatenated([state[1], state[2]], axis: -1))]
        }
        func read() throws -> [[Data]] {
            try layout.dsaLayers.map { layer in
                let rows = try #require(record.rows[layer])
                return try [rows.keys, rows.values].map { source in
                    var data = Data(count: 32 * source.width * source.dtype.size)
                    // Two reads, one crossing a page boundary mid-page, as units of other sizes would.
                    try data.withUnsafeMutableBytes { raw in
                        try source.read(0 ..< 18, raw.baseAddress!)
                        try source.read(18 ..< 32, raw.baseAddress!.advanced(by: 18 * source.width * source.dtype.size))
                    }
                    return data
                }
            }
        }
        #expect(try read() == expected)
        let before = pool.capacityPages
        let other = try pool.reserve(pages: before * 3)
        #expect(pool.capacityPages > before)
        #expect(try read() == expected, "after the slabs grew")
        pool.release(other)
        #expect(try pool.trim() > 0)
        #expect(try read() == expected, "after the slabs were trimmed")
    }

    @Test(.enabled(if: servingEnabled))
    func aServingStageRestoresFromTheSSDExactly() throws {
        try Device.withDefaultDevice(.gpu) {
            let (stage, mtp) = try GLM5NextTensorParallelPagedKVTests.model()
            let text = stage.plan.configuration
            let pool = try stage.makeDSAPagePool(pageSize: GLM5NextTensorParallelResidentRuntime.dsaPageTokens)
            let prompt = (0 ..< 1_500).map { ($0 * 104_729 + 17) % text.vocabularySize }
            try Self.check(stage: stage, mtp: mtp, pool: pool, prompt: prompt, chunk: 600, bulk: 1_200, boundary: 1_200)
            try Self.check(stage: stage, mtp: mtp, pool: nil, prompt: prompt, chunk: 600, bulk: 1_200, boundary: 1_200)
        }
    }
}
