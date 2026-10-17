import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite(.timeLimit(.minutes(1)))
struct DistributedCBv2DeadlineTests {
    @Test func callerPhaseRatesRemainAnAdmissionConstraint() async throws {
        let rates: [Double?] = [nil, .nan, 0, 0.01]
        for rate in rates {
            let owner = DistributedTestOwner()
            let clock = DistributedTestClock()
            let engine = try distributedTestEngine(owner, clock: clock.clock)
            let admission = CBv2FirstTokenDeadlineAdmission(
                deadline: clock.now.advanced(by: .seconds(30)),
                conservativePrefillTokensPerSecond: rate, conservativeDecodeTokensPerSecond: 100)
            let result = try await engine.submit(distributedTestRequest(), firstTokenDeadline: admission)
            guard case .deadlineUnreachable = result else { Issue.record("caller rate was ignored"); return }
            #expect(owner.reserveCount == 0)
            await engine.shutdown()
        }
    }

    @Test func unknownOrInvalidProjectionDoesNotStartOrReserve() async throws {
        let projections: [CBv2FirstTokenProjectedWork] = [
            .unbounded(reason: nil),
            .bounded(work: .init(prefillTokens: 2, decodeTokens: 0, scheduledSteps: 1, mixedSteps: 0),
                     serviceDuration: .seconds(1)),
            .bounded(work: .init(prefillTokens: 3, decodeTokens: 0, scheduledSteps: 0, mixedSteps: 0),
                     serviceDuration: .seconds(1)),
            .bounded(work: .init(prefillTokens: 3, decodeTokens: 0, scheduledSteps: 1, mixedSteps: 0),
                     serviceDuration: .zero),
            .bounded(work: .init(prefillTokens: 3, decodeTokens: 0, scheduledSteps: 1, mixedSteps: 0),
                     serviceDuration: .seconds(60))
        ]
        for projection in projections {
            let owner = DistributedTestOwner()
            owner.projection = projection
            let clock = DistributedTestClock()
            let engine = try distributedTestEngine(owner, clock: clock.clock)
            let result = try await engine.submit(
                distributedTestRequest(), firstTokenDeadline: distributedTestDeadline(clock.now.advanced(by: .seconds(30))))
            guard case .deadlineUnreachable = result else { Issue.record("expected refusal"); return }
            #expect(owner.reserveCount == 0)
            await engine.shutdown()
        }
    }

    @Test func deadlineRecheckedAfterReservationAndResourcesRetiredBeforeRefusal() async throws {
        let owner = DistributedTestOwner()
        let clock = DistributedTestClock()
        let engine = try distributedTestEngine(owner, clock: clock.clock)
        owner.onReserve = {
            clock.advance(.seconds(5))
            // No work starts, but even a pre-start reservation needs an ack.
            owner.last.acknowledge()
        }
        let result = try await engine.submit(
            distributedTestRequest(), firstTokenDeadline: distributedTestDeadline(clock.now.advanced(by: .seconds(3))))
        guard case .deadlineUnreachable = result else { Issue.record("expected post-reservation refusal"); return }
        #expect(owner.last.startCount == 0)
        #expect(owner.last.cancelCount == 1)
        #expect(owner.last.releaseCount == 1)
        #expect(engine.capacity().activeRequests == 0)
        await engine.shutdown()
    }

    @Test func admittedHandleAndTerminalWaitForTheSameRetirement() async throws {
        let owner = DistributedTestOwner()
        let clock = DistributedTestClock()
        // First target token can come from the final prefill, without a decode step.
        owner.projection = .bounded(
            work: .init(prefillTokens: 3, decodeTokens: 0, scheduledSteps: 1, mixedSteps: 0),
            serviceDuration: .seconds(1))
        let engine = try distributedTestEngine(owner, clock: clock.clock)
        let result = try await engine.submit(
            distributedTestRequest(maxTokens: 1),
            firstTokenDeadline: distributedTestDeadline(clock.now.advanced(by: .seconds(3))))
        guard case .admitted(let stream, _, let admittedAt, let retirement) = result else {
            Issue.record("expected admission"); return
        }
        #expect(admittedAt == clock.now)
        owner.last.send(.token(4))
        #expect(owner.last.releaseCount == 0)
        owner.last.acknowledge()
        await retirement.wait()
        #expect(owner.last.releaseCount == 1)
        #expect(distributedTerminal(await distributedCollect(stream))?.0 == .length)
        await engine.shutdown()
    }

    @Test func firstTokenDeadlineAndAbsoluteDeadlineCancelWithoutEarlyRelease() async throws {
        for firstToken in [true, false] {
            let owner = DistributedTestOwner()
            let clock = DistributedTestClock()
            let engine = try distributedTestEngine(owner, clock: clock.clock)
            let result = try await engine.submit(
                distributedTestRequest(),
                firstTokenDeadline: distributedTestDeadline(clock.now.advanced(by: .seconds(3))))
            guard case .admitted(let stream, _, _, let retirement) = result else {
                Issue.record("expected admission"); return
            }
            if !firstToken { owner.last.send(.token(4)) }
            clock.advance(firstToken ? .seconds(3) : .seconds(315))
            #expect(!owner.last.send(.token(5))) // event path checks the same absolute clock
            #expect(owner.last.cancelCount == 1)
            #expect(owner.last.releaseCount == 0)
            #expect(engine.capacity().activeRequests == 1)
            owner.last.acknowledge()
            await retirement.wait()
            let terminal = distributedTerminal(await distributedCollect(stream))
            guard let terminal, case .terminal(let cause, _) = terminal.0 else {
                Issue.record("expected typed deadline terminal"); return
            }
            #expect(cause == (firstToken ? .prefillStall : .safetyDeadline))
            await engine.shutdown()
        }
    }

    /// Under phase split the pair selects the first token and only then hands
    /// the request state to rank 1; later tokens reach the owner in relayed
    /// batches. The first-token budget ends with the first token: a pause as
    /// long as the hand-off's own agreed limit, and sixteen tokens arriving at
    /// once, are charged to the generation deadline alone.
    @Test func handOffPauseAndRelayBatchesAfterTheFirstTokenAreNotFirstTokenTime() async throws {
        let owner = DistributedTestOwner()
        let clock = DistributedTestClock()
        let engine = try distributedTestEngine(owner, clock: clock.clock)
        let result = try await engine.submit(
            distributedTestRequest(maxTokens: 40),
            firstTokenDeadline: distributedTestDeadline(clock.now.advanced(by: .seconds(3))))
        guard case .admitted(let stream, _, _, let retirement) = result else {
            Issue.record("expected admission"); return
        }
        clock.advance(.seconds(2))
        #expect(owner.last.send(.token(4))) // selected by the pair, inside its budget
        clock.advance(.seconds(20)) // the hand-off's agreed limit, far past the first-token deadline
        for _ in 0..<16 { #expect(owner.last.send(.token(5))) } // one relay batch, all at once
        clock.advance(.milliseconds(600)) // rank 1 decodes the next batch
        for _ in 0..<16 { #expect(owner.last.send(.token(4))) }
        #expect(owner.last.cancelCount == 0)
        #expect(engine.capacity().activeRequests == 1)
        for index in 0..<7 { #expect(owner.last.send(.token(5)) == (index < 6)) } // the fortieth token is the limit
        owner.last.send(.finished(.length))
        owner.last.acknowledge()
        await retirement.wait()
        let terminal = distributedTerminal(await distributedCollect(stream))
        #expect(terminal?.0 == .length)
        #expect(terminal?.1.completionTokens == 40)
        #expect(owner.last.cancelCount == 0)
        await engine.shutdown()
    }

    @Test func ordinarySubmissionAlsoHasAnAbsoluteDeadline() async throws {
        let owner = DistributedTestOwner()
        let clock = DistributedTestClock()
        let engine = try distributedTestEngine(owner, clock: clock.clock)
        let stream = try engine.submit(distributedTestRequest())
        clock.advance(.seconds(316))
        #expect(!owner.last.send(.token(4)))
        #expect(owner.last.releaseCount == 0)
        owner.last.acknowledge()
        let terminal = distributedTerminal(await distributedCollect(stream))
        guard let terminal, case .terminal(let cause, _) = terminal.0 else {
            Issue.record("expected bounded ordinary submission"); return
        }
        #expect(cause == .safetyDeadline)
        await engine.shutdown()
    }

    @Test func cancellationDuringReservationCannotStartAndCarriesRetirementHandle() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let cancellation = DistributedAdmissionCancellation()
        owner.onReserve = { cancellation.cancel() }
        do {
            _ = try await engine.submit(
                distributedTestRequest(), deadline: distributedTestDeadline(ContinuousClock.now.advanced(by: .seconds(30))),
                cancellation: cancellation)
            Issue.record("expected cancellation handoff")
        } catch let handoff as CBv2FirstTokenAdmissionCancellation {
            #expect(owner.last.startCount == 0)
            #expect(owner.last.cancelCount == 1)
            #expect(owner.last.releaseCount == 0)
            owner.last.acknowledge()
            await handoff.retirement.wait()
            #expect(distributedTerminal(await distributedCollect(handoff.stream))?.0 == .cancelled)
            #expect(owner.last.releaseCount == 1)
        }
        await engine.shutdown()
    }

    @Test func oldGenerationTerminationCannotCancelAReusedRequestID() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let first = try engine.submit(distributedTestRequest(maxTokens: 1))
        let oldTermination = engine.onQueue { engine.active?.continuation.onTermination }
        owner.last.send(.token(4))
        owner.last.acknowledge()
        _ = await distributedCollect(first)
        let second = try engine.submit(distributedTestRequest(maxTokens: 1))
        oldTermination?(.cancelled)
        #expect(owner.last.cancelCount == 0)
        owner.last.send(.token(5))
        owner.last.acknowledge()
        #expect(distributedTerminal(await distributedCollect(second))?.0 == .length)
        await engine.shutdown()
    }
}
