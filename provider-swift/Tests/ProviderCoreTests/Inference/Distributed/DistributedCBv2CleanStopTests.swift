import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A client that goes away, and a host that is stopping, end the request with
/// the owner's clean stop instead of its failure path, so the pair stays in
/// service; a deadline still ends a clean stop that does not come; and a
/// failure reaches the consumer when it is known, not at retirement.
/// Fabricated owners only: no model, GPU or peer process.
@Suite(.timeLimit(.minutes(1)))
struct DistributedCBv2CleanStopTests {
    private func cleanStopOwner() -> DistributedTestOwner {
        let owner = DistributedTestOwner()
        owner.leasesAcceptCleanStop = true
        return owner
    }

    /// Collects the stream, or nil when it has not finished within `seconds`.
    private func collect(_ stream: AsyncStream<CBv2Event>, within seconds: Double) async -> [CBv2Event]? {
        let box = DistributedCollected()
        let task = Task { box.set(await distributedCollect(stream)) }
        let end = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while box.value == nil && ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
        if box.value == nil { task.cancel() }
        return box.value
    }

    @Test func clientHangUpAfterATokenIsACleanStopAndTheOwnerServesTheNextRequest() async throws {
        let owner = cleanStopOwner()
        let engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest(maxTokens: 8))
        let lease = owner.last
        #expect(lease.send(.token(4)))
        engine.cancel(.init(1))
        engine.cancel(.init(1))
        #expect(lease.cleanStopCount == 1)
        #expect(lease.cancelCount == 0) // the pair's failure path is not taken
        #expect(!lease.send(.token(5))) // the token the stop answers is not delivered
        #expect(!lease.send(.finished(.stop)))
        #expect(lease.cancelCount == 0)
        #expect(engine.capacity().activeRequests == 1) // held until both peers retire
        lease.acknowledge()
        let events = await distributedCollect(stream)
        #expect(distributedText(events) == "t4")
        #expect(distributedTerminal(events)?.0 == .cancelled)
        #expect(distributedTerminal(events)?.1.completionTokens == 1)
        #expect(lease.releaseCount == 1)
        #expect(engine.capacity().kvBytesCapacity > 0)
        let next = try engine.submit(distributedTestRequest(2, maxTokens: 1))
        #expect(!owner.last.send(.token(6)))
        owner.last.acknowledge()
        let second = await distributedCollect(next)
        #expect(distributedText(second) == "t6")
        #expect(distributedTerminal(second)?.0 == .length)
        await engine.shutdown()
    }

    @Test func droppedStreamIsTheSameCleanStop() async throws {
        let owner = cleanStopOwner()
        let engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest(maxTokens: 8))
        #expect(owner.last.send(.token(4)))
        let task = Task { for await _ in stream {} }
        task.cancel(); _ = await task.value
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while owner.last.cleanStopCount == 0 && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(owner.last.cleanStopCount == 1)
        #expect(owner.last.cancelCount == 0)
        owner.last.acknowledge()
        await engine.shutdown()
        #expect(owner.shutdownCount == 1)
    }

    @Test func hangUpBeforeTheFirstTokenStopsAtItAndTheFirstTokenBudgetEnds() async throws {
        let owner = cleanStopOwner()
        let clock = DistributedTestClock()
        let engine = try distributedTestEngine(owner, clock: clock.clock)
        let result = try await engine.submit(
            distributedTestRequest(maxTokens: 8),
            firstTokenDeadline: distributedTestDeadline(clock.now.advanced(by: .seconds(3))))
        guard case .admitted(let stream, _, _, let retirement) = result else {
            Issue.record("expected admission"); return
        }
        engine.cancel(.init(1))
        #expect(owner.last.cleanStopCount == 1)
        clock.advance(.seconds(2))
        #expect(!owner.last.send(.token(4))) // the first token answers the stop
        clock.advance(.seconds(2)) // past the first-token deadline: the stop has been answered
        engine.onQueue { if let active = engine.active { engine.checkDeadline(active) } }
        #expect(owner.last.cancelCount == 0)
        owner.last.acknowledge()
        await retirement.wait()
        let events = await distributedCollect(stream)
        #expect(distributedText(events).isEmpty)
        #expect(distributedTerminal(events)?.0 == .cancelled)
        await engine.shutdown()
    }

    @Test func aCleanStopThatDoesNotComeIsCancelledAtTheRequestsDeadline() async throws {
        for beforeFirstToken in [true, false] {
            let owner = cleanStopOwner()
            let clock = DistributedTestClock()
            let engine = try distributedTestEngine(owner, clock: clock.clock)
            let result = try await engine.submit(
                distributedTestRequest(maxTokens: 8),
                firstTokenDeadline: distributedTestDeadline(clock.now.advanced(by: .seconds(3))))
            guard case .admitted(let stream, _, _, let retirement) = result else {
                Issue.record("expected admission"); return
            }
            if !beforeFirstToken { #expect(owner.last.send(.token(4))) }
            engine.cancel(.init(1))
            #expect(owner.last.cleanStopCount == 1)
            #expect(owner.last.cancelCount == 0)
            // The stalled pair never answers; the deadline timer fires.
            clock.advance(beforeFirstToken ? .seconds(3) : .seconds(315))
            engine.onQueue { if let active = engine.active { engine.checkDeadline(active) } }
            #expect(owner.last.cancelCount == 1)
            #expect(owner.last.releaseCount == 0)
            #expect(engine.capacity().activeRequests == 1)
            // The consumer learns the cause now, before the peers retire.
            let events = await collect(stream, within: 2)
            guard let events, let terminal = distributedTerminal(events), case .terminal(let cause, _) = terminal.0 else {
                Issue.record("the deadline was not published before retirement"); return
            }
            #expect(cause == (beforeFirstToken ? .prefillStall : .safetyDeadline))
            owner.last.acknowledge()
            await retirement.wait()
            #expect(owner.last.releaseCount == 1)
            await engine.shutdown()
        }
    }

    @Test func aLostPeerIsPublishedWhenItIsKnownNotAtRetirement() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest(maxTokens: 8))
        #expect(owner.last.send(.token(4)))
        owner.losePeer()
        #expect(owner.last.cancelCount == 1)
        let events = await collect(stream, within: 2)
        #expect(events.flatMap(distributedTerminal)?.0 == .error("distributed peer readiness lost"))
        #expect(events.map(distributedText) == "t4")
        #expect(owner.last.releaseCount == 0) // resources stay owned until retirement
        #expect(engine.capacity().activeRequests == 1)
        owner.last.acknowledge()
        await engine.shutdown()
        #expect(owner.last.releaseCount == 1)
    }

    @Test func anOwnersOwnStopIsReportedAsCancelledWithoutCancellingTheLease() async throws {
        let owner = cleanStopOwner()
        let engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest(maxTokens: 8))
        #expect(owner.last.send(.token(4)))
        #expect(!owner.last.send(.finished(.cancelled)))
        #expect(owner.last.cancelCount == 0)
        owner.last.acknowledge()
        #expect(distributedTerminal(await distributedCollect(stream))?.0 == .cancelled)
        await engine.shutdown()
    }

    @Test func shutdownWithARunningRequestUsesTheCleanStop() async throws {
        let owner = cleanStopOwner()
        let engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest(maxTokens: 8))
        #expect(owner.last.send(.token(4)))
        let shutdown = Task { await engine.shutdown() }
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while owner.last.cleanStopCount == 0 && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(owner.last.cleanStopCount == 1)
        #expect(owner.last.cancelCount == 0)
        #expect(!owner.last.send(.token(5)))
        owner.last.acknowledge()
        await shutdown.value
        #expect(owner.shutdownCount == 1)
        #expect(distributedTerminal(await distributedCollect(stream))?.0 == .cancelled)
    }

    @Test func cancellationDuringReservationStartsAndStopsAtTheFirstToken() async throws {
        let owner = cleanStopOwner()
        let engine = try distributedTestEngine(owner)
        let cancellation = DistributedAdmissionCancellation()
        owner.onReserve = { cancellation.cancel() }
        do {
            _ = try await engine.submit(
                distributedTestRequest(), deadline: distributedTestDeadline(ContinuousClock.now.advanced(by: .seconds(30))),
                cancellation: cancellation)
            Issue.record("expected cancellation handoff")
        } catch let handoff as CBv2FirstTokenAdmissionCancellation {
            // The owner cannot give a reservation back without ending its
            // ranks; it is started instead and stops at its first token.
            #expect(owner.last.startCount == 1)
            #expect(owner.last.cleanStopCount == 1)
            #expect(owner.last.cancelCount == 0)
            #expect(!owner.last.send(.token(4)))
            owner.last.acknowledge()
            await handoff.retirement.wait()
            #expect(distributedTerminal(await distributedCollect(handoff.stream))?.0 == .cancelled)
            #expect(owner.last.releaseCount == 1)
        }
        await engine.shutdown()
    }
}

private final class DistributedCollected: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CBv2Event]?
    func set(_ value: [CBv2Event]) { lock.withLock { events = value } }
    var value: [CBv2Event]? { lock.withLock { events } }
}
