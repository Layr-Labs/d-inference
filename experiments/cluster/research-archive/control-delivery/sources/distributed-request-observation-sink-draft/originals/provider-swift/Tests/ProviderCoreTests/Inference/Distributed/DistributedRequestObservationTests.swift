import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

private final class DistributedObservationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [DistributedRequestObservation] = []
    var values: [DistributedRequestObservation] { lock.withLock { observations } }
    func record(_ value: DistributedRequestObservation) { lock.withLock { observations.append(value) } }
}

@Suite(.timeLimit(.minutes(1)))
struct DistributedRequestObservationTests {
    private func engine(_ owner: DistributedTestOwner, _ clock: DistributedTestClock,
                        _ capture: DistributedObservationCapture) throws -> DistributedCBv2Engine {
        try .init(owner: owner, expectedIdentity: owner.identity, profile: distributedTestProfile(),
                  detokenizers: DistributedTestDetokenizers(), clock: clock.clock,
                  requestObserver: capture.record)
    }

    @Test func successfulObservationSeparatesReservationAndTokenTime() async throws {
        let owner = DistributedTestOwner(), clock = DistributedTestClock(), capture = DistributedObservationCapture()
        let engine = try engine(owner, clock, capture)
        owner.onReserve = { clock.advance(.milliseconds(250)) }
        let origin = clock.now
        let stream = try engine.submit(distributedTestRequest(), deadlineContext: .init(
            generationDeadline: origin.advanced(by: .seconds(30)),
            firstTokenDeadline: origin.advanced(by: .seconds(10))))
        clock.advance(.seconds(2))
        #expect(owner.last.send(.token(4)))
        clock.advance(.milliseconds(50))
        #expect(!owner.last.send(.token(5)))
        #expect(capture.values.map(\.phase) == [.reserved, .firstToken, .terminal])
        #expect(owner.last.releaseCount == 0)
        owner.last.acknowledge()
        _ = await distributedCollect(stream)
        await engine.shutdown()
        let values = capture.values
        #expect(values.map(\.phase) == [.reserved, .firstToken, .terminal, .retired])
        #expect(Set(values.map(\.generation)).count == 1)
        #expect(values.allSatisfy { $0.reservationMilliseconds == 250 && $0.promptTokens == 3 })
        #expect(values[0].admissionElapsedMilliseconds == 250)
        #expect(values[1].admissionElapsedMilliseconds == 2_250)
        #expect(values[1].remainingFirstTokenMilliseconds == 7_750)
        #expect(values[1].completionTokens == 1)
        #expect(values[2].outcome == "length" && values[3].outcome == "length")
        #expect(owner.last.releaseCount == 1)
    }

    @Test func deadlineCauseSurvivesPeerLossAndRetirementIsNotInvented() async throws {
        let owner = DistributedTestOwner(), clock = DistributedTestClock(), capture = DistributedObservationCapture()
        let engine = try engine(owner, clock, capture)
        let stream = try engine.submit(distributedTestRequest(), deadlineContext: .init(
            generationDeadline: clock.now.advanced(by: .seconds(30)),
            firstTokenDeadline: clock.now.advanced(by: .seconds(3))))
        clock.advance(.seconds(4))
        engine.onQueue { engine.checkDeadline(engine.active!) }
        owner.losePeer()
        #expect(capture.values.map(\.phase) == [.reserved, .terminal])
        let terminal = try #require(capture.values.last)
        #expect(terminal.outcome == "prefill_stall" && terminal.completionTokens == 0)
        #expect(terminal.remainingFirstTokenMilliseconds == -1_000)
        #expect(owner.last.cancelCount == 1 && owner.last.releaseCount == 0)
        owner.last.acknowledge()
        _ = await distributedCollect(stream)
        await engine.shutdown()
        #expect(capture.values.map(\.phase) == [.reserved, .terminal, .retired])
        #expect(capture.values.last?.outcome == "prefill_stall")
        #expect(owner.last.releaseCount == 1)
    }

    @Test func outcomesNeverIncludeArbitraryErrorMessages() {
        #expect(DistributedRequestObservation.outcome(.error("private fixture text")) == "engine_error")
        #expect(DistributedRequestObservation.outcome(.terminal(cause: .prefillStall,
            message: "private fixture text")) == "prefill_stall")
        #expect(DistributedRequestObservation.outcome(.cancelled) == "cancelled")
    }
}
