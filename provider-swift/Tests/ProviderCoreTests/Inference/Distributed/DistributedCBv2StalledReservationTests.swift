import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A pair's reservation waits until both ranks answer at their next step
/// boundary, up to the lane admission wait (30 s). A capacity read and a cancel
/// never wait behind it; a cancel of another request takes effect at once, and
/// the cancel of the request whose reservation it is once that returns.
/// Fabricated owners only: no model, GPU or peer.
@Suite(.timeLimit(.minutes(1)))
struct DistributedCBv2StalledReservationTests {
    /// Holds the owner's reservations, as ranks in the middle of a prefill step.
    final class RankStep: @unchecked Sendable {
        private let condition = NSCondition()
        private var finished = false
        private var waiting = 0

        var waitingCount: Int { condition.withLock { waiting } }
        func wait() {
            condition.lock()
            waiting += 1
            while !finished { condition.wait() }
            waiting -= 1
            condition.unlock()
        }
        func finish() { condition.withLock { finished = true; condition.broadcast() } }
    }

    /// Runs `body` on its own thread; reports whether it returned within `seconds`.
    private func returnsPromptly(within seconds: Double = 2, _ body: @escaping @Sendable () -> Void) async -> Bool {
        let done = DistributedTestFlag()
        DispatchQueue.global().async { body(); done.set() }
        let end = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !done.value && ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        return done.value
    }

    private func until(_ condition: () -> Bool) async {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// One admitted lane in its prompt, and a second reservation held by the
    /// ranks' step on another thread.
    private func stalledPair() async throws
        -> (DistributedTestOwner, DistributedCBv2Engine, RankStep, AsyncStream<CBv2Event>, DistributedTestBox<AsyncStream<CBv2Event>>) {
        let owner = DistributedTestOwner()
        owner.lanes = 8
        let engine = try distributedTestEngine(owner)
        let first = try engine.submit(distributedTestRequest(1, maxTokens: 8))
        let step = RankStep()
        owner.onReserve = { step.wait() }
        let second = DistributedTestBox<AsyncStream<CBv2Event>>()
        DispatchQueue.global().async { second.set(try? engine.submit(distributedTestRequest(2, maxTokens: 8))) }
        await until { step.waitingCount == 1 }
        #expect(step.waitingCount == 1, "the second reservation is waiting for the ranks")
        return (owner, engine, step, first, second)
    }

    @Test func aCapacityReadDoesNotWaitForAReservation() async throws {
        let (owner, engine, step, first, second) = try await stalledPair()
        let capacity = DistributedTestBox<CBv2CapacitySnapshot>()
        #expect(await returnsPromptly { capacity.set(engine.capacity()) },
                "the capacity read waited for the ranks' step")
        step.finish()
        await until { capacity.value != nil }
        #expect(capacity.value?.activeRequests == 1, "the admitted lane, not the one still reserving")
        #expect((capacity.value?.kvBytesCapacity ?? 0) > 0)

        // Once the reservation returns, the next read counts both lanes.
        await until { second.value != nil }
        await until { engine.capacity().activeRequests == 2 }
        #expect(engine.capacity().activeRequests == 2)
        await finish(owner, engine, [first, try #require(second.value)])
    }

    @Test func aLostPeerReadsAsNoCapacityWhileAReservationWaits() async throws {
        let (owner, engine, step, first, second) = try await stalledPair()
        owner.losePeer(notify: false)
        let capacity = DistributedTestBox<CBv2CapacitySnapshot>()
        #expect(await returnsPromptly { capacity.set(engine.capacity()) })
        #expect(capacity.value?.kvBytesCapacity == 0)
        step.finish()
        await until { second.value != nil }
        // The checks the read queued ran once the queue was free: the engine
        // stays withdrawn even if the peer answers again.
        owner.available = true
        await until { engine.capacity().kvBytesCapacity == 0 && engine.capacity().activeRequests == 2 }
        engine.onQueue {}
        #expect(engine.capacity().kvBytesCapacity == 0)
        await finish(owner, engine, [first, try #require(second.value)])
    }

    @Test func aCancelReturnsAndLandsAtOnceWhileAnotherRequestReserves() async throws {
        let (owner, engine, step, first, second) = try await stalledPair()
        // A lane still in its prompt: P2-9's lane cancel, not a clean stop.
        #expect(await returnsPromptly { engine.cancel(.init(1)) }, "the cancel waited for the ranks' step")
        // The reservation waits off the engine queue, so the cancel needs no turn behind it.
        await until { owner.lease(0).cancelCount == 1 }
        #expect(owner.lease(0).cancelCount == 1, "the cancel waited for another request's reservation")
        step.finish()
        await until { second.value != nil }
        engine.onQueue {}
        #expect(owner.lease(0).cancelCount == 1)
        #expect(owner.lease(0).cleanStopCount == 0)
        #expect(owner.lease(1).cancelCount == 0, "only the named request is cancelled")
        await finish(owner, engine, [first, try #require(second.value)])
    }

    @Test func aCancelForTheReservingRequestIsAppliedOnceItIsAdmitted() async throws {
        let (owner, engine, step, first, second) = try await stalledPair()
        #expect(await returnsPromptly { engine.cancel(.init(2)) }, "the cancel waited for the ranks' step")
        step.finish()
        await until { second.value != nil }
        engine.onQueue {}
        #expect(owner.reserveCount == 2)
        #expect(owner.lease(1).cancelCount == 1, "the cancel queued behind its own reservation was lost")
        #expect(owner.lease(0).cancelCount == 0)
        owner.lease(1).acknowledge()
        let events = await distributedCollect(try #require(second.value))
        #expect(distributedTerminal(events)?.0 == .cancelled)
        owner.lease(0).acknowledge()
        _ = await distributedCollect(first)
        await engine.shutdown()
    }

    @Test func aSubmissionCancelledWhileItWaitsForTheQueueNeverAsksTheRanks() async throws {
        let (owner, engine, step, first, second) = try await stalledPair()
        let third = Task {
            try await engine.submit(distributedTestRequest(3, maxTokens: 8),
                firstTokenDeadline: distributedTestDeadline(ContinuousClock.now.advanced(by: .seconds(60))))
        }
        // The third submission waits for the queue behind the held reservation;
        // its caller goes away meanwhile.
        try await Task.sleep(for: .milliseconds(300))
        third.cancel()
        step.finish()
        let outcome = await third.result
        #expect(owner.reserveCount == 2, "the cancelled submission still asked the ranks for a reservation")
        if case .success = outcome { Issue.record("a cancelled submission was admitted") }
        await finish(owner, engine, [first, try #require(second.value)])
    }

    /// A pair measures no prefill rate, so the provider's bridge submits its
    /// requests without a projected admission. That submission must not wait
    /// for the engine queue on the bridge's actor: a cancel and every capacity
    /// read need the actor while another request's reservation holds the queue.
    @Test func theBridgeAnswersCancelsAndCapacityReadsWhileAReservationWaits() async throws {
        let owner = DistributedTestOwner()
        owner.lanes = 8
        let bridge = try DistributedEngineFactory.makeBridge(
            owner: owner, expectedIdentity: owner.identity, profile: distributedTestProfile(),
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
        let model = owner.identity.modelID
        let submit: @Sendable (String) async -> AsyncStream<GenerationEvent> = { id in
            await bridge.submitTokenized(
                promptTokens: [1, 2, 3],
                request: ChatCompletionRequest(model: model, messages: [], temperature: 0, max_tokens: 1),
                requestId: id, cacheEnabled: false)
        }
        let first = await submit("first")
        let step = RankStep()
        owner.onReserve = { step.wait() }
        let second = Task { await submit("second") }
        await until { step.waitingCount == 1 }
        #expect(step.waitingCount == 1, "the second reservation is waiting for the ranks")

        let answered = DistributedTestFlag()
        let reads = Task {
            _ = await bridge.backendSlotCapacity()
            await bridge.cancel(requestId: "first")
            answered.set()
        }
        await until { answered.value }
        #expect(answered.value, "the bridge waited for the ranks' step")

        // A request whose caller goes away while it waits behind that
        // reservation never asks the ranks.
        let third = Task { await submit("third") }
        try await Task.sleep(for: .milliseconds(300))
        third.cancel()
        step.finish()
        await reads.value
        let secondStream = await second.value
        _ = await third.value
        // The cancel lands once the reservation returns, on its own request.
        await until { owner.lease(0).cancelCount == 1 }
        #expect(owner.lease(0).cancelCount == 1)
        #expect(owner.reserveCount == 2, "the request cancelled while it waited still asked the ranks")
        #expect(owner.lease(1).cancelCount == 0)
        for index in 0..<owner.reserveCount { owner.lease(index).acknowledge() }
        for await _ in first {}
        for await _ in secondStream {}
        await bridge.shutdown()
    }

    private func finish(_ owner: DistributedTestOwner, _ engine: DistributedCBv2Engine,
                        _ streams: [AsyncStream<CBv2Event>]) async {
        for index in 0..<owner.reserveCount { owner.lease(index).acknowledge() }
        let shutdown = Task { await engine.shutdown() }
        for stream in streams { _ = await distributedCollect(stream) }
        await shutdown.value
    }
}

final class DistributedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.withLock { isSet = true } }
    var value: Bool { lock.withLock { isSet } }
}

final class DistributedTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    func set(_ value: Value?) { lock.withLock { stored = value } }
    var value: Value? { lock.withLock { stored } }
}
