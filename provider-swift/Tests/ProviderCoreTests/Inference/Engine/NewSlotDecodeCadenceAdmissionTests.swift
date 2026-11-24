import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// A slot without a completed decode sample prices a deadline request beside a
/// decoding row from the cadence of the requests decoding on it now. The real
/// engine projects the queue: one row is frozen mid-decode, so the new prompt's
/// steps carry decode work. The bridge's decoding rows are set directly.
@Suite("New-slot decode cadence admission", .serialized)
struct NewSlotDecodeCadenceAdmissionTests {
    private struct Fixture {
        let engine: EngineV2
        let bridge: EngineV2Bridge
        let decoder: AsyncStream<CBv2Event>

        func release() async {
            await bridge.removeDecodingRowsForTesting()
            engine.loopForTesting.onEngineQueueSync {
                engine.loopForTesting.suspendStepExecutionAtCountForTesting = nil
            }
            for await _ in decoder {}
            await bridge.shutdown()
        }
    }

    /// One request has prefilled and decoded once; the loop then stops before
    /// its next step. Prefill is priced at 1,000 tok/s; there is no decode sample.
    private func makeFixture(admissionFixes: Bool = true) async throws -> Fixture {
        let model = DeadlineAdmissionFixtureModel()
        let engine = EngineV2(model: model, layerKinds: model.kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 20)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds),
            sampler: CBv2GreedySampler(), schedulerConfig: .init(
                maxConcurrentRequests: 2, maxBatchedTokensPerStep: 64,
                prefillChunkSize: 32, maxConcurrentPartialPrefills: 1,
                maxWaiting: 4, enablePrefixCache: false))
        engine.loopForTesting.onEngineQueueSync {
            engine.loopForTesting.suspendStepExecutionAtCountForTesting = 2
        }
        let decoder = try engine.submit(.init(id: .init(910_001), promptTokens: [1], maxTokens: 64))
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while engine.stepCount < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(engine.stepCount == 2)
        let bridge = EngineV2Bridge(engine: engine, modelId: "new-slot-fixture",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [],
            prefillDeadlineMode: .enforce, admissionFixes: admissionFixes)
        await bridge.updatePrefillTpsEwma(1_000, isolated: true)
        #expect(await bridge.ewmaInitialized == false)
        return Fixture(engine: engine, bridge: bridge, decoder: decoder)
    }

    private func submit(_ fixture: Fixture, id: UInt64, budgetMilliseconds: Int64) async throws
        -> (CBv2FirstTokenDeadlineAdmission, CBv2FirstTokenDeadlineResult)
    {
        let policy = try #require(await fixture.bridge.firstTokenDeadlineAdmission(
            deadline: .init(relativeBudgetMilliseconds: budgetMilliseconds),
            isMultimodal: false))
        let result = try await fixture.engine.submit(
            .init(id: .init(id), promptTokens: Array(repeating: 2, count: 100), maxTokens: 1),
            firstTokenDeadline: policy)
        return (policy, result)
    }

    @Test("a new slot admits a deadline request beside a decoding row at that row's cadence")
    func admitsAtLiveCadence() async throws {
        let fixture = try await makeFixture()
        // 20 tokens after the first in one second: 20 tok/s.
        await fixture.bridge.addDecodingRowForTesting("decoding", tokensAfterFirst: 20, since: .seconds(1))
        let (policy, result) = try await submit(fixture, id: 910_002, budgetMilliseconds: 10_000)
        let rate = try #require(policy.conservativeDecodeTokensPerSecond)
        #expect(rate > 19 && rate <= 20)
        #expect(policy.decodeRateShape == nil, "a live cadence is charged per row")
        guard case .admitted(let stream, .bounded(let work, _), _, _) = result else {
            Issue.record("expected a priced admission, got \(result)")
            await fixture.release()
            return
        }
        #expect(work.decodeTokens > 0, "the projection carries the decoding row's work")
        await fixture.release()
        for await _ in stream {}
    }

    @Test("a new slot whose decoding rows' cadence predicts a miss refuses with a priced projection")
    func refusesWhenCadencePredictsMiss() async throws {
        let fixture = try await makeFixture()
        // The slower row prices admission: 1 tok/s, not 100.
        await fixture.bridge.addDecodingRowForTesting("fast", tokensAfterFirst: 100, since: .seconds(1))
        await fixture.bridge.addDecodingRowForTesting("slow", tokensAfterFirst: 9, since: .seconds(9))
        let (policy, result) = try await submit(fixture, id: 910_003, budgetMilliseconds: 1_000)
        let rate = try #require(policy.conservativeDecodeTokensPerSecond)
        #expect(rate > 0.9 && rate <= 1)
        guard case .deadlineUnreachable(.bounded(let work, let duration)) = result else {
            Issue.record("expected deadline_unreachable from a priced projection, got \(result)")
            await fixture.release()
            return
        }
        #expect(work.decodeTokens > 0)
        #expect(duration > .seconds(1))
        await fixture.release()
    }

    @Test("with no row past 8 tokens after its first the decode rate stays unavailable")
    func noRowPastMinimumStaysUnavailable() async throws {
        let fixture = try await makeFixture()
        await fixture.bridge.addDecodingRowForTesting("young", tokensAfterFirst: 7, since: .seconds(1))
        let (policy, result) = try await submit(fixture, id: 910_004, budgetMilliseconds: 10_000)
        #expect(policy.conservativeDecodeTokensPerSecond == nil)
        guard case .deadlineUnreachable(.unbounded(reason: .decodeRateUnavailable)) = result else {
            Issue.record("expected decode_rate_unavailable, got \(result)")
            await fixture.release()
            return
        }
        await fixture.release()
    }

    @Test("with the admission fixes off a new slot's decode rate stays unavailable beside a decoding row")
    func fixesOffStaysUnavailable() async throws {
        let fixture = try await makeFixture(admissionFixes: false)
        await fixture.bridge.addDecodingRowForTesting("decoding", tokensAfterFirst: 20, since: .seconds(1))
        let (policy, result) = try await submit(fixture, id: 910_005, budgetMilliseconds: 10_000)
        #expect(policy.conservativeDecodeTokensPerSecond == nil)
        #expect(policy.decodeRateShape == nil)
        guard case .deadlineUnreachable(.unbounded(reason: .decodeRateUnavailable)) = result else {
            Issue.record("expected decode_rate_unavailable, got \(result)")
            await fixture.release()
            return
        }
        await fixture.release()
    }
}

private extension EngineV2Bridge {
    func addDecodingRowForTesting(_ id: String, tokensAfterFirst: Int, since: Duration) {
        let firstTokenAt = ContinuousClock.now - since
        active[Self.decodingRowPrefix + id] = ActiveRequestState(promptTokens: 1, maxTokens: 1_024,
            completionTokens: tokensAfterFirst + 1, submittedAt: firstTokenAt,
            firstTokenAt: firstTokenAt, firstEmissionTokens: 1)
    }

    static var decodingRowPrefix: String { "live-row-" }

    func removeDecodingRowsForTesting() {
        for id in active.keys where id.hasPrefix(Self.decodingRowPrefix) { active.removeValue(forKey: id) }
    }
}
