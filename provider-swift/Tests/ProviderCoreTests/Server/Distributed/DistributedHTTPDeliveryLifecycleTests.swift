import Foundation
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite(.timeLimit(.minutes(1)))
struct DistributedHTTPDeliveryLifecycleTests {
    @Test func ordinarySuccessfulContentPreservesFrameBytes() async throws {
        let control = DistributedHTTPResponse(), capture = HTTPDeliveryCapture()
        try control.bind(deadline: ContinuousClock.now.advanced(by: .seconds(20)), cancel: capture.cancel)
        control.recordTerminal(.init(promptTokens: 3, completionTokens: 1, cause: nil))
        let values = [try httpDeliveryFrame(role: "assistant"), try httpDeliveryFrame(content: "fixture"),
                      try httpDeliveryFrame(finish: "length"), ServerSentEventEncoder.done]
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for value in values { continuation.yield(value) }; continuation.finish()
        }
        let response = DistributedHTTPEventStream.response(stream, control: control)
        try await response.body.write(HTTPDeliveryWriter(capture: capture))
        #expect(capture.values == values && capture.finishCount == 1 && capture.cancelCount == 0)
        #expect(control.isComplete && !control.deadlineExpired)
    }

    @Test func cleanEmptyCompletionCannotClaimTheExplicitContentPolicy() throws {
        let policy = DistributedHTTPResponse(), legacy = DistributedHTTPResponse()
        defer { policy.finish(); legacy.finish() }
        try policy.bind(deadline: ContinuousClock.now.advanced(by: .seconds(20)), cancel: {})
        try legacy.bind(deadline: nil, cancel: {})
        for response in [policy, legacy] {
            response.recordTerminal(.init(promptTokens: 3, completionTokens: 1, cause: nil))
        }
        #expect(try DistributedHTTPEventStream.failureFrame(for: policy, upstreamFailed: false)?.contains("deadline_unreachable") == true)
        #expect(try DistributedHTTPEventStream.failureFrame(for: legacy, upstreamFailed: false) == nil)
    }

    @Test func deliveryGraceIsOnceBoundAndCannotClearNativeOwnership() async throws {
        let responses = DistributedHTTPResponses(), capture = HTTPDeliveryCapture()
        let response = try responses.begin()
        try response.bind(deadline: nil, cancel: capture.cancel)
        let now = ContinuousClock.now
        responses.beginDeliveryGrace(now: now.advanced(by: .seconds(-4)))
        responses.beginDeliveryGrace(now: now) // cannot replenish the first grace
        let start = ContinuousClock.now
        await responses.waitForDelivery()
        #expect(start.duration(to: ContinuousClock.now) < .seconds(1))
        #expect(responses.hasActiveResponse && response.terminal == nil)
        #expect(throws: MultiModelBatchSchedulerEngineError.self) { _ = try responses.begin() }
        responses.abort()
        #expect(capture.cancelCount == 1 && response.terminal == nil && !response.isComplete)
        responses.listenerStopped()
        #expect(response.isComplete && !responses.hasActiveResponse && response.terminal == nil)
    }

    @Test func full32KOutputReachesTheClientWithoutHittingTheOldByteLimit() async throws {
        let count = 32_768
        let control = DistributedHTTPResponse(), capture = HTTPDeliveryCapture()
        try control.bind(deadline: nil, cancel: capture.cancel)
        control.recordTerminal(.init(promptTokens: 16, completionTokens: count, cause: nil))
        let frame = try ServerSentEventEncoder.encode(OpenAIChatCompletionChunk(
            id: "chatcmpl-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            model: "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp",
            choices: [.init(index: 0, delta: .init(role: nil, content: "",
                reasoningContent: " example", toolCalls: nil), finishReason: nil)],
            usage: nil, created: 1_792_440_000))
        #expect(frame.utf8.count * count > 8_388_608)
        let finish = try httpDeliveryFrame(finish: "length")
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for _ in 0..<count { continuation.yield(frame) }
            continuation.yield(finish); continuation.yield(ServerSentEventEncoder.done)
            continuation.finish()
        }
        try await DistributedHTTPEventStream.response(stream, control: control)
            .body.write(HTTPDeliveryWriter(capture: capture))
        #expect(capture.values.filter { $0 == frame }.count == count)
        #expect(Array(capture.values.suffix(2)) == [finish, ServerSentEventEncoder.done])
        #expect(capture.finishCount == 1 && capture.cancelCount == 0 && control.isComplete)
    }

    @Test func frameAndTotalBoundsCancelWithoutInventingUsage() async throws {
        #expect(throws: DistributedHTTPEventStream.Failure.outputLimit) {
            _ = try DistributedHTTPEventStream.isVisibleContent(String(repeating: "x", count: DistributedHTTPEventStream.maximumFrameBytes + 1))
        }
        let control = DistributedHTTPResponse(), capture = HTTPDeliveryCapture()
        try control.bind(deadline: nil, cancel: capture.cancel)
        let frame = try httpDeliveryFrame(content: String(repeating: "x", count: 1_000_000))
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for _ in 0...(DistributedHTTPEventStream.maximumStreamBytes / frame.utf8.count) { continuation.yield(frame) }; continuation.finish()
        }
        let response = DistributedHTTPEventStream.response(stream, control: control)
        do { try await response.body.write(HTTPDeliveryWriter(capture: capture)); Issue.record("Output limit accepted") }
        catch DistributedHTTPEventStream.Failure.outputLimit {}
        #expect(capture.values.reduce(0) { $0 + $1.utf8.count } < DistributedHTTPEventStream.maximumStreamBytes)
        #expect(capture.cancelCount == 1 && capture.finishCount == 0 && control.terminal == nil)
    }

    @Test func hostClosesAdmissionsBeforeGraceAndRetainsEntryUntilOwnerACK() async throws {
        let session = LocalHostTestSession(); session.holdOwnerACK = true
        let host = localHost(session)
        try await host.start()
        let responses = await host.responses
        let response = try responses.begin()
        let stop = Task { await host.stop(until: localHostDeadline(50)) }
        #expect(try await localHostEventually { session.nativeCleanupObserved })
        #expect(throws: MultiModelBatchSchedulerEngineError.self) { _ = try responses.begin() }
        let bounded = await stop.value
        #expect(bounded.phase == .quarantined && !bounded.cleanupComplete)
        let heldEntry = await host.entry
        #expect(heldEntry != nil && !response.isComplete)
        // Model release and native cleanup are not response completion/owner ACK.
        response.finish()
        let retainedEntry = await host.entry
        #expect(!responses.hasActiveResponse && retainedEntry != nil)
        session.ack.complete()
        #expect(try await localHostEventually { await host.status.cleanupComplete })
    }
}
