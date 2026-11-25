import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Parallel complete-checkpoint stage", .serialized)
struct SSDParallelStageTests {
    struct Streamed: Equatable {
        var calls: [[Int]] = []
        var tensors: [Data] = []
        var bytesRead = 0
    }

    final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        let limit: Int
        init(limit: Int = .max) { self.limit = limit }
        var bytes: Int { lock.withLock { total } }
        func add(_ count: Int) { lock.withLock { total += count } }
        func charge(_ count: Int) throws {
            try lock.withLock {
                total += max(0, count)
                if total > limit { throw SSDCheckpointReadBudget.Exhausted.bytes }
            }
        }
    }

    struct Stop: Error {}

    static func candidate(_ f: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore,
                          position: Int) throws -> SSDHybridCheckpointStore.ReadCandidate {
        let tag = store.lookupKeys.checkpointTag(
            chainHash: store.hashes(tokens: f.tokens, scope: "tenant-a")[position / 256 - 1], cacheSalt: "tenant-a")
        let chain = try #require(store.index.chain(tag16: Data(tag.prefix(16)))?.tags)
        return .init(position: position, tag: tag, chain: chain, fileBytes: 0)
    }

    /// Streams `position` as a stage does; `stopAfter` appends make the importer fail.
    static func stream(_ f: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore, position: Int,
                       readLimit: Int = .max, stopAfter: Int = .max, cancelAfter: Int = .max) throws -> Streamed {
        let candidate = try candidate(f, store, position: position)
        let meter = Meter(limit: readLimit), read = Meter()
        var files = try store.openChain(candidate, promptTokens: f.tokens, tracksIdentity: true, check: {},
                                        beforeRead: meter.charge,
                                        countRead: read.add, blame: { _ in })
        var out = Streamed(tensors: files[0].link.manifest.tensors.map { _ in Data() })
        var checks = 0
        let check = {
            checks += 1
            if checks > cancelAfter { throw CancellationError() }
        }
        _ = try store.streamChain(&files, parallel: store.config.parallelStage, check: check, blame: { _ in }) { tensor, offset, data in
            guard out.calls.count < stopAfter else { throw Stop() }
            out.calls.append([tensor, offset, data.count])
            out.tensors[tensor].append(data)
        }
        out.bytesRead = read.bytes
        return out
    }

    /// Writes complete files at 256 and 2304 and an eight-file delta chain to 2048.
    static func populate(_ f: SSDHybridCheckpointTestFixture) async throws {
        let store = try f.makeStore(incrementalCheckpoints: true, parallelStage: false)
        try await SSDCheckpointDeltaTests.turn(f, store, id: 1, restores: nil, donates: 256)
        for position in stride(from: 512, through: 2048, by: 256) {
            try await SSDCheckpointDeltaTests.turn(f, store, id: position, restores: position - 256, donates: position)
        }
        try await SSDCheckpointDeltaTests.turn(f, store, id: 2, restores: 2048, donates: 2304, consume: false)
        #expect(store.stats().deltaFilesWritten == 7)
        await store.closeAndWait()
    }

    @Test("both stages hand the importer the same bytes in the same calls and read the same chunks",
          arguments: [true, false])
    func sameBytes(paged: Bool) async throws {
        let f = try SSDHybridCheckpointTestFixture(paged: paged, tokenCount: 2305)
        defer { f.remove() }
        try await Self.populate(f)
        let sequential = try f.makeStore(incrementalCheckpoints: true, parallelStage: false)
        let parallel = try f.makeStore(incrementalCheckpoints: true, parallelStage: true)
        for (position, files) in [(256, 1), (1024, 4), (2048, 8), (2304, 1)] {
            #expect(try Self.candidate(f, parallel, position: position).chain.count == files)
            let expected = try Self.stream(f, sequential, position: position)
            #expect(try Self.stream(f, parallel, position: position) == expected, "\(position)")
            let source = try SSDCheckpointDeltaTests.source(f, position)
            for (index, tensor) in source.manifest.tensors.enumerated() {
                #expect(expected.tensors[index] == (try source.readSegment(
                    tensorIndex: index, byteOffset: 0, maximumBytes: tensor.byteCount)))
            }
            source.close()
        }
        for store in [sequential, parallel] {
            #expect(await store.stage(requestID: .init(9), request: f.request(), reserveReadScratch: f.reserveReadScratch,
                                      makeImportPlan: f.plan).disposition
                == .staged(matchedTokens: 2304, expectedPrefillTokensSaved: 2304, shortenedByCorruption: false))
            store.completeStaging(requestID: .init(9))
            await store.closeAndWait()
        }
        #expect(await f.budget.outstandingReservedBytes() == 0)
    }

    @Test("a corrupt chunk, an exhausted read budget or a failing importer fail the same way")
    func failures() async throws {
        let f = try SSDHybridCheckpointTestFixture(paged: true, tokenCount: 2305)
        defer { f.remove() }
        try await Self.populate(f)
        let stores = [false, true].map { try! f.makeStore(incrementalCheckpoints: true, parallelStage: $0) }
        func outcome(_ store: SSDHybridCheckpointStore, readLimit: Int = .max, stopAfter: Int = .max,
                     cancelAfter: Int = .max) -> String {
            do {
                let streamed = try Self.stream(f, store, position: 2048, readLimit: readLimit, stopAfter: stopAfter,
                                               cancelAfter: cancelAfter)
                return "ok \(streamed.calls.count)"
            } catch { return "\(error)" }
        }
        let full = try Self.stream(f, stores[0], position: 2048)
        for limit in [0, 4096, full.bytesRead / 2, full.bytesRead - 1] {
            let sequential = outcome(stores[0], readLimit: limit)
            #expect(sequential.contains("bytes"), "\(limit)")
            #expect(outcome(stores[1], readLimit: limit) == sequential, "\(limit)")
        }
        for stop in [0, 1, full.calls.count / 2, full.calls.count - 1] {
            #expect(outcome(stores[0], stopAfter: stop) == "\(Stop())")
            #expect(outcome(stores[1], stopAfter: stop) == "\(Stop())")
        }
        // A cancel seen by `check` stops both stages at the same chunk, with opens still queued.
        for cancel in [0, 1, 3, full.calls.count / 2] {
            #expect(outcome(stores[0], cancelAfter: cancel) == "\(CancellationError())")
            #expect(outcome(stores[1], cancelAfter: cancel) == "\(CancellationError())")
        }
        // Every stop above released its files: the chain still streams.
        #expect(try Self.stream(f, stores[1], position: 2048) == full)

        // Flip the keys tag of a middle file: every restore through it takes those rows.
        let file = f.file(stores[0], position: 1024)
        let sizes = try SSDBlockStore.readHeaderOnly(from: file).metadata.chunkPlaintextSizes
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - sizes.suffix(3).reduce(0) { $0 + 4 + $1 + 16 } - 1] ^= 1
        try bytes.write(to: file)
        let sequential = outcome(stores[0])
        #expect(sequential.contains("authenticat"), "\(sequential)")
        #expect(outcome(stores[1]) == sequential)
        // A prompt whose deepest checkpoint is the chain's leaf at 2048.
        var request = f.request()
        request.promptTokens = Array(f.tokens.prefix(2049))
        for store in stores {
            // The previous store removed the file that failed.
            try bytes.write(to: file)
            #expect(await store.stage(requestID: .init(9), request: request, reserveReadScratch: f.reserveReadScratch,
                                      makeImportPlan: f.plan).disposition == .missCorrupt)
            store.completeStaging(requestID: .init(9))
            await store.closeAndWait()
        }
        #expect(await f.budget.outstandingReservedBytes() == 0)
    }

    /// `scratchFits`: the read-ahead's scratch is reserved but its destination peak is not.
    @Test("a budget without room for the read-ahead stages sequentially instead of refusing",
          arguments: [false, true])
    func tightBudget(scratchFits: Bool) async throws {
        let probe = try SSDHybridCheckpointTestFixture(paged: true, tokenCount: 2305)
        let plan = try probe.plan(probe.manifest(position: 2304))
        let sequentialPeak = SSDHybridCheckpointStore.ioScratchBytes(files: 1, parallel: false)
            + plan.nativeDestinationBytes + plan.scratchBytes
        probe.remove()
        let parallelScratch = SSDHybridCheckpointStore.ioScratchBytes(files: 1, parallel: true)
        let parallelPeak = sequentialPeak + parallelScratch - SSDHybridCheckpointStore.ioScratchBytes(files: 1, parallel: false)
        // The ledger keeps 2 GiB back; neither room holds the parallel peak.
        let room = UInt64(scratchFits ? parallelScratch + (1 << 20)
                                      : sequentialPeak + CBv2CompleteCheckpointManifest.maximumSegmentBytes)
        try #require(room >= UInt64(sequentialPeak) && room < UInt64(parallelPeak))
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: (2 << 30) + room, active: 0, cache: 0, systemAvailable: .max) })
        #expect(budget.processLedger.snapshot().remainingBytes == room)
        let f = try SSDHybridCheckpointTestFixture(paged: true, budget: budget, tokenCount: 2305)
        defer { f.remove() }
        let store = try f.makeStore(incrementalCheckpoints: true, parallelStage: true)
        try await SSDCheckpointDeltaTests.turn(f, store, id: 1, restores: nil, donates: 2304)
        let result = await store.stage(requestID: .init(9), request: f.request(), reserveReadScratch: f.reserveReadScratch,
                                       makeImportPlan: f.plan)
        #expect(result.disposition == .staged(matchedTokens: 2304, expectedPrefillTokensSaved: 2304,
                                              shortenedByCorruption: false))
        #expect(store.stats().peakStagingReservationBytes == (scratchFits ? parallelScratch : sequentialPeak))
        store.completeStaging(requestID: .init(9))
        await store.closeAndWait()
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("a prefetcher returns the cursor's chunks in order at any depth and stops early on cancel")
    func prefetcher() async throws {
        let f = try SSDHybridCheckpointTestFixture(paged: true, tokenCount: 2305)
        defer { f.remove() }
        try await Self.populate(f)
        let store = try f.makeStore(incrementalCheckpoints: true, parallelStage: false)
        defer { store.close() }
        let candidate = try Self.candidate(f, store, position: 2304)
        func open() throws -> SSDHybridCheckpointStore.ChainFile {
            try store.openChain(candidate, promptTokens: f.tokens, tracksIdentity: true, check: {},
                                beforeRead: { _ in }, countRead: { _ in },
                                blame: { _ in })[0]
        }
        let reference = try open()
        var chunks: [Data] = []
        while let chunk = try reference.cursor.next() { chunks.append(chunk) }
        #expect(chunks.count >= 3)
        let skips = chunks.indices.map { $0 % 2 == 1 }
        for depth in [1, 2, 4, 16] {
            let file = try open()
            let plan = chunks.indices.map { SSDChunkPrefetcher.Planned(index: $0 + 1, skip: skips[$0]) }
            let prefetcher = SSDChunkPrefetcher(cursor: file.cursor, plan: plan, depth: depth)
            for (index, chunk) in chunks.enumerated() {
                #expect(try prefetcher.next(expectingIndex: index + 1, skip: skips[index]) == (skips[index] ? Data() : chunk))
            }
            prefetcher.finish()
            #expect(try file.cursor.finish(requireEOF: true) != nil)

            let early = try open()
            let stopped = SSDChunkPrefetcher(cursor: early.cursor, plan: plan, depth: depth)
            #expect(try stopped.next(expectingIndex: 1, skip: skips[0]) == chunks[0])
            #expect(throws: (any Error).self) { try stopped.next(expectingIndex: 3, skip: false) }
            stopped.cancel()
            #expect(early.cursor.nextIndex <= 1 + depth + 1)
        }
    }

    @Test("chunk plans follow the consumer's take and skip decisions and stop where it would fail")
    func plans() {
        typealias P = SSDChunkPrefetcher.Planned
        let steps: [[(file: Int, bytes: Int, take: Bool)]] = [
            [(0, 3, true), (1, 4, false)], [(0, 5, false), (1, 6, true)], [(0, 3, true), (1, 1, false)],
        ]
        let plans = SSDHybridCheckpointStore.chunkPlans(steps: steps, chunkSizes: [[9, 4, 4, 4], [9, 4, 4, 4]],
                                                        firstIndices: [1, 1])
        #expect(plans[0] == [P(index: 1, skip: false), P(index: 2, skip: true), P(index: 3, skip: false)])
        #expect(plans[1] == [P(index: 1, skip: true), P(index: 2, skip: false), P(index: 3, skip: false)])
        let short = SSDHybridCheckpointStore.chunkPlans(steps: [[(0, 4, true), (0, 9, true), (0, 1, true)]],
                                                        chunkSizes: [[9, 4, 4]], firstIndices: [1])
        #expect(short == [[P(index: 1, skip: false), P(index: 2, skip: false)]])
        #expect(SSDHybridCheckpointStore.chunkPlans(steps: [[(0, 0, true)]], chunkSizes: [[9]], firstIndices: [1]) == [[]])
        // A drop shorter than the next chunk reads it: the rest of it is taken.
        let partial = SSDHybridCheckpointStore.chunkPlans(steps: [[(0, 2, false), (0, 2, true), (0, 4, false)]],
                                                          chunkSizes: [[9, 4, 4]], firstIndices: [1])
        #expect(partial == [[P(index: 1, skip: false), P(index: 2, skip: true)]])
        // Empty chunks are planned like any other: skipped on a drop, read on a take.
        let empty = SSDHybridCheckpointStore.chunkPlans(steps: [[(0, 3, false), (0, 3, true), (0, 3, true)]],
                                                        chunkSizes: [[9, 0, 3, 0, 3, 3]], firstIndices: [1])
        #expect(empty == [[P(index: 1, skip: true), P(index: 2, skip: true), P(index: 3, skip: false),
                           P(index: 4, skip: false), P(index: 5, skip: false)]])
    }

    @Test("the read-ahead is charged as stage scratch")
    func scratch() {
        let segment = CBv2CompleteCheckpointManifest.maximumSegmentBytes
        let base = SSDHybridCheckpointStore.ioScratchBytes
        #expect(SSDHybridCheckpointStore.ioScratchBytes(files: 1, parallel: false) == base)
        #expect(SSDHybridCheckpointStore.ioScratchBytes(files: 3, parallel: false) == base + 2 * segment)
        #expect(SSDHybridCheckpointStore.ioScratchBytes(files: 3, parallel: true)
            == base + (2 + 3 * SSDHybridCheckpointStore.parallelStageDepth * 3) * segment)
    }

    @Test("on by default; the rollback reaches the provider job")
    func rollbackIsForwarded() {
        let key = SSDPrefixCachePolicy.parallelStageFlag
        #expect(key == "DARKBLOOM_PREFIX_CACHE_PARALLEL_STAGE")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        for (value, on) in [(nil, true), ("", true), ("1", true), ("typo", true), ("0", false), (" OFF ", false),
                            ("false", false), ("no", false)] as [(String?, Bool)] {
            var environment: [String: String] = [:]
            environment[key] = value
            #expect(SSDPrefixCachePolicy.parallelStage(environment: environment) == on, "\(String(describing: value))")
            let forwarded = LaunchAgent.passthroughEnvironment(from: environment)
            #expect(SSDPrefixCachePolicy.parallelStage(environment: forwarded) == on)
        }
    }
}
