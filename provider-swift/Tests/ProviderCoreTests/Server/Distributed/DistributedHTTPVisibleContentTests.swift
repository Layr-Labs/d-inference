import Foundation
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite(.timeLimit(.minutes(1)))
struct DistributedHTTPVisibleContentTests {
    @Test func roleAndEmptyFramesDoNotSatisfyVisibleContent() async throws {
        for frame in [try httpDeliveryFrame(role: "assistant"), try httpDeliveryFrame(content: ""),
                      try httpDeliveryFrame(reasoning: "")] {
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
            // The product's failure-frame shape with the cluster's cause; like
            // the product's, nothing follows it.
            #expect(capture.values.count == 2 && capture.values[1].contains("deadline_unreachable"))
            #expect(capture.values[1].contains("attempt_usage") && capture.values[1].contains("\"finish_reason\":\"error\""))
            #expect(capture.values[1].contains("\"id\":\"fixture\"") && capture.values[1].contains("\"model\":\"fixture\""))
            #expect(capture.finishCount == 1)
        }
    }

    /// The product's rule (`ProviderLoop.hasVisibleStreamOutput`): content,
    /// reasoning content and tool calls are all visible output.
    @Test func reasoningAndToolCallFramesAreVisibleOutputLikeTheProduct() throws {
        #expect(try DistributedHTTPEventStream.isVisibleContent(httpDeliveryFrame(content: "text")))
        #expect(try DistributedHTTPEventStream.isVisibleContent(httpDeliveryFrame(reasoning: "thinking")))
        #expect(try DistributedHTTPEventStream.isVisibleContent(httpDeliveryToolCallFrame()))
    }

    /// A streamed tool call: the tool-call tokens are withheld until the call
    /// parses, so no content frame precedes it. The first committed token met
    /// the first-content budget; the stream ends with the finish frame
    /// (`finish_reason: "tool_calls"`) and [DONE], not an error frame.
    @Test func streamedToolCallEndsWithToolCallsFinish() async throws {
        for tokenSignal in [true, false] {
            let capture = HTTPDeliveryCapture(), control = DistributedHTTPResponse()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
            try control.bind(deadline: deadline, cancel: capture.cancel)
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            let response = DistributedHTTPEventStream.response(stream, control: control)
            let writing = Task { try await response.body.write(HTTPDeliveryWriter(capture: capture)) }
            continuation.yield(try httpDeliveryFrame(role: "assistant"))
            if tokenSignal {
                control.firstTokenCommitted()
                // The call parses after the first-content budget has passed.
                try await Task.sleep(for: .milliseconds(400))
                control.expire(at: ContinuousClock.now)
            }
            continuation.yield(try httpDeliveryToolCallFrame())
            continuation.yield(try httpDeliveryFrame(finish: "tool_calls"))
            continuation.yield(ServerSentEventEncoder.done)
            control.recordTerminal(.init(promptTokens: 3, completionTokens: 9, cause: nil))
            continuation.finish()
            try await writing.value
            #expect(capture.cancelCount == 0 && !control.deadlineExpired)
            #expect(!capture.values.contains { $0.contains("\"error\"") })
            #expect(capture.values.contains { $0.contains("\"tool_calls\":[") })
            #expect(capture.values.contains { $0.contains("\"finish_reason\":\"tool_calls\"") })
            #expect(capture.values.last == ServerSentEventEncoder.done && capture.finishCount == 1)
        }
    }

    /// A thinking stream: reasoning frames, then content, ends normally.
    @Test func reasoningOnlyStreamIsNotAnErrorFrame() async throws {
        let capture = HTTPDeliveryCapture(), control = DistributedHTTPResponse()
        try control.bind(deadline: ContinuousClock.now.advanced(by: .seconds(10)), cancel: capture.cancel)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let response = DistributedHTTPEventStream.response(stream, control: control)
        let writing = Task { try await response.body.write(HTTPDeliveryWriter(capture: capture)) }
        continuation.yield(try httpDeliveryFrame(reasoning: "considering"))
        continuation.yield(try httpDeliveryFrame(finish: "length"))
        continuation.yield(ServerSentEventEncoder.done)
        control.recordTerminal(.init(promptTokens: 3, completionTokens: 4, cause: nil))
        continuation.finish()
        try await writing.value
        #expect(!capture.values.contains { $0.contains("\"error\"") })
        #expect(capture.values.first?.contains("considering") == true)
        #expect(capture.values.contains { $0.contains("\"finish_reason\":\"length\"") })
    }

    @Test func firstCommittedTokenDisarmsTheContentBudgetOnly() throws {
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        let capture = HTTPDeliveryCapture(), control = DistributedHTTPResponse()
        defer { control.finish() }
        try control.bind(deadline: end, cancel: capture.cancel)
        control.firstTokenCommitted(at: end.advanced(by: .seconds(-1)))
        control.expire(at: end.advanced(by: .seconds(1)))
        #expect(!control.deadlineExpired && capture.cancelCount == 0 && !control.contentMissingAtTerminal)
        // A first token after the budget does not revive it.
        let late = DistributedHTTPResponse()
        defer { late.finish() }
        try late.bind(deadline: end, cancel: capture.cancel)
        late.firstTokenCommitted(at: end)
        #expect(late.deadlineExpired && capture.cancelCount == 1)
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
