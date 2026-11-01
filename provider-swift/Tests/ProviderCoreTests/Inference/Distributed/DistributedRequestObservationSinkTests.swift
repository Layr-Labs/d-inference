import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

private final class BlockedObservation: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocked = false
    var isBlocked: Bool { lock.withLock { blocked } }
    private var records: [DistributedRequestObservation] = []
    var values: [DistributedRequestObservation] { lock.withLock { records } }

    func receive(_ observation: DistributedRequestObservation) {
        let first = lock.withLock { records.append(observation); return records.count == 1 }
        if first {
            lock.withLock { blocked = true }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
            lock.withLock { blocked = false }
        }
    }

    func waitForCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while values.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return values.count >= count
    }
}

private func observationWait(_ signal: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: signal.wait(timeout: .now() + 3) == .success)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DistributedRequestObservationSinkTests {
    @Test func blockedCallbackCannotDelayDeadlineCancellationOrActualRetirement() async throws {
        let owner = DistributedTestOwner(), clock = DistributedTestClock(), blocked = BlockedObservation()
        defer { blocked.release.signal() }
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity,
            profile: distributedTestProfile(), detokenizers: DistributedTestDetokenizers(), clock: clock.clock,
            requestObserver: blocked.receive)
        let stream = try engine.submit(distributedTestRequest(), deadlineContext: .init(
            generationDeadline: clock.now.advanced(by: .seconds(30)),
            firstTokenDeadline: clock.now.advanced(by: .seconds(3))))
        #expect(await observationWait(blocked.entered))
        #expect(blocked.isBlocked)
        clock.advance(.seconds(4))
        engine.onQueue { engine.checkDeadline(engine.active!) }
        #expect(owner.last.cancelCount == 1 && owner.last.releaseCount == 0)
        #expect(blocked.values.count == 1)
        // No callback progress is permitted yet. Actual lease acknowledgement,
        // resource release, stream completion and shutdown must still finish.
        owner.last.acknowledge()
        _ = await distributedCollect(stream)
        await engine.shutdown()
        #expect(owner.last.releaseCount == 1 && blocked.values.count == 1 && blocked.isBlocked)
        #expect(engine.observationSink?.pendingCount == 2)
        blocked.release.signal()
        #expect(await blocked.waitForCount(3))
        #expect(blocked.values.map(\.phase) == [.reserved, .terminal, .retired])
        #expect(blocked.values.last?.outcome == "prefill_stall")
        #expect(blocked.values.allSatisfy { $0.droppedObservations == 0 })
    }

    @Test func overflowIsBoundedAndCumulativeLossAppearsOnDeliveredValues() async throws {
        let owner = DistributedTestOwner(), clock = DistributedTestClock(), blocked = BlockedObservation()
        defer { blocked.release.signal() }
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity,
            profile: distributedTestProfile(), detokenizers: DistributedTestDetokenizers(), clock: clock.clock,
            requestObserver: blocked.receive)
        let stream = try engine.submit(distributedTestRequest())
        #expect(await observationWait(blocked.entered))
        #expect(blocked.isBlocked)
        let sink = try #require(engine.observationSink)
        let value = try #require(blocked.values.first)
        for _ in 0..<70 { sink.enqueue(value) }
        #expect(sink.pendingCount == 64 && sink.droppedCount == 6)
        engine.cancel(distributedTestRequest().id)
        owner.last.acknowledge()
        _ = await distributedCollect(stream)
        await engine.shutdown()
        // Terminal and retirement observations also obey the same bound.
        #expect(sink.pendingCount == 64 && sink.droppedCount == 8)
        #expect(blocked.values.count == 1 && owner.last.releaseCount == 1 && blocked.isBlocked)
        blocked.release.signal()
        #expect(await blocked.waitForCount(65))
        #expect(blocked.values.count == 65 && sink.pendingCount == 0)
        #expect(blocked.values.first?.droppedObservations == 0)
        #expect(blocked.values.dropFirst().allSatisfy { $0.droppedObservations == 8 })
    }
}
