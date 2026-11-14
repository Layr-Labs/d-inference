// Copyright © 2026 Eigen Labs.
// Turn continuation on a bridge whose engine keeps its prefixes in the
// encrypted complete-checkpoint store. The hidden request's restore and its
// checkpoint write are device transfers on the budget its session idles on;
// they must not end the session that makes them. A hidden request that would
// compute its turn's own prompt again is refused before it reaches the engine.

import Foundation
import MLX
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

@Suite("Turn continuation on the complete-checkpoint store", .serialized)
struct TurnContinuationStoreBridgeTests {
    private struct Reply {
        var completionTokens: Int?
        var failed = false
    }

    private static func run(
        _ bridge: EngineV2Bridge, _ id: String, prompt: [Int], cacheReady: CancelledPrefixBarrier? = nil
    ) async -> Reply {
        let stream = await bridge.submitTokenized(
            promptTokens: prompt,
            request: ChatCompletionRequest(
                model: "fixture-model", messages: [], temperature: 0, max_tokens: 1),
            requestId: id, cacheScope: "tenant-a",
            usageSignal: EngineV2RequestUsageSignal(onCacheReady: { _ in cacheReady?.signal() }))
        var reply = Reply()
        for await event in stream {
            switch event {
            case .logprobs, .chunk: break
            case .info(_, let completion, _, _): reply.completionTokens = completion
            case .error, .terminal: reply.failed = true
            }
        }
        return reply
    }

    /// A bridge that feeds only the durable tier, which keeps multiples of 256
    /// below a prompt's last token.
    private static func makeBridge(
        _ fixture: SSDHybridCheckpointTestFixture, store: SSDHybridCheckpointStore
    ) throws -> EngineV2Bridge {
        let model = CancelledPrefixModel()
        let tokenizer = CancelledPrefixTokenizer(prompt: fixture.tokens)
        let backend = try PagedKVBackend(layerKinds: model.kinds, config: .init(
            capacityBytes: 128 << 20, dtype: .float32, maxPrefillChunk: 256,
            segmentSizeBytes: 64 << 10, layerDTypes: [.float32]))
        let engine = EngineV2(
            model: model, layerKinds: model.kinds, backend: backend,
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
            schedulerConfig: .init(
                maxConcurrentRequests: 1, maxBatchedTokensPerStep: 256,
                prefillChunkSize: 256, maxWaiting: 4, enablePrefixCache: true),
            completePrefixCache: store)
        return EngineV2Bridge(
            engine: engine, modelId: "fixture-model", tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], prefillDeadlineMode: .off, kvBudget: fixture.budget,
            ssdHybridCheckpointStore: store, kvBackendKind: .paged,
            calibrationPosturePermitsWork: { true },
            turnContinuationCells: TurnContinuationCells(
                gridTokens: 256, boundaryRule: nil, residentBank: false),
            emitTelemetry: { _ in })
    }

    /// Polls for up to five seconds.
    private static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("a continuation outlives its own store transfers and the follow-up restores what it wrote")
    func theContinuationOutlivesItsOwnStoreTransfers() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true, tokenCount: 1_025)
        defer { fixture.remove() }
        // The store reports its device transfers to the budget the bridge idles on.
        let donations = DonationOutcomes()
        let store = try fixture.makeStore(donationRecorder: donations)
        let bridge = try Self.makeBridge(fixture, store: store)
        let budget = fixture.budget.serviceBudget
        let source = Array(fixture.tokens.prefix(513))
        let shared = Array(fixture.tokens.prefix(900))
        let next = Array(fixture.tokens.prefix(1_000))
        func exists(_ position: Int) -> Bool {
            FileManager.default.fileExists(atPath: fixture.file(store, position: position).path)
        }

        do {
            let ready = CancelledPrefixBarrier()
            let first = await Self.run(bridge, "turn-1", prompt: source, cacheReady: ready)
            try #require(!first.failed && first.completionTokens == 1, "\(first)")
            #expect(await ready.wait(), "\(donations.all) \(store.stats())")
            try #require(exists(512) && !exists(768), "\(donations.all) \(store.stats())")
            try #require(await Self.eventually { budget.isIdle })
            let before = store.stats()
            let admits = await bridge._testCounters().admits

            // The next turn is known to start with 900 tokens. The first turn
            // left 512; the store can keep 768.
            await bridge.continueTurn(after: "turn-1", source: source, shared: shared, cacheScope: "tenant-a")
            await bridge.awaitStoreTurnContinuationTest()
            // One hidden request ran, and neither its restore nor its
            // checkpoint write was the end of it.
            #expect(await bridge._testCounters().admits == admits + 1)
            #expect(budget.idleCalibration.cancellationSource == nil)
            #expect(await Self.eventually { exists(768) })
            let continued = store.stats()
            #expect(continued.consumedPrefixTokens - before.consumedPrefixTokens == 512, "\(continued)")
            #expect(continued.filesWritten > before.filesWritten, "\(continued)")

            // The follow-up restores the position the hidden request wrote.
            try #require(await Self.eventually { budget.isIdle })
            let followed = await Self.run(bridge, "turn-2", prompt: next)
            #expect(!followed.failed && followed.completionTokens == 1, "\(followed)")
            let after = store.stats()
            #expect(after.consumedPrefixTokens - continued.consumedPrefixTokens == 768, "\(after)")
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
    }

    @Test("a continuation is refused while the store holds nothing of its turn, and runs once it does")
    func aContinuationIsRefusedWhileTheStoreHoldsNothingOfItsTurn() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true, tokenCount: 1_025)
        defer { fixture.remove() }
        let donations = DonationOutcomes()
        let store = try fixture.makeStore(donationRecorder: donations)
        let bridge = try Self.makeBridge(fixture, store: store)
        let budget = fixture.budget.serviceBudget
        let source = Array(fixture.tokens.prefix(513))
        let shared = Array(fixture.tokens.prefix(900))
        func exists(_ position: Int) -> Bool {
            FileManager.default.fileExists(atPath: fixture.file(store, position: position).path)
        }

        do {
            // A turn whose own request wrote nothing: the store is empty. The
            // plan asks for position 512; a hidden request that ran would
            // prefill all 769 tokens and write them.
            await bridge.continueTurn(after: "turn-0", source: source, shared: shared, cacheScope: "tenant-a")
            await bridge.awaitStoreTurnContinuationTest()
            #expect(await bridge._testCounters().admits == 0)
            #expect(budget.idleCalibration.cancellationSource == nil)
            let refused = store.stats()
            #expect(refused.filesWritten == 0 && refused.consumedPrefixTokens == 0, "\(refused)")
            #expect(!exists(256) && !exists(512) && !exists(768))

            // The slot serves the turn as if nothing had been tried.
            try #require(await Self.eventually { budget.isIdle })
            let ready = CancelledPrefixBarrier()
            let first = await Self.run(bridge, "turn-1", prompt: source, cacheReady: ready)
            try #require(!first.failed && first.completionTokens == 1, "\(first)")
            #expect(await ready.wait(), "\(donations.all) \(store.stats())")
            try #require(exists(512) && !exists(768), "\(donations.all) \(store.stats())")
            try #require(await Self.eventually { budget.isIdle })
            let admits = await bridge._testCounters().admits

            // Now the store holds position 512, and the same continuation runs.
            await bridge.continueTurn(after: "turn-1", source: source, shared: shared, cacheScope: "tenant-a")
            await bridge.awaitStoreTurnContinuationTest()
            #expect(await bridge._testCounters().admits == admits + 1)
            #expect(await Self.eventually { exists(768) })
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
    }

    @Test("a continuation is refused when the store restores less than its turn's last position")
    func aContinuationIsRefusedBelowItsTurnsLastPosition() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true, tokenCount: 1_025)
        defer { fixture.remove() }
        let donations = DonationOutcomes()
        let store = try fixture.makeStore(donationRecorder: donations)
        let bridge = try Self.makeBridge(fixture, store: store)
        let budget = fixture.budget.serviceBudget
        func exists(_ position: Int) -> Bool {
            FileManager.default.fileExists(atPath: fixture.file(store, position: position).path)
        }

        do {
            let ready = CancelledPrefixBarrier()
            let first = await Self.run(bridge, "turn-1", prompt: Array(fixture.tokens.prefix(513)), cacheReady: ready)
            try #require(!first.failed && first.completionTokens == 1, "\(first)")
            #expect(await ready.wait(), "\(donations.all) \(store.stats())")
            try #require(exists(512) && !exists(768), "\(donations.all) \(store.stats())")
            try #require(await Self.eventually { budget.isIdle })
            let before = store.stats()
            let admits = await bridge._testCounters().admits

            // A 769-token turn should have left position 768, but the store
            // holds only an older checkpoint at 512, as it does after a write
            // it declined. The plan asks for 768; the store restores 512.
            let source = Array(fixture.tokens.prefix(769))
            await bridge.continueTurn(after: "turn-2", source: source, shared: fixture.tokens, cacheScope: "tenant-a")
            await bridge.awaitStoreTurnContinuationTest()
            #expect(await bridge._testCounters().admits == admits)
            #expect(budget.idleCalibration.cancellationSource == nil)
            // The checkpoint that was read is given back, not consumed.
            let refused = store.stats()
            #expect(refused.consumedPrefixTokens == before.consumedPrefixTokens, "\(refused)")
            #expect(!exists(768) && !exists(1_024))

            // The next request still restores the checkpoint that is there.
            try #require(await Self.eventually { budget.isIdle })
            let followed = await Self.run(bridge, "turn-3", prompt: Array(fixture.tokens.prefix(1_000)))
            #expect(!followed.failed && followed.completionTokens == 1, "\(followed)")
            let after = store.stats()
            #expect(after.consumedPrefixTokens - refused.consumedPrefixTokens == 512, "\(after)")
        } catch {
            await bridge.shutdown()
            throw error
        }
        await bridge.shutdown()
    }
}

/// What the store did with each offered checkpoint, for a failure's message.
private final class DonationOutcomes: PrefixCacheDonationRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [PrefixCacheDonationOutcome] = []
    func record(_ outcome: PrefixCacheDonationOutcome) { lock.withLock { outcomes.append(outcome) } }
    var all: [PrefixCacheDonationOutcome] { lock.withLock { outcomes } }
}

private extension EngineV2Bridge {
    func awaitStoreTurnContinuationTest() async { await modelCalibration.task?.value }
}
