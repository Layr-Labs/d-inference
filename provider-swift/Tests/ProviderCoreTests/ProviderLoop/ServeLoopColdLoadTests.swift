// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

/// A request waiting for its model load releases the coordinator work FIFO:
/// a warm model's request is served meanwhile, while a cancel for the waiting
/// request still takes effect exactly where the serial FIFO applied it.
@Suite("Serve loop cold-load admission")
struct ServeLoopColdLoadTests {
    static let coldModel = "cold-load-fixture"

    @Test("a warm model's request is served while another request waits for its model load")
    func warmRequestOvertakesLoadWait() async throws {
        let fixture = try await ServeLoopFixture.make(models: [ModelLoadingFixtures.model(Self.coldModel)])
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        await fixture.loop.modelLoadingMarkLoading(Self.coldModel)

        try await fixture.pushChatRequest(requestId: "cold", body: Self.body(model: Self.coldModel))
        try await Self.until { await fixture.loop.modelLoadingLoadingWaiterCount(Self.coldModel) == 1 }
        try await fixture.pushChatRequest(requestId: "warm")
        try await fixture.awaitSubmissions(1)
        fixture.completeSubmission(0)
        let warm = try await fixture.mock.waitForSnapshot(timeout: .seconds(15)) {
            ServeLoopFixture.terminalCount($0, requestId: "warm") > 0
        }
        #expect(try #require(warm).inferenceComplete.contains { $0.requestId == "warm" })
        #expect(await fixture.loop.releasedAdmissionCountForTesting() == 1)

        // The failed load ends the waiting request with its one terminal.
        await fixture.loop.modelLoadingResumeLoadingWaiters(Self.coldModel, failure: "scripted")
        let cold = try await fixture.mock.waitForSnapshot(timeout: .seconds(15)) {
            ServeLoopFixture.terminalCount($0, requestId: "cold") > 0
        }
        #expect(ServeLoopFixture.terminalCount(try #require(cold), requestId: "cold") == 1)
        try await Self.until { await fixture.loop.releasedAdmissionCountForTesting() == 0 }
        #expect(await fixture.stop(task))
    }

    @Test("a cancel for a request waiting on its load applies once the admission returns")
    func cancelDuringLoadWaitAppliesAfterAdmission() async throws {
        let fixture = try await ServeLoopFixture.make(models: [ModelLoadingFixtures.model(Self.coldModel)])
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        await fixture.loop.modelLoadingMarkLoading(Self.coldModel)

        try await fixture.pushChatRequest(requestId: "cold", body: Self.body(model: Self.coldModel))
        try await Self.until { await fixture.loop.modelLoadingLoadingWaiterCount(Self.coldModel) == 1 }
        try await fixture.mock.pushCancel(requestId: "cold")
        // An event behind the cancel proves the FIFO already passed it.
        try await fixture.pushChatRequest(requestId: "warm")
        try await fixture.awaitSubmissions(1)
        #expect(await fixture.loop.modelLoadingLoadingWaiterCount(Self.coldModel) == 1)

        // The load completes: the request is admitted, then cancelled, as when
        // the FIFO held the cancel behind the load.
        let engine = PrefillScriptEngine()
        let tokenizer = CancelledPrefixTokenizer(prompt: [1, 2, 3])
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        }
        let bridge = EngineV2Bridge(
            engine: engine, modelId: Self.coldModel, tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [], kvBytesPerToken: 4_000, kvBudget: budget)
        await fixture.runtime.register(modelId: Self.coldModel, bridge: bridge)
        await fixture.loop.installModelSlotForTesting(
            modelId: Self.coldModel, container: cancelledPrefixContainer(tokenizer: tokenizer),
            tokenizer: TokenizerHandle(tokenizer), engineV2: bridge,
            sizing: .init(weightsBytes: 0, fp16KVBytesPerToken: 4_000, maxContextLength: 8192, defaultMaxTokens: 4096))
        await fixture.loop.modelLoadingClearLoading(Self.coldModel)
        await fixture.loop.modelLoadingResumeLoadingWaiters(Self.coldModel)

        let cold = try await fixture.mock.waitForSnapshot(timeout: .seconds(15)) {
            ServeLoopFixture.terminalCount($0, requestId: "cold") > 0
        }
        let snapshot = try #require(cold)
        #expect(ServeLoopFixture.terminalCount(snapshot, requestId: "cold") == 1)
        #expect(snapshot.inferenceErrors.first { $0.requestId == "cold" }?.failureCode == .cancelled)
        try await Self.until { await fixture.loop.releasedAdmissionCountForTesting() == 0 }

        fixture.completeSubmission(0)
        await bridge.shutdown()
        _ = await fixture.runtime.unregister(modelId: Self.coldModel)
        #expect(await fixture.stop(task))
    }

    @Test("the kill switch keeps the FIFO serial behind a load wait")
    func killSwitchKeepsSerialAdmission() async throws {
        let fixture = try await ServeLoopFixture.make(models: [ModelLoadingFixtures.model(Self.coldModel)])
        await fixture.loop.setColdLoadReleasesWorkFIFOForTesting(false)
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        await fixture.loop.modelLoadingMarkLoading(Self.coldModel)

        try await fixture.pushChatRequest(requestId: "cold", body: Self.body(model: Self.coldModel))
        try await Self.until { await fixture.loop.modelLoadingLoadingWaiterCount(Self.coldModel) == 1 }
        try await fixture.pushChatRequest(requestId: "warm")
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.engine.continuations.isEmpty)
        #expect(await fixture.loop.releasedAdmissionCountForTesting() == 0)

        await fixture.loop.modelLoadingResumeLoadingWaiters(Self.coldModel, failure: "scripted")
        try await fixture.awaitSubmissions(1)
        fixture.completeSubmission(0)
        #expect(await fixture.stop(task))
    }

    @Test("connection, drain and model-management events wait for released admissions")
    func barrierEvents() {
        #expect(CoordinatorEvent.cancel(requestId: "r").overtakesReleasedAdmissions)
        #expect(CoordinatorEvent.attestationChallenge(nonce: "n", timestamp: "t").overtakesReleasedAdmissions)
        #expect(!CoordinatorEvent.disconnected.overtakesReleasedAdmissions)
        #expect(!CoordinatorEvent.connected.overtakesReleasedAdmissions)
        #expect(!CoordinatorEvent.drainAck("d").overtakesReleasedAdmissions)
        #expect(!CoordinatorEvent.loadModel(modelId: "m").overtakesReleasedAdmissions)
        #expect(!CoordinatorEvent.desiredModels(entries: []).overtakesReleasedAdmissions)
        #expect(!CoordinatorEvent.prefetchModel(modelId: "m", priority: 0).overtakesReleasedAdmissions)
        #expect(WorkFIFOPolicy.releasesColdLoadWaits(environment: [:]))
        #expect(!WorkFIFOPolicy.releasesColdLoadWaits(environment: ["DARKBLOOM_TTFT_COLD_LOAD_RELEASE": "0"]))
    }

    private static func body(model: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 1, "stream": true, "reasoning_parser": "none",
        ])
    }

    private static func until(
        timeout: Duration = .seconds(10), _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}
