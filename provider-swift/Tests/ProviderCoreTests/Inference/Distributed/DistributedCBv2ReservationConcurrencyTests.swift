import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A pair serving several lanes keeps them decoding while another request is
/// admitted, and counts what it holds. A reservation waits until both ranks
/// answer at their next step boundary, and rank 0 waits a bounded time each
/// step for its owner's answer to every running lane's token: a token answered
/// only after the reservation returns stalls every lane and the reservation
/// with it. A request reserving, or waiting to reserve, holds a lane the
/// coordinator must not be offered. Fabricated owners only: no model, GPU or peer.
@Suite(.timeLimit(.minutes(1)))
struct DistributedCBv2ReservationConcurrencyTests {
    typealias RankStep = DistributedCBv2StalledReservationTests.RankStep

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

    /// One running lane, and a second request whose reservation the ranks hold.
    private func runningLaneAndAReservation(lanes: Int = 8) async throws
        -> (DistributedTestOwner, DistributedCBv2Engine, RankStep, AsyncStream<CBv2Event>, DistributedTestBox<AsyncStream<CBv2Event>>) {
        let owner = DistributedTestOwner()
        owner.lanes = lanes
        let engine = try distributedTestEngine(owner)
        let first = try engine.submit(distributedTestRequest(1, maxTokens: 8))
        #expect(owner.lease(0).startCount == 1)
        let step = RankStep()
        owner.onReserve = { step.wait() }
        let second = DistributedTestBox<AsyncStream<CBv2Event>>()
        DispatchQueue.global().async { second.set(try? engine.submit(distributedTestRequest(2, maxTokens: 8))) }
        await until { step.waitingCount == 1 }
        #expect(step.waitingCount == 1, "the second reservation is waiting for the ranks")
        return (owner, engine, step, first, second)
    }

    @Test func aRunningLanesTokenIsAnsweredWhileAnotherRequestReserves() async throws {
        let (owner, engine, step, first, second) = try await runningLaneAndAReservation()
        let answer = DistributedTestBox<Bool>()
        #expect(await returnsPromptly { answer.set(owner.lease(0).send(.token(7))) },
                "the running lane's token waited for another request's reservation")
        #expect(answer.value == true, "the lane goes on")
        step.finish()
        await until { second.value != nil }
        owner.lease(0).send(.finished(.stop))
        owner.lease(0).acknowledge()
        let events = await distributedCollect(first)
        #expect(distributedText(events).contains("t7"))
        await finish(owner, engine, [try #require(second.value)])
    }

    @Test func aCapacityReadCountsTheRequestsBeingAdmitted() async throws {
        let (owner, engine, step, first, second) = try await runningLaneAndAReservation()
        let third = DistributedTestBox<AsyncStream<CBv2Event>>()
        DispatchQueue.global().async { third.set(try? engine.submit(distributedTestRequest(3, maxTokens: 8))) }
        await until { engine.capacity().waitingRequests == 2 }
        let held = engine.capacity()
        #expect(held.activeRequests == 1, "the admitted lane")
        #expect(held.waitingRequests == 2, "the request reserving and the one waiting to reserve hold lanes too")
        step.finish()
        await until { third.value != nil }
        await until { engine.capacity().activeRequests == 3 }
        #expect(engine.capacity().activeRequests == 3)
        #expect(engine.capacity().waitingRequests == 0)
        await finish(owner, engine, [first, try #require(second.value), try #require(third.value)])
    }

    @Test func aLaneBeingReservedIsNotOfferedAgain() async throws {
        let (owner, engine, step, first, second) = try await runningLaneAndAReservation(lanes: 2)
        let refusal = DistributedTestBox<Error>()
        #expect(await returnsPromptly {
            do { _ = try engine.submit(distributedTestRequest(3, maxTokens: 8)) } catch { refusal.set(error) }
        }, "a request beyond the lanes waited for another request's reservation before it was refused")
        if case CBv2KVError.capacityExhausted? = refusal.value {} else {
            Issue.record("expected the lane refusal, got \(String(describing: refusal.value))")
        }
        step.finish()
        await until { second.value != nil }
        #expect(owner.reserveCount == 2, "the refused request asked the ranks")
        await finish(owner, engine, [first, try #require(second.value)])
    }

    /// A shutdown begun during a reservation stops that request once the ranks
    /// answer, and releases the owner only after it retired.
    @Test func aShutdownWaitsForTheRequestBeingReserved() async throws {
        let (owner, engine, step, first, second) = try await runningLaneAndAReservation()
        let shutdown = Task { await engine.shutdown() }
        await until { owner.lease(0).cancelCount == 1 }
        owner.lease(0).acknowledge()
        _ = await distributedCollect(first)
        step.finish()
        await until { second.value != nil }
        await until { owner.lease(1).cancelCount == 1 }
        #expect(owner.lease(1).cancelCount == 1, "the request reserved during the shutdown was not stopped")
        #expect(owner.lease(1).startCount == 0, "its prompt started")
        try await Task.sleep(for: .milliseconds(100))
        #expect(owner.shutdownCount == 0, "the owner was released before the reserved request retired")
        owner.lease(1).acknowledge()
        #expect(distributedTerminal(await distributedCollect(try #require(second.value)))?.0 == .cancelled)
        await shutdown.value
        #expect(owner.shutdownCount == 1)
    }

    @Test func theHeartbeatCountsARequestBeingAdmitted() async throws {
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
        var slot = await bridge.backendSlotCapacity()
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while Int(slot.numRunning) + Int(slot.numWaiting) < 2 && ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(20))
            slot = await bridge.backendSlotCapacity()
        }
        #expect(slot.numRunning == 1)
        #expect(slot.numWaiting == 1, "the request the ranks are reserving for is advertised as free room")
        step.finish()
        let secondStream = await second.value
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
