import Foundation
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite(.timeLimit(.minutes(1)))
struct DistributedHTTPVisibleContentTests {
    @Test func roleEmptyAndReasoningFramesDoNotSatisfyVisibleContent() async throws {
        for frame in [try httpDeliveryFrame(role: "assistant"), try httpDeliveryFrame(content: ""),
                      try httpDeliveryFrame(reasoning: "reasoning fixture")] {
            #expect(try !DistributedHTTPEventStream.isVisibleContent(frame))
            let capture = HTTPDeliveryCapture(), control = DistributedHTTPResponse()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            try control.bind(deadline: deadline, cancel: capture.cancel)
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            let response = DistributedHTTPEventStream.response(stream, control: control)
            let writing = Task { try await response.body.write(HTTPDeliveryWriter(capture: capture)) }
            continuation.yield(frame)
            #expect(try await httpDeliveryEventually { capture.values.count == 1 })
            control.expire(at: deadline)
            #expect(capture.cancelCount == 1 && control.terminal == nil)
            #expect(capture.values.count == 1 && capture.finishCount == 0)
            // This fabricated terminal stands for the independent engine ACK;
            // neither expiry nor the writer created this usage.
            control.recordTerminal(.init(promptTokens: 3, completionTokens: 1, cause: .cancelled))
            continuation.finish(throwing: CancellationError())
            try await writing.value
            #expect(capture.values.count == 3 && capture.values[1].contains("deadline_unreachable"))
            #expect(capture.values[1].contains("attempt_usage") && capture.values[2] == ServerSentEventEncoder.done)
            #expect(!capture.values[1].contains("reasoning fixture") && capture.finishCount == 1)
        }
    }

    @Test func acceptanceEqualityLosesAndEarlierAcceptanceDisarmsOnlyContentTimer() throws {
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        let capture = HTTPDeliveryCapture(), late = DistributedHTTPResponse(), timely = DistributedHTTPResponse()
        defer { late.finish(); timely.finish() }
        try late.bind(deadline: end, cancel: capture.cancel)
        #expect(!late.contentAccepted(at: end))
        #expect(late.deadlineExpired && capture.cancelCount == 1)
        try timely.bind(deadline: end, cancel: capture.cancel)
        #expect(timely.contentAccepted(at: end.advanced(by: .nanoseconds(-1))))
        timely.expire(at: end.advanced(by: .seconds(1)))
        #expect(!timely.deadlineExpired && capture.cancelCount == 1)
        #expect(timely.terminal == nil) // no fabricated generation completion
    }

    @Test func writerAcceptanceCrossingDeadlineCannotBecomeSuccess() async throws {
        let capture = HTTPDeliveryCapture(), entered = HTTPDeliveryCapture(), release = LocalHostLatch()
        defer { release.complete() }
        let control = DistributedHTTPResponse(), end = ContinuousClock.now.advanced(by: .seconds(20))
        try control.bind(deadline: end, cancel: capture.cancel)
        let frame = try httpDeliveryFrame(content: "late fixture")
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let response = DistributedHTTPEventStream.response(stream, control: control)
        let writing = Task {
            try await response.body.write(HTTPDeliveryWriter(capture: capture, beforeWrite: { value in
                if value == frame { entered.cancel(); await release.wait() }
            }))
        }
        continuation.yield(frame)
        #expect(try await httpDeliveryEventually { entered.cancelCount == 1 })
        control.expire(at: end)
        #expect(capture.cancelCount == 1 && capture.values.isEmpty)
        control.recordTerminal(.init(promptTokens: 3, completionTokens: 1, cause: .cancelled))
        continuation.finish(throwing: CancellationError())
        release.complete()
        try await writing.value
        #expect(control.deadlineExpired)
        #expect(capture.values[0] == frame) // cannot retract a write already in flight
        #expect(capture.values[1].contains("deadline_unreachable"))
    }

    @Test func expiredOrRepeatedBindingNeverRefreshesBudget() throws {
        let control = DistributedHTTPResponse(), capture = HTTPDeliveryCapture()
        defer { control.finish() }
        #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            try control.bind(deadline: ContinuousClock.now.advanced(by: .seconds(-1)), cancel: capture.cancel)
        }
        #expect(throws: CancellationError.self) {
            try control.bind(deadline: ContinuousClock.now.advanced(by: .seconds(30)), cancel: capture.cancel)
        }
        control.applyPendingCancellation()
        #expect(capture.cancelCount == 1 && control.deadlineExpired)
    }

    @Test func missingTerminalNeverProducesUsageAndNativeFailureWinsOverVisibleExpiry() throws {
        let control = DistributedHTTPResponse()
        defer { control.finish() }
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        try control.bind(deadline: end, cancel: {})
        control.expire(at: end)
        #expect(throws: DistributedHTTPEventStream.Failure.missingTerminal) {
            _ = try DistributedHTTPEventStream.failureFrame(for: control, upstreamFailed: true)
        }
        control.recordTerminal(.init(promptTokens: 3, completionTokens: 0, cause: .prefillStall))
        let candidate = try DistributedHTTPEventStream.failureFrame(for: control, upstreamFailed: true)
        let frame = try #require(candidate)
        #expect(frame.contains("prefill_stall") && !frame.contains("deadline_unreachable"))
    }
}
