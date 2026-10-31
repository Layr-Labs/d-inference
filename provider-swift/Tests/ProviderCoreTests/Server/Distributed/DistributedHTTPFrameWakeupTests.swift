import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite(.timeLimit(.minutes(1)))
struct DistributedHTTPFrameWakeupTests {
    @Test func arrivalsBeforeAndAfterConsumerRegistrationAreNotLost() async throws {
        let (frames, source) = AsyncThrowingStream<String, Error>.makeStream()
        let pump = DistributedHTTPFramePump(frames, maximumFrameBytes: 1024)
        defer { pump.cancel() }
        source.yield("before")
        #expect(try await httpDeliveryEventually { pump.pendingFrames == 1 })
        guard case .item(.frame("before")) = await pump.next(until: ContinuousClock.now.advanced(by: .seconds(5))) else {
            Issue.record("Buffered arrival was lost"); return
        }
        let waiting = Task { await pump.next(until: ContinuousClock.now.advanced(by: .seconds(5))) }
        #expect(try await httpDeliveryEventually { pump.waitingConsumer })
        let arrived = ContinuousClock.now
        source.yield("after")
        guard case .item(.frame("after")) = await waiting.value else { Issue.record("Waiting consumer was not notified"); return }
        #expect(arrived.duration(to: ContinuousClock.now) < .seconds(1)) // five-second timer did not supply the wakeup
        #expect(!pump.waitingConsumer)
        source.finish()
        guard case .item(.end) = await pump.next(until: ContinuousClock.now.advanced(by: .seconds(5))) else {
            Issue.record("End was lost"); return
        }
        let producer = pump.cancel(); await producer?.value
    }

    @Test func timeoutDoesNotDiscardTheNextFrameOrLeaveAStreamReadBehind() async throws {
        let (frames, source) = AsyncThrowingStream<String, Error>.makeStream()
        let pump = DistributedHTTPFramePump(frames, maximumFrameBytes: 1024)
        defer { pump.cancel() }
        guard case .probe = await pump.next(until: ContinuousClock.now.advanced(by: .milliseconds(10))) else {
            Issue.record("Idle wait did not time out"); return
        }
        #expect(!pump.waitingConsumer && pump.pendingFrames == 0)
        source.yield("later")
        #expect(try await httpDeliveryEventually { pump.pendingFrames == 1 })
        // A queued frame wins an expired *probe* timer; content's independent
        // absolute deadline is still checked by the writer before acceptance.
        guard case .item(.frame("later")) = await pump.next(until: ContinuousClock.now.advanced(by: .seconds(-1))) else {
            Issue.record("Probe timeout consumed a later frame"); return
        }
        let producer = pump.cancel(); await producer?.value
    }

    @Test func sameDeadlineArrivalAndProbeRaceDeliverEachFrameExactlyOnce() async throws {
        for index in 0..<32 {
            let (frames, source) = AsyncThrowingStream<String, Error>.makeStream()
            let pump = DistributedHTTPFramePump(frames, maximumFrameBytes: 1024)
            let end = ContinuousClock.now.advanced(by: .milliseconds(2))
            let reading = Task { await pump.next(until: end) }
            let sending = Task {
                try? await ContinuousClock().sleep(until: end)
                source.yield("\(index)"); source.finish()
            }
            var first = await reading.value
            if case .probe = first { first = await pump.next(until: ContinuousClock.now.advanced(by: .seconds(2))) }
            guard case .item(.frame(let value)) = first else {
                pump.cancel(); await sending.value; Issue.record("Arrival disappeared in timeout race"); return
            }
            #expect(value == "\(index)")
            guard case .item(.end) = await pump.next(until: ContinuousClock.now.advanced(by: .seconds(2))) else {
                pump.cancel(); await sending.value; Issue.record("Duplicate frame or missing end"); return
            }
            await sending.value
            let producer = pump.cancel(); await producer?.value
        }
    }

    @Test func consumerCancellationResumesAndJoinsBothWaits() async throws {
        let (frames, source) = AsyncThrowingStream<String, Error>.makeStream()
        let pump = DistributedHTTPFramePump(frames, maximumFrameBytes: 1024)
        let reading = Task { await pump.next(until: ContinuousClock.now.advanced(by: .seconds(30))) }
        #expect(try await httpDeliveryEventually { pump.waitingConsumer })
        reading.cancel()
        guard case .closed = await reading.value else { Issue.record("Cancelled consumer remained open"); return }
        let producer = pump.cancel(); await producer?.value
        #expect(!pump.waitingConsumer && pump.pendingFrames == 0)
        source.finish()
    }

    @Test func arrivalRacingCancellationCannotStrandEitherContinuation() async throws {
        for _ in 0..<32 {
            let (frames, source) = AsyncThrowingStream<String, Error>.makeStream()
            let pump = DistributedHTTPFramePump(frames, maximumFrameBytes: 1024)
            let reading = Task { await pump.next(until: ContinuousClock.now.advanced(by: .seconds(10))) }
            #expect(try await httpDeliveryEventually { pump.waitingConsumer })
            let sending = Task { source.yield("raced"); source.finish() }
            let cancelling = Task { pump.cancel() }
            let value = await reading.value
            switch value {
            case .item(.frame("raced")), .closed: break
            default: Issue.record("Unexpected arrival/cancel outcome")
            }
            await sending.value
            let producer = await cancelling.value; await producer?.value
            #expect(!pump.waitingConsumer && pump.pendingFrames == 0)
        }
    }

    @Test func concurrentConsumersCannotAllocateAnotherWaiterOrStealItsFrame() async throws {
        let (frames, source) = AsyncThrowingStream<String, Error>.makeStream()
        let pump = DistributedHTTPFramePump(frames, maximumFrameBytes: 1024)
        defer { pump.cancel() }
        let first = Task { await pump.next(until: ContinuousClock.now.advanced(by: .seconds(30))) }
        #expect(try await httpDeliveryEventually { pump.waitingConsumer })
        guard case .closed = await pump.next(until: ContinuousClock.now.advanced(by: .seconds(30))) else {
            Issue.record("Concurrent consumer admitted"); return
        }
        #expect(pump.waitingConsumer)
        source.yield("owned")
        guard case .item(.frame("owned")) = await first.value else { Issue.record("Original consumer lost its frame"); return }
        let producer = pump.cancel(); await producer?.value
    }

    @Test func discardedUninvokedBodyReleasesOnlyHTTPHoldAndKeepsLeaseUntilACK() async throws {
        let owner = DistributedTestOwner(), engine = try distributedTestEngine(owner)
        let events = try engine.submit(distributedTestRequest(maxTokens: 5))
        let responses = DistributedHTTPResponses(), response = try responses.begin()
        try response.bind(deadline: nil) { engine.cancel(owner.last.requestID) }
        response.applyPendingCancellation()
        discardBody(response: response, responses: responses)
        #expect(!responses.hasActiveResponse && response.isComplete)
        #expect(owner.last.cancelCount == 1 && owner.last.releaseCount == 0 && response.terminal == nil)
        owner.last.acknowledge()
        _ = await distributedCollect(events)
        #expect(owner.last.releaseCount == 1)
        await engine.shutdown()
    }

    @Test func connectionFinishedBeforeAdmissionRetainsThePendingCancellationHook() async throws {
        let owner = DistributedTestOwner(), engine = try distributedTestEngine(owner)
        let request = distributedTestRequest(maxTokens: 5)
        let responses = DistributedHTTPResponses(), response = try responses.begin()
        try response.bind(deadline: nil) { engine.cancel(request.id) }
        // Full channel close after bind, before reserve has installed the row.
        response.disconnect(); response.finish()
        #expect(!responses.hasActiveResponse && response.isComplete && owner.reserveCount == 0)
        let events = try engine.submit(request)
        response.applyPendingCancellation()
        #expect(owner.last.cancelCount == 1 && owner.last.releaseCount == 0)
        #expect(response.terminal == nil)
        owner.last.acknowledge(); _ = await distributedCollect(events)
        #expect(owner.last.releaseCount == 1)
        await engine.shutdown()
    }

    private func discardBody(response: DistributedHTTPResponse, responses: DistributedHTTPResponses) {
        let stream = AsyncThrowingStream<String, Error> { $0.finish() }
        let body = DistributedHTTPEventStream.response(stream, control: response)
        withExtendedLifetime(body) { #expect(responses.hasActiveResponse && !response.isComplete) }
        // Deliberately never invoke body.write: its captured lifetime guard owns
        // the response hold until this last body value is discarded.
    }
}
