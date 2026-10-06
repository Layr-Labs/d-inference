import Foundation
import MLXLMCommon
import MLXLMServer
import XCTest
@testable import ProviderCore

/// Host ownership tests, not SDK/GPU completion or generated-model quality.
/// Barriers hold actual Tasks; no elapsed timeout/count is completion evidence.
final class NativeLocalConsumerOwnershipTests: XCTestCase {
    func testCloseBeforeBindingCannotJoinAnEmptyButArmedHandoff() async throws {
        let lease = NativeLocalConsumerLease(), events = ConsumerEvents()
        XCTAssertEqual(lease.snapshot().phase, .awaitingBinding)
        XCTAssertTrue(lease.snapshot().hasOutstandingHandoff)
        let initialRevision = lease.snapshot().revision
        lease.closeAndCancel()
        let token = OneShotRelease(release: { _ in events.record("release") }, modelId: "native",
                                   nativeConsumerLease: lease)
        XCTAssertTrue(token.nativeBindingAccepted)
        XCTAssertTrue(token.nativeConsumerLease === lease)
        XCTAssertEqual(try lease.abandonUnstartedHandoff(), .boundReleaseRequested)
        XCTAssertEqual(try lease.abandonUnstartedHandoff(), .boundReleaseRequested)
        XCTAssertTrue(lease.snapshot().hasOutstandingHandoff)
        XCTAssertTrue(events.values.isEmpty)
        XCTAssertThrowsError(try lease.startPreparation { 1 }) {
            XCTAssertEqual($0 as? NativeLocalConsumerOwnershipError, .closed)
        }
        // Only Scheduler's actual payload disposal settles this bound handoff.
        try lease.discardUnstartedPreparation()
        await lease.joinFromOutside()
        XCTAssertEqual(events.values, ["release"])
        XCTAssertFalse(lease.snapshot().hasOutstandingHandoff)
        XCTAssertEqual(lease.snapshot().phase, .completed)
        XCTAssertGreaterThan(lease.snapshot().revision, initialRevision)
    }

    func testUnboundColdDisposalCannotBeRevivedByLateBindingOrWork() async throws {
        let lease = NativeLocalConsumerLease(), events = ConsumerEvents()
        lease.closeAndCancel()
        XCTAssertEqual(try lease.abandonUnstartedHandoff(), .unbound)
        XCTAssertEqual(try lease.abandonUnstartedHandoff(), .alreadyAbandoned)
        await lease.joinFromOutside() // NO-WORK disposition only, not SDK proof.
        let token = OneShotRelease(release: { _ in events.record("invalid release") }, modelId: "native",
                                   nativeConsumerLease: lease)
        XCTAssertFalse(token.nativeBindingAccepted)
        await token.fire()
        XCTAssertThrowsError(try lease.startPreparation { 1 }) {
            XCTAssertEqual($0 as? NativeLocalConsumerOwnershipError, .invalidBinding)
        }
        XCTAssertEqual(lease.snapshot().phase, .abandoned)
        XCTAssertFalse(lease.snapshot().hasOutstandingHandoff)
        XCTAssertTrue(events.values.isEmpty)
    }

    func testDuplicateBindingCannotReleaseOrAdoptFirstAcquisition() async throws {
        let lease = NativeLocalConsumerLease(), events = ConsumerEvents()
        let first = OneShotRelease(release: { _ in events.record("first") }, modelId: "a",
                                   nativeConsumerLease: lease)
        let duplicate = OneShotRelease(release: { _ in events.record("duplicate") }, modelId: "b",
                                       nativeConsumerLease: lease)
        XCTAssertTrue(first.nativeBindingAccepted)
        XCTAssertFalse(duplicate.nativeBindingAccepted)
        await duplicate.fire()
        XCTAssertEqual(lease.snapshot().phase, .active)
        XCTAssertTrue(events.values.isEmpty)
        try lease.discardUnstartedPreparation()
        await lease.joinFromOutside()
        await first.fire()
        await duplicate.fire()
        XCTAssertEqual(events.values, ["first"])
    }

    func testFireIsNotSelfJoinAndReleaseWaitsActualPreparationTaskTail() async throws {
        let lease = NativeLocalConsumerLease(), tail = ConsumerBarrier(), events = ConsumerEvents()
        let token = OneShotRelease(release: { _ in events.record("release") }, modelId: "native",
                                   nativeConsumerLease: lease)
        let task: Task<Void, Error> = try lease.startPreparation {
            await token.fire()
            events.record("fire returned")
            await tail.wait() // Actual task stays alive after logical fire.
            events.record("tail returned")
        }
        await tail.waitUntilEntered()
        XCTAssertEqual(events.values, ["fire returned"])
        XCTAssertEqual(lease.snapshot().phase, .closing)
        XCTAssertThrowsError(try lease.abandonUnstartedHandoff())
        await tail.open()
        try await task.value
        await lease.joinFromOutside()
        XCTAssertEqual(events.values, ["fire returned", "tail returned", "release"])
        // A completed task is still not an "unstarted" acquisition.
        XCTAssertThrowsError(try lease.abandonUnstartedHandoff())
    }

    func testParentCancellationCannotSkipRegisteredPreparationCleanup() async throws {
        let lease = NativeLocalConsumerLease(), gate = ConsumerBarrier(), events = ConsumerEvents()
        let parentEntered = ConsumerBarrier()
        let token = OneShotRelease(release: { _ in events.record("release") }, modelId: "native",
                                   nativeConsumerLease: lease)
        let task: Task<Void, Error> = try lease.startPreparation {
            await gate.wait() // deliberately cancellation-insensitive cleanup
            XCTAssertTrue(Task.isCancelled)
            events.record("cleanup")
            await token.fire()
            throw CancellationError()
        }
        let parent = Task {
            try await withTaskCancellationHandler {
                await parentEntered.wait()
                try await task.value
            }
                onCancel: { lease.closeAndCancel() }
        }
        await gate.waitUntilEntered()
        // The child can enter preparation before its parent task has started.
        // Wait until the parent's cancellation handler is installed before
        // asserting the synchronous close caused by parent.cancel().
        await parentEntered.waitUntilEntered()
        parent.cancel()
        XCTAssertTrue(events.values.isEmpty)
        XCTAssertEqual(lease.snapshot().phase, .closing)
        await parentEntered.open()
        await gate.open()
        do { try await parent.value; XCTFail("expected cancellation") } catch is CancellationError {}
        await lease.joinFromOutside()
        XCTAssertEqual(events.values, ["cleanup", "release"])
    }

    func testCloseBeforeForwardingRegistrationRefusesNewConsumer() async throws {
        let lease = NativeLocalConsumerLease(), gate = ConsumerBarrier(), events = ConsumerEvents()
        let token = OneShotRelease(release: { _ in events.record("release") }, modelId: "native",
                                   nativeConsumerLease: lease)
        let prep: Task<Void, Error> = try lease.startPreparation {
            await gate.wait()
            XCTAssertThrowsError(try lease.makeForwardingHandoff(cancel: {}, operation: {
                events.record("escaped")
            })) { XCTAssertEqual($0 as? NativeLocalConsumerOwnershipError, .closed) }
            await token.fire()
        }
        await gate.waitUntilEntered()
        lease.closeAndCancel()
        await gate.open()
        try await prep.value
        await lease.joinFromOutside()
        XCTAssertEqual(events.values, ["release"])
    }

    func testRegisteredForwardingCannotRunBeforeHandoffAndCancellationIsOwnedOnce() async throws {
        let lease = NativeLocalConsumerLease(), cleanup = ConsumerBarrier(), events = ConsumerEvents()
        let token = OneShotRelease(release: { _ in events.record("release") }, modelId: "native",
                                   nativeConsumerLease: lease)
        let prep = try lease.startPreparation { 0 }
        _ = try await prep.value
        let handoff = try lease.makeForwardingHandoff(cancel: {
            events.record("cancel entered")
            await cleanup.wait()
            events.record("cancel returned")
        }, operation: {
            XCTAssertTrue(Task.isCancelled)
            events.record("forward returned")
            await token.fire()
        })
        XCTAssertTrue(events.values.isEmpty) // handle installed, body gated
        lease.closeAndCancel()
        handoff.cancel()
        handoff.terminate()
        handoff.terminate()
        await cleanup.waitUntilEntered()
        XCTAssertEqual(events.values, ["cancel entered"])
        handoff.activate()
        await handoff.task.value
        XCTAssertEqual(events.values, ["cancel entered", "forward returned"])
        XCTAssertEqual(lease.snapshot().phase, .closing)
        await cleanup.open()
        await lease.joinFromOutside()
        XCTAssertEqual(events.values, ["cancel entered", "forward returned", "cancel returned", "release"])
    }

    func testCompletedForwarderCannotEraseUnsettledTerminationHandoff() async throws {
        let lease = NativeLocalConsumerLease(), events = ConsumerEvents()
        let token = OneShotRelease(release: { _ in events.record("release") }, modelId: "native",
                                   nativeConsumerLease: lease)
        let prep = try lease.startPreparation { 0 }
        _ = try await prep.value
        let handoff = try lease.makeForwardingHandoff(cancel: { events.record("cancel") }, operation: {
            await token.fire()
        })
        handoff.activate()
        await handoff.task.value
        XCTAssertTrue(lease.snapshot().hasOutstandingHandoff)
        XCTAssertTrue(events.values.isEmpty)
        handoff.terminate()
        await lease.joinFromOutside()
        XCTAssertEqual(events.values, ["cancel", "release"])
    }

    func testExternalJoinIncludesRealReleaseCallbackTail() async throws {
        let lease = NativeLocalConsumerLease(), releaseTail = ConsumerBarrier(), events = ConsumerEvents()
        let token = OneShotRelease(release: { _ in
            events.record("release entered")
            await releaseTail.wait()
            events.record("release returned")
        }, modelId: "native", nativeConsumerLease: lease)
        let task: Task<Void, Error> = try lease.startPreparation { await token.fire() }
        try await task.value
        await releaseTail.waitUntilEntered()
        XCTAssertEqual(lease.snapshot().phase, .releasing)
        XCTAssertEqual(events.values, ["release entered"])
        let joiner = Task {
            await lease.joinFromOutside()
            XCTAssertEqual(lease.snapshot().phase, .completed)
            events.record("joined")
        }
        await releaseTail.open()
        await joiner.value
        XCTAssertEqual(events.values, ["release entered", "release returned", "joined"])
        XCTAssertEqual(lease.snapshot().phase, .completed)
    }

    func testActualAtomicAcquisitionCancellationBeforeReturnNeverSubmits() async throws {
        let fixture = ConsumerSchedulerFixture(), lease = NativeLocalConsumerLease()
        let gate = ConsumerBarrier(), events = ConsumerEvents()
        let token = OneShotRelease(release: { _ in events.record("release") }, modelId: "fixture",
                                   nativeConsumerLease: lease)
        let scheduler = MultiModelBatchSchedulerEngine(acquire: { _ in
            await gate.wait() // stand-in for the async actor-return interval
            return fixture.acquired(token)
        }, tokenizerProvider: { _ in .init(tokenizer: fixture.tokenizer, modelType: nil) },
        availableModels: { ["fixture"] })
        let submission = Task { try await scheduler.streamChatCompletion(request: fixture.request) }
        await gate.waitUntilEntered()
        submission.cancel()
        XCTAssertTrue(lease.snapshot().hasOutstandingHandoff)
        XCTAssertTrue(events.values.isEmpty)
        await gate.open()
        do { _ = try await submission.value; XCTFail("expected cancellation") } catch is CancellationError {}
        await lease.joinFromOutside()
        XCTAssertEqual(fixture.engine.submissions, 0)
        XCTAssertEqual(fixture.preparations.values, [])
        XCTAssertEqual(events.values, ["release"])
    }

    func testLegacyFactoryCloseAfterPublicationBeforeBindingDoesNotLoseHandoff() async throws {
        let fixture = ConsumerSchedulerFixture(), lease = NativeLocalConsumerLease()
        let returnBoundary = ConsumerBarrier(), events = ConsumerEvents()
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { ["fixture": fixture.entry] },
            reserveModel: { _ in events.record("reserve") }, releaseModel: { _ in events.record("release") },
            nativeConsumerLeaseProvider: { id, entry in
                XCTAssertEqual(id, "fixture")
                XCTAssertTrue(entry.engineV2Bridge === fixture.bridge)
                // Test-only barrier models the scheduling gap AFTER a real
                // owner's nonsuspending create/store/return actor segment.
                await returnBoundary.wait()
                return lease
            })
        let submission = Task { try await scheduler.streamChatCompletion(request: fixture.request) }
        await returnBoundary.waitUntilEntered()
        lease.closeAndCancel()
        XCTAssertTrue(lease.snapshot().hasOutstandingHandoff)
        XCTAssertEqual(events.values, ["reserve"])
        await returnBoundary.open()
        do { _ = try await submission.value; XCTFail("expected closed refusal") }
        catch let error as NativeLocalConsumerOwnershipError { XCTAssertEqual(error, .closed) }
        await lease.joinFromOutside()
        XCTAssertEqual(events.values, ["reserve", "release"])
        XCTAssertEqual(fixture.engine.submissions, 0)
        XCTAssertTrue(fixture.preparations.values.isEmpty)
    }

    func testLegacyFactoryFailureBeforePublicationUnwindsOriginalReservationOnce() async throws {
        let fixture = ConsumerSchedulerFixture(), validation = ConsumerBarrier(), events = ConsumerEvents()
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { ["fixture": fixture.entry] },
            reserveModel: { _ in events.record("reserve") }, releaseModel: { _ in events.record("release") },
            nativeConsumerLeaseProvider: { _, _ in
                await validation.wait()
                try Task.checkCancellation() // no lease was published
                throw ConsumerFixtureError.refused
            })
        let submission = Task { try await scheduler.streamChatCompletion(request: fixture.request) }
        await validation.waitUntilEntered()
        submission.cancel()
        await validation.open()
        do { _ = try await submission.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(events.values, ["reserve", "release"])
        XCTAssertEqual(fixture.engine.submissions, 0)
    }

    func testOwnerColdUnwindBeforeLateLegacyBindingDoesNotReleaseTwice() async throws {
        let fixture = ConsumerSchedulerFixture(), lease = NativeLocalConsumerLease()
        let returnBoundary = ConsumerBarrier(), events = ConsumerEvents()
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { ["fixture": fixture.entry] },
            reserveModel: { _ in events.record("reserve") }, releaseModel: { _ in events.record("scheduler release") },
            nativeConsumerLeaseProvider: { _, _ in await returnBoundary.wait(); return lease })
        let submission = Task { try await scheduler.streamChatCompletion(request: fixture.request) }
        await returnBoundary.waitUntilEntered()
        lease.closeAndCancel()
        XCTAssertEqual(try lease.abandonUnstartedHandoff(), .unbound)
        events.record("exact owner cold unwind") // same reservation, not a second lease
        XCTAssertEqual(try lease.abandonUnstartedHandoff(), .alreadyAbandoned)
        await returnBoundary.open()
        do { _ = try await submission.value; XCTFail("expected rejected late binding") }
        catch let error as NativeLocalConsumerOwnershipError { XCTAssertEqual(error, .invalidBinding) }
        XCTAssertEqual(events.values, ["reserve", "exact owner cold unwind"])
        XCTAssertEqual(fixture.engine.submissions, 0)
        XCTAssertEqual(lease.snapshot().phase, .abandoned)
    }

    func testCancellationAcrossLegacyAcquisitionAwaitsPreservesReservationUnwind() async throws {
        for boundary in ["ensure", "registry", "reserve", "factory"] {
            let fixture = ConsumerSchedulerFixture(), gate = ConsumerBarrier(), events = ConsumerEvents()
            let lease = NativeLocalConsumerLease()
            let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
                if boundary == "registry" { await gate.wait() }
                return ["fixture": fixture.entry]
            }, ensureLoaded: { _ in
                if boundary == "ensure" { await gate.wait() }
            }, reserveModel: { _ in
                events.record("reserve")
                if boundary == "reserve" { await gate.wait() }
            }, releaseModel: { _ in events.record("release") }, nativeConsumerLeaseProvider: { _, _ in
                if boundary == "factory" { await gate.wait() }
                return lease
            })
            let submission = Task { try await scheduler.streamChatCompletion(request: fixture.request) }
            await gate.waitUntilEntered()
            submission.cancel()
            await gate.open()
            do { _ = try await submission.value; XCTFail("expected cancellation at \(boundary)") }
            catch is CancellationError {}
            if boundary == "ensure" || boundary == "registry" {
                XCTAssertTrue(events.values.isEmpty, boundary)
                XCTAssertEqual(lease.snapshot().phase, .awaitingBinding)
                // This test created a candidate lease, but the actual factory
                // was never reached; dispose that test-only unused candidate.
                XCTAssertEqual(try lease.abandonUnstartedHandoff(), .unbound)
            } else {
                await lease.joinFromOutside()
                XCTAssertEqual(events.values, ["reserve", "release"], boundary)
                XCTAssertEqual(lease.snapshot().phase, .completed)
            }
            XCTAssertEqual(fixture.engine.submissions, 0, boundary)
            XCTAssertTrue(fixture.preparations.values.isEmpty, boundary)
        }
    }

    func testNonCancellationValidationRefusalBeforeLeasePublicationUnwindsOnce() async throws {
        let fixture = ConsumerSchedulerFixture(), events = ConsumerEvents()
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { ["fixture": fixture.entry] },
            reserveModel: { _ in events.record("reserve") }, releaseModel: { _ in events.record("release") },
            nativeConsumerLeaseProvider: { _, _ in throw ConsumerFixtureError.refused })
        do { _ = try await scheduler.streamChatCompletion(request: fixture.request); XCTFail("expected refusal") }
        catch ConsumerFixtureError.refused {}
        XCTAssertEqual(events.values, ["reserve", "release"])
        XCTAssertEqual(fixture.engine.submissions, 0)
    }

    func testActualSchedulerCloseCancelsOwnedForwardingAndUpstreamBeforeRelease() async throws {
        let fixture = ConsumerSchedulerFixture(holdOpen: true), lease = NativeLocalConsumerLease()
        let events = ConsumerEvents()
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { ["fixture": fixture.entry] },
            releaseModel: { _ in
                XCTAssertEqual(fixture.engine.pendingCount, 0)
                events.record("release")
            }, nativeConsumerLeaseProvider: { _, _ in lease })
        let stream = try await scheduler.streamChatCompletion(request: fixture.request)
        XCTAssertEqual(fixture.engine.submissions, 1)
        XCTAssertEqual(fixture.engine.pendingCount, 1)
        let reader = Task { for try await _ in stream {} }
        lease.closeAndCancel()
        lease.closeAndCancel()
        await lease.joinFromOutside()
        _ = await reader.result
        XCTAssertEqual(events.values, ["release"])
        XCTAssertEqual(fixture.engine.pendingCount, 0)
        XCTAssertEqual(fixture.engine.cancelledRows, 1)
        XCTAssertEqual(lease.snapshot().phase, .completed)
    }

    func testActualSchedulerNativeAndNilPathsKeepIdenticalVisibleEvents() async throws {
        var outputs: [[String]] = []
        for native in [false, true] {
            let fixture = ConsumerSchedulerFixture(), events = ConsumerEvents()
            let lease: NativeLocalConsumerLease? = native ? .init() : nil
            let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { ["fixture": fixture.entry] },
                releaseModel: { _ in events.record("release") },
                nativeConsumerLeaseProvider: { _, _ in lease })
            let stream = try await scheduler.streamChatCompletion(request: fixture.request)
            var output: [String] = []
            for try await event in stream {
                switch event {
                case .content(let text): output.append("content:" + text)
                case .info(let info): output.append("info:\(info.promptTokens):\(info.completionTokens):\(info.stopReason)")
                default: XCTFail("unexpected fixture event")
                }
            }
            if let lease { await lease.joinFromOutside(); XCTAssertEqual(lease.snapshot().phase, .completed) }
            outputs.append(output)
            XCTAssertEqual(events.values, ["release"])
            XCTAssertEqual(fixture.engine.submissions, 1)
            XCTAssertEqual(fixture.preparations.values, ["template"])
        }
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs[0], outputs[1])
        XCTAssertEqual(outputs[0].first, "content:hello")
    }

    func testActualSchedulerAtomicAcquisitionUsesSameTokenOwnedLease() async throws {
        let fixture = ConsumerSchedulerFixture(), lease = NativeLocalConsumerLease(), events = ConsumerEvents()
        let token = OneShotRelease(release: { _ in events.record("release") }, modelId: "fixture",
                                   nativeConsumerLease: lease)
        let acquisition = fixture.acquired(token)
        XCTAssertTrue(acquisition.nativeConsumerLease === lease)
        let scheduler = MultiModelBatchSchedulerEngine(acquire: { _ in acquisition },
            tokenizerProvider: { _ in .init(tokenizer: fixture.tokenizer, modelType: nil) },
            availableModels: { ["fixture"] })
        let stream = try await scheduler.streamChatCompletion(request: fixture.request)
        for try await _ in stream {}
        await lease.joinFromOutside()
        XCTAssertEqual(fixture.engine.submissions, 1)
        XCTAssertEqual(events.values, ["release"])
        XCTAssertEqual(lease.snapshot().phase, .completed)
    }
    #if DEBUG
    func testNativeCloseBeforeFirstForwardThrowsWithoutSeedOrSuccess() async throws {
        let lease = NativeLocalConsumerLease(), entered = ConsumerBarrier(), releases = ConsumerEvents()
        let token = OneShotRelease(release: { _ in releases.record("release") }, modelId: "fixture",
                                   nativeConsumerLease: lease)
        let preparation = try lease.startPreparation { 0 }
        _ = try await preparation.value
        var scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        scheduler._testNativeForwardingHold = { point in
            if case .beforeForward = point { await entered.wait() }
        }
        let source = AsyncStream<GenerationEvent>.makeStream()
        defer { source.continuation.finish() }
        let prepared = try ToolChoicePromptPolicy.prepare(ConsumerSchedulerFixture().request)
        let stream = try scheduler._testMakeEventStream(upstream: source.stream,
            cancelUpstream: {}, prepared: prepared, releaseBox: token,
            reasoningPrefix: "seed must not be emitted")
        let listener = Task { await ConsumerStreamObservation.read(stream) }
        await entered.waitUntilEntered()
        lease.closeAndCancel() // listener remains alive and is NOT cancelled
        await entered.open()
        let result = await listener.value
        await lease.joinFromOutside()
        XCTAssertTrue(result.cancelled)
        XCTAssertNil(result.schedulerError)
        XCTAssertNil(result.unexpectedError)
        XCTAssertTrue(result.events.isEmpty, "pre-forward cancellation must not seed content or emit info/tools")
        XCTAssertEqual(releases.values, ["release"])
    }

    func testNativeCancellationDuringPendingNextThrowsInsteadOfSuccessfulStop() async throws {
        let lease = NativeLocalConsumerLease(), pendingNext = ConsumerBarrier(), trace = ConsumerEvents()
        let token = OneShotRelease(release: { _ in trace.record("release") }, modelId: "fixture",
                                   nativeConsumerLease: lease)
        let preparation = try lease.startPreparation { 0 }
        _ = try await preparation.value
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        let source = AsyncStream<GenerationEvent>.makeStream()
        defer { source.continuation.finish() }
        let iterator = ConsumerSingleStreamIterator(source.stream, trace: trace)
        // The production for-await is inside its pending next() call when this
        // unfolding hold is entered. After cancellation, a REAL inner
        // AsyncStream next() supplies nil; no producer finish/event supplies it.
        let upstream = AsyncStream<GenerationEvent>(unfolding: {
            await pendingNext.wait()
            return await iterator.next()
        })
        let prepared = try ToolChoicePromptPolicy.prepare(ConsumerSchedulerFixture().request)
        let stream = try scheduler._testMakeEventStream(upstream: upstream,
            cancelUpstream: { trace.record("cancel upstream") }, prepared: prepared, releaseBox: token)
        let listener = Task { await ConsumerStreamObservation.read(stream) }
        await pendingNext.waitUntilEntered() // pre-forward check already passed
        lease.closeAndCancel()
        await pendingNext.open()
        let result = await listener.value
        await lease.joinFromOutside()
        XCTAssertEqual(iterator.calls, 1)
        XCTAssertTrue(trace.values.contains("real next nil"))
        XCTAssertTrue(result.cancelled)
        XCTAssertNil(result.schedulerError)
        XCTAssertNil(result.unexpectedError)
        XCTAssertTrue(result.events.isEmpty, "nil from a cancelled next() is not successful info(stop) or tool output")
        XCTAssertEqual(trace.values.filter { $0 == "release" }.count, 1)
    }

    func testNativeCancellationPreservesTypedFailureJustReturnedByNext() async throws {
        let result = try await heldNativeReturnedEvent(.terminal(cause: .watchdog,
            message: "held typed failure", promptTokens: 7, completionTokens: 3))
        XCTAssertFalse(result.cancelled)
        XCTAssertNil(result.unexpectedError)
        XCTAssertTrue(result.events.isEmpty)
        guard case .platformTerminal(let cause, let message, let usage)? = result.schedulerError else {
            return XCTFail("returned typed engine failure was replaced by cancellation/success")
        }
        XCTAssertEqual(cause, .watchdog)
        XCTAssertEqual(message, "watchdog: held typed failure")
        XCTAssertEqual(usage.promptTokens, 7)
        XCTAssertEqual(usage.completionTokens, 3)
    }

    func testNativeCancellationPreservesStringFailureJustReturnedByNext() async throws {
        let message = "fixture returned engine failure"
        let result = try await heldNativeReturnedEvent(.error(message))
        XCTAssertFalse(result.cancelled)
        XCTAssertNil(result.unexpectedError)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.schedulerError, MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message))
    }

    func testNativeCancellationSuppressesReturnedContentAndSuccessInfo() async throws {
        for event in [GenerationEvent.chunk("must not escape"),
                      .info(promptTokens: 4, completionTokens: 1, tokensPerSecond: 0, finishReason: "stop")] {
            let result = try await heldNativeReturnedEvent(event)
            XCTAssertTrue(result.cancelled)
            XCTAssertNil(result.schedulerError)
            XCTAssertNil(result.unexpectedError)
            XCTAssertTrue(result.events.isEmpty, "post-next owner close may expose no new content/info/tool success")
        }
    }

    func testNativeCancellationKeepsPreviouslyObservedTerminalAheadOfNewContent() async throws {
        let lease = NativeLocalConsumerLease(), returned = ConsumerBarrier()
        let token = OneShotRelease(release: { _ in }, modelId: "fixture", nativeConsumerLease: lease)
        let preparation = try lease.startPreparation { 0 }
        _ = try await preparation.value
        var scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        scheduler._testNativeForwardingHold = { point in
            if case .receivedEvent(.chunk(_)) = point { await returned.wait() }
        }
        let source = AsyncStream<GenerationEvent>.makeStream()
        defer { source.continuation.finish() }
        source.continuation.yield(.terminal(cause: .watchdog,
            message: "already observed", promptTokens: 11, completionTokens: 2))
        source.continuation.yield(.chunk("must not escape"))
        let prepared = try ToolChoicePromptPolicy.prepare(ConsumerSchedulerFixture().request)
        let stream = try scheduler._testMakeEventStream(upstream: source.stream,
            cancelUpstream: {}, prepared: prepared, releaseBox: token)
        let listener = Task { await ConsumerStreamObservation.read(stream) }
        await returned.waitUntilEntered() // first terminal already switched/stored
        lease.closeAndCancel()
        await returned.open()
        let result = await listener.value
        await lease.joinFromOutside()
        XCTAssertFalse(result.cancelled)
        XCTAssertNil(result.unexpectedError)
        XCTAssertTrue(result.events.isEmpty)
        guard case .platformTerminal(let cause, let message, let usage)? = result.schedulerError else {
            return XCTFail("prior typed terminal was dropped by the next cancelled loop iteration")
        }
        XCTAssertEqual(cause, .watchdog)
        XCTAssertEqual(message, "watchdog: already observed")
        XCTAssertEqual(usage.promptTokens, 11)
        XCTAssertEqual(usage.completionTokens, 2)
    }

    private func heldNativeReturnedEvent(_ event: GenerationEvent) async throws -> ConsumerStreamObservation {
        let lease = NativeLocalConsumerLease(), returned = ConsumerBarrier(), releases = ConsumerEvents()
        let token = OneShotRelease(release: { _ in releases.record("release") }, modelId: "fixture",
                                   nativeConsumerLease: lease)
        let preparation = try lease.startPreparation { 0 }
        _ = try await preparation.value
        var scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
        scheduler._testNativeForwardingHold = { point in
            if case .receivedEvent = point { await returned.wait() }
        }
        let source = AsyncStream<GenerationEvent>.makeStream()
        defer { source.continuation.finish() }
        source.continuation.yield(event)
        let prepared = try ToolChoicePromptPolicy.prepare(ConsumerSchedulerFixture().request)
        let stream = try scheduler._testMakeEventStream(upstream: source.stream,
            cancelUpstream: {}, prepared: prepared, releaseBox: token)
        let listener = Task { await ConsumerStreamObservation.read(stream) }
        await returned.waitUntilEntered() // event returned; switch not yet entered
        lease.closeAndCancel()
        await returned.open()
        let result = await listener.value
        await lease.joinFromOutside()
        XCTAssertEqual(releases.values, ["release"])
        XCTAssertEqual(lease.snapshot().phase, .completed)
        return result
    }
    #endif
}

private enum ConsumerFixtureError: Error { case refused }
private final class ConsumerEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ event: String) { lock.withLock { entries.append(event) } }
    var values: [String] { lock.withLock { entries } }
}

private actor ConsumerBarrier {
    private var entered = false, opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let current = entryWaiters; entryWaiters.removeAll()
        current.forEach { $0.resume() }
        if !opened { await withCheckedContinuation { openWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func open() {
        opened = true
        let current = openWaiters; openWaiters.removeAll()
        current.forEach { $0.resume() }
    }
}

/// Real Scheduler and Bridge; only the engine/tokenizer boundary is scripted.
/// No native model, allocator, receipt, weights, template or token parity claim.
private struct ConsumerSchedulerFixture: Sendable {
    let engine: ConsumerScriptedEngine
    let preparations: ConsumerEvents
    let tokenizer: TokenizerHandle
    let bridge: EngineV2Bridge
    init(holdOpen: Bool = false) {
        let engine = ConsumerScriptedEngine(holdOpen: holdOpen), preparations = ConsumerEvents()
        self.engine = engine
        self.preparations = preparations
        let tokenizer = TokenizerHandle(ConsumerTokenizer(preparations: preparations))
        self.tokenizer = tokenizer
        bridge = EngineV2Bridge(engine: engine, modelId: "fixture", tokenizer: tokenizer, eosTokenIds: [])
    }
    var request: OpenAIChatCompletionRequest {
        .init(model: "fixture", messages: [.init(role: .user, content: .text("hi"))])
    }
    var entry: MultiModelBatchSchedulerEngine.ModelRegistryEntry {
        .init(tokenizer: tokenizer, engineV2Bridge: bridge)
    }
    func acquired(_ token: OneShotRelease) -> MultiModelBatchSchedulerEngine.AcquiredModel {
        .init(tokenizer: tokenizer, releaseToken: token, engineV2Bridge: bridge)
    }
}

private final class ConsumerScriptedEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var cancelled = 0
    private var pending: [CBv2RequestID: AsyncStream<CBv2Event>.Continuation] = [:]
    private let holdOpen: Bool
    init(holdOpen: Bool) { self.holdOpen = holdOpen }
    var submissions: Int { lock.withLock { count } }
    var pendingCount: Int { lock.withLock { pending.count } }
    var cancelledRows: Int { lock.withLock { cancelled } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { count += 1 }
        return AsyncStream { continuation in
            if holdOpen { lock.withLock { pending[request.id] = continuation }; return }
            continuation.yield(.delta(text: "hello", tokens: [9], logprobs: nil))
            continuation.yield(.finished(reason: .stop,
                usage: .init(promptTokens: request.promptTokens.count, completionTokens: 1)))
            continuation.finish()
        }
    }
    func cancel(_ id: CBv2RequestID) {
        let continuation = lock.withLock {
            let result = pending.removeValue(forKey: id)
            if result != nil { cancelled += 1 }
            return result
        }
        continuation?.yield(.finished(reason: .cancelled,
            usage: .init(promptTokens: 0, completionTokens: 0)))
        continuation?.finish()
    }
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

private struct ConsumerTokenizer: MLXLMCommon.Tokenizer {
    let preparations: ConsumerEvents
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "fixture" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        preparations.record("template")
        return [1, 2, 3]
    }
}

#if DEBUG
private struct ConsumerStreamObservation: Sendable {
    var events: [MLXServerGenerationEvent] = []
    var cancelled = false
    var schedulerError: MultiModelBatchSchedulerEngineError?
    var unexpectedError: String?
    static func read(_ stream: AsyncThrowingStream<MLXServerGenerationEvent, Error>) async -> Self {
        var result = Self()
        do { for try await event in stream { result.events.append(event) } }
        catch is CancellationError { result.cancelled = true }
        catch let error as MultiModelBatchSchedulerEngineError { result.schedulerError = error }
        catch { result.unexpectedError = String(describing: error) }
        return result
    }
}

/// One production forwarding task is the sole iterator consumer. The lock
/// protects only the observation count, never spans next() or a native wait.
private final class ConsumerSingleStreamIterator: @unchecked Sendable {
    private var iterator: AsyncStream<GenerationEvent>.Iterator
    private let lock = NSLock()
    private var count = 0
    private let trace: ConsumerEvents
    init(_ stream: AsyncStream<GenerationEvent>, trace: ConsumerEvents) {
        iterator = stream.makeAsyncIterator(); self.trace = trace
    }
    var calls: Int { lock.withLock { count } }
    func next() async -> GenerationEvent? {
        lock.withLock { count += 1 }
        let event = await iterator.next()
        if case nil = event { trace.record("real next nil") }
        return event
    }
}
#endif
