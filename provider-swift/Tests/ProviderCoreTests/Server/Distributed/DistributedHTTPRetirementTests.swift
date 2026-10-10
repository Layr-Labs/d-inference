import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite(.timeLimit(.minutes(1)))
struct DistributedHTTPRetirementTests {
    @Test func blockedWriterCannotHoldDeadlineCancellationOrActualLeaseRetirement() async throws {
        let owner = DistributedTestOwner(), engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest(maxTokens: 5))
        let capture = HTTPDeliveryCapture(), entered = HTTPDeliveryCapture(), release = LocalHostLatch()
        defer { release.complete() }
        let control = DistributedHTTPResponse(), deadline = ContinuousClock.now.advanced(by: .seconds(20))
        try control.bind(deadline: deadline) { engine.cancel(owner.last.requestID); capture.cancel() }
        let (frames, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let response = DistributedHTTPEventStream.response(frames, control: control)
        let writing = Task {
            try await response.body.write(HTTPDeliveryWriter(capture: capture, beforeWrite: { _ in
                entered.cancel(); await release.wait()
            }))
        }
        let collecting = Task {
            for await event in stream {
                if case .finished(_, let usage) = event {
                    control.recordTerminal(.init(promptTokens: usage.promptTokens,
                        completionTokens: usage.completionTokens, cause: .cancelled))
                    continuation.finish(throwing: CancellationError())
                }
            }
        }
        continuation.yield(try httpDeliveryFrame(role: "assistant"))
        #expect(try await httpDeliveryEventually { entered.cancelCount == 1 })
        #expect(owner.last.send(.token(4))) // raw token does not acknowledge HTTP content
        control.expire(at: deadline)
        #expect(owner.last.cancelCount == 1 && owner.last.releaseCount == 0 && control.terminal == nil)
        owner.last.acknowledge()
        await collecting.value
        #expect(owner.last.releaseCount == 1 && control.terminal?.completionTokens == 1)
        #expect(capture.values.isEmpty && capture.finishCount == 0)
        release.complete()
        try await writing.value
        #expect(capture.values.joined().contains("deadline_unreachable"))
        await engine.shutdown()
    }

    @Test func disconnectCancelsButDoesNotInventRetirementOrUsage() async throws {
        let owner = DistributedTestOwner(), engine = try distributedTestEngine(owner)
        let stream = try engine.submit(distributedTestRequest(maxTokens: 5))
        let control = DistributedHTTPResponse(), capture = HTTPDeliveryCapture()
        try control.bind(deadline: ContinuousClock.now.advanced(by: .seconds(20))) { engine.cancel(owner.last.requestID) }
        let (frames, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let response = DistributedHTTPEventStream.response(frames, control: control)
        let writing = Task {
            try await response.body.write(HTTPDeliveryWriter(capture: capture, beforeWrite: { _ in
                throw CancellationError()
            }))
        }
        continuation.yield(try httpDeliveryFrame(role: "assistant"))
        do { try await writing.value; Issue.record("Disconnected writer succeeded") } catch {}
        #expect(owner.last.cancelCount == 1 && owner.last.releaseCount == 0 && control.terminal == nil)
        #expect(capture.values.isEmpty && capture.finishCount == 0)
        owner.last.acknowledge(); _ = await distributedCollect(stream)
        #expect(owner.last.releaseCount == 1)
        await engine.shutdown()
    }

    @Test func bridgeBindsActualTokenCountBeforeReserveAndCarriesOnlyActualTerminalUsage() async throws {
        let owner = DistributedTestOwner(), control = DistributedHTTPResponse()
        defer { control.finish() }
        let policy = try DistributedFirstTokenBudgetPolicy(baseMilliseconds: 10_000, millisecondsPerInputToken: 100)
        let bridge = try DistributedEngineFactory.makeBridge(owner: owner, expectedIdentity: owner.identity,
            profile: distributedTestProfile(), tokenizer: TokenizerHandle(DistributedTestTokenizer()),
            eosTokenIDs: [99], firstTokenBudgetPolicy: policy)
        let origin = ContinuousClock.now.advanced(by: .seconds(-1))
        let expected = origin.advanced(by: .milliseconds(10_300))
        owner.onReserve = { #expect(control.selectedDeadline == expected) }
        let stream = try await DistributedHTTPResponseScope.$current.withValue(control) {
            try await bridge.submitTokenized(promptTokens: [1, 2, 3],
                request: ChatCompletionRequest(model: owner.identity.modelID, messages: [], temperature: 0, max_tokens: 5),
                requestId: "http-deadline-fixture", cacheEnabled: false,
                firstContentDeadline: nil, distributedRequestOrigin: origin)
        }
        #expect(control.selectedDeadline == expected && owner.reserveCount == 1)
        #expect(owner.last.send(.token(4)))
        control.expire(at: expected)
        #expect(try await httpDeliveryEventually { owner.last.cancelCount == 1 })
        #expect(control.terminal == nil && owner.last.releaseCount == 0)
        owner.last.acknowledge()
        for await _ in stream {}
        #expect(control.terminal?.completionTokens == 1 && control.terminal?.cause == .cancelled)
        #expect(owner.last.releaseCount == 1)
        await bridge.shutdown()
    }

    @Test func delayedAdmissionConsumesBoundDeadlineAndPendingCancelIsReapplied() async throws {
        let owner = DistributedTestOwner(), control = DistributedHTTPResponse()
        defer { control.finish() }
        let bridge = try DistributedEngineFactory.makeBridge(owner: owner, expectedIdentity: owner.identity,
            profile: distributedTestProfile(), tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99],
            firstTokenBudgetPolicy: .init(baseMilliseconds: 10_000, millisecondsPerInputToken: 0))
        owner.onReserve = { control.expire(at: control.selectedDeadline!) }
        let stream = await DistributedHTTPResponseScope.$current.withValue(control) {
            await bridge.submitTokenized(promptTokens: [1, 2, 3],
                request: ChatCompletionRequest(model: owner.identity.modelID, messages: [], temperature: 0, max_tokens: 5),
                requestId: "http-reserve-race", cacheEnabled: false)
        }
        #expect(try await httpDeliveryEventually { owner.last.cancelCount == 1 })
        #expect(control.deadlineExpired && control.terminal == nil && owner.last.releaseCount == 0)
        owner.last.acknowledge(); for await _ in stream {}
        #expect(control.terminal != nil && owner.last.releaseCount == 1)
        await bridge.shutdown()
    }
}
