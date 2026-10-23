import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

private actor BatchReplacementTrace {
    var prepares = 0
    var restores = 0
    var demands: [DistributedLocalBatchDemand] = []
    func plan(_ demand: DistributedLocalBatchDemand) { demands.append(demand) }
    func prepare() { prepares += 1 }
    func restore() { restores += 1 }
}

private func batchHost(_ session: LocalHostTestSession, waiting: Int = 64, retryDelay: Duration = .seconds(30),
    planner: @escaping @Sendable (DistributedLocalBatchDemand) async throws -> DistributedLocalBatchReplacement?
) -> DistributedLocalServer {
    .init(session: session, config: .init(host: "127.0.0.1", port: 0),
        tokenizerLoader: { _ in TokenizerHandle(DistributedTestTokenizer()) },
        queue: .init(maximumWaiting: waiting), batchReplacement: planner, replacementRetryDelay: retryDelay)
}

private func pending(_ host: DistributedLocalServer, response: DistributedHTTPResponse,
                     model: String) -> Task<MultiModelBatchSchedulerEngine.AcquiredModel, Error> {
    Task { try await DistributedHTTPResponseScope.$current.withValue(response) { try await host.acquire(model) } }
}

@Test(arguments: [2, 4, 8]) func distributedBatchReplacementKeepsListenerAndPendingResponseAfterBothOwnersRelease(width: Int) async throws {
    let previous = LocalHostTestSession(), next = LocalHostTestSession(), trace = BatchReplacementTrace()
    previous.holdOwnerACK = true; next.concurrentRequests = width
    let host = batchHost(previous) { demand in
        await trace.plan(demand)
        return .init(requestedCapacity: width, makeTestSession: {
            #expect(previous.status == .released)
            await trace.prepare(); return next
        })
    }
    try await host.start()
    let port = try #require(await host.status.boundPort)
    let first = try await host.acquire(previous.model.publicModelID)
    let registry = await host.responses, response = try registry.begin()
    let queued = pending(host, response: response, model: previous.model.publicModelID)
    #expect(try await localHostEventually { await host.status.phase == .reconfiguring })
    #expect(previous.nativeCleanupObserved == false)
    await first.releaseToken.fire()
    #expect(try await localHostEventually { previous.nativeCleanupObserved })
    #expect(await trace.prepares == 0)
    #expect(!response.isComplete && registry.owns(response))
    let (_, loading) = try await localHostGET(port: port, path: "/v1/models")
    #expect(loading.statusCode == 200)
    previous.ack.complete()
    let admitted = try await queued.value
    #expect(next.startCount == 1 && previous.status == .released)
    #expect(await host.status.boundPort == port)
    #expect(await host.responses === registry)
    #expect(await host.generation.capacity == width)
    let recorded = await trace.demands
    #expect(recorded.count == 1 && recorded[0].waitingRequests == 1 && recorded[0].activeRequests == 1)
    #expect(recorded[0].maximumPromptTokens == previous.profile.maxPromptTokens)
    await admitted.releaseToken.fire(); response.finish()
    #expect(await host.stop(until: localHostDeadline()).cleanupComplete)
}

@Test func distributedBatchReplacementPendingDisconnectRemainsEffectiveDuringLoad() async throws {
    let previous = LocalHostTestSession(), next = LocalHostTestSession(), ready = LocalHostLatch()
    let trace = BatchReplacementTrace(); next.concurrentRequests = 8
    let host = batchHost(previous) { _ in
        .init(requestedCapacity: 8, makeTestSession: { await trace.prepare(); await ready.wait(); return next })
    }
    try await host.start()
    let first = try await host.acquire(previous.model.publicModelID)
    let response = try await host.responses.begin()
    let queued = pending(host, response: response, model: previous.model.publicModelID)
    #expect(try await localHostEventually { await host.status.phase == .reconfiguring })
    await first.releaseToken.fire()
    #expect(try await localHostEventually { await trace.prepares == 1 })
    response.disconnect()
    do { _ = try await queued.value; Issue.record("Disconnected pending response acquired a new owner") }
    catch is CancellationError {} catch { Issue.record("Unexpected pending error: \(error)") }
    #expect(next.startCount == 0)
    response.finish(); ready.complete()
    #expect(try await localHostEventually { await host.status.phase == .serving })
    #expect(await host.stop(until: localHostDeadline()).cleanupComplete)
}

@Test func distributedBatchReplacementDoesNotRestartOriginalQueueCeiling() async throws {
    let previous = LocalHostTestSession(requestTimeout: .milliseconds(200))
    let next = LocalHostTestSession(requestTimeout: .milliseconds(200)), ready = LocalHostLatch()
    next.concurrentRequests = 8
    let host = batchHost(previous, waiting: 1) { _ in
        .init(requestedCapacity: 8, makeTestSession: { await ready.wait(); return next })
    }
    try await host.start()
    let first = try await host.acquire(previous.model.publicModelID)
    let response = try await host.responses.begin()
    let queued = pending(host, response: response, model: previous.model.publicModelID)
    #expect(try await localHostEventually { await host.status.phase == .reconfiguring })
    await first.releaseToken.fire()
    do { _ = try await queued.value; Issue.record("Expired queue ticket acquired a replacement") }
    catch let error as MultiModelBatchSchedulerEngineError {
        #expect(error == .requestRejected(DistributedRequestQueue.waitedTooLongMessage))
    }
    #expect(next.startCount == 0 && response.selectedDeadline == nil)
    response.finish(); ready.complete()
    #expect(try await localHostEventually { await host.status.phase == .serving })
    #expect(await host.stop(until: localHostDeadline()).cleanupComplete)
}

@Test func distributedBatchReplacementRollsBackWithFreshOwnerAfterFailedCandidateRelease() async throws {
    let previous = LocalHostTestSession(), rejected = LocalHostTestSession(), restored = LocalHostTestSession()
    rejected.failStart = true; rejected.holdOwnerACK = true
    let trace = BatchReplacementTrace()
    let host = batchHost(previous) { _ in
        .init(requestedCapacity: 8, makeTestSession: { rejected }, restoreTestSession: {
            #expect(previous.status == .released && rejected.status == .released)
            await trace.restore(); return restored
        })
    }
    try await host.start()
    let first = try await host.acquire(previous.model.publicModelID)
    let response = try await host.responses.begin()
    let queued = pending(host, response: response, model: previous.model.publicModelID)
    #expect(try await localHostEventually { await host.status.phase == .reconfiguring })
    await first.releaseToken.fire()
    #expect(try await localHostEventually { rejected.nativeCleanupObserved })
    #expect(await trace.restores == 0)
    rejected.ack.complete()
    let admitted = try await queued.value
    #expect(previous.startCount == 1 && rejected.startCount == 1 && restored.startCount == 1)
    #expect(await host.status.failed == false)
    await admitted.releaseToken.fire(); response.finish()
    #expect(await host.stop(until: localHostDeadline()).cleanupComplete)
}

@Test func distributedBatchReplacementRejectsChangedRequestContractBeforeNewOwnerStart() async throws {
    let previous = LocalHostTestSession(), changed = LocalHostTestSession(maxPromptTokens: 4096)
    let restored = LocalHostTestSession()
    let host = batchHost(previous) { _ in
        .init(requestedCapacity: 8, makeTestSession: { changed }, restoreTestSession: { restored })
    }
    try await host.start()
    let first = try await host.acquire(previous.model.publicModelID)
    let response = try await host.responses.begin()
    let queued = pending(host, response: response, model: previous.model.publicModelID)
    #expect(try await localHostEventually { await host.status.phase == .reconfiguring })
    await first.releaseToken.fire()
    let admitted = try await queued.value
    #expect(changed.startCount == 0 && changed.status == .released && restored.startCount == 1)
    await admitted.releaseToken.fire(); response.finish()
    #expect(await host.stop(until: localHostDeadline()).cleanupComplete)
}

@Test func distributedBatchReplacementUnresolvedOldReleaseNeverPreparesReplacement() async throws {
    let previous = LocalHostTestSession(), next = LocalHostTestSession(), trace = BatchReplacementTrace()
    previous.retainQuarantine = true
    let host = batchHost(previous) { _ in
        .init(requestedCapacity: 8, makeTestSession: { await trace.prepare(); return next })
    }
    try await host.start()
    let first = try await host.acquire(previous.model.publicModelID)
    let response = try await host.responses.begin()
    let queued = pending(host, response: response, model: previous.model.publicModelID)
    #expect(try await localHostEventually { await host.status.phase == .reconfiguring })
    await first.releaseToken.fire()
    do { _ = try await queued.value; Issue.record("Unresolved owner release admitted pending work") } catch {}
    response.finish()
    let stopped = await host.waitUntilStopped()
    #expect(stopped.phase == .quarantined && !stopped.cleanupComplete)
    #expect(await trace.prepares == 0 && next.startCount == 0)
}

@Test func distributedBatchReplacementStopDuringDeferredFactoryRetainsFreshSessionCleanup() async throws {
    let previous = LocalHostTestSession(), next = LocalHostTestSession(), ready = LocalHostLatch()
    let trace = BatchReplacementTrace()
    let host = batchHost(previous) { _ in
        .init(requestedCapacity: 8, makeTestSession: { await trace.prepare(); await ready.wait(); return next })
    }
    try await host.start()
    let first = try await host.acquire(previous.model.publicModelID)
    let response = try await host.responses.begin()
    let queued = pending(host, response: response, model: previous.model.publicModelID)
    #expect(try await localHostEventually { await host.status.phase == .reconfiguring })
    await first.releaseToken.fire()
    #expect(try await localHostEventually { await trace.prepares == 1 })
    let stopping = await host.stop(until: localHostDeadline(25))
    #expect(!stopping.cleanupComplete)
    ready.complete()
    do { _ = try await queued.value; Issue.record("Stop admitted pending work") } catch {}
    response.finish()
    #expect(try await localHostEventually { await host.status.cleanupComplete })
    #expect(next.startCount == 0 && next.nativeCleanupObserved && next.status == .released)
}

@Test func distributedBatchReplacementRequiresActualRequestedWorkerWidth() async throws {
    let previous = LocalHostTestSession(), narrow = LocalHostTestSession(), restored = LocalHostTestSession()
    let host = batchHost(previous) { _ in
        .init(requestedCapacity: 8, makeTestSession: { narrow }, restoreTestSession: { restored })
    }
    try await host.start()
    let first = try await host.acquire(previous.model.publicModelID)
    let response = try await host.responses.begin()
    let queued = pending(host, response: response, model: previous.model.publicModelID)
    #expect(try await localHostEventually { await host.status.phase == .reconfiguring })
    await first.releaseToken.fire()
    let admitted = try await queued.value
    #expect(narrow.startCount == 1 && narrow.status == .released && restored.startCount == 1)
    #expect(await host.generation.capacity == 1)
    await admitted.releaseToken.fire(); response.finish()
    #expect(await host.stop(until: localHostDeadline()).cleanupComplete)
}

@Test func distributedBatchReplacementNewPendingUsesStableTimeoutWhileRejectedCandidateRetires() async throws {
    let previous = LocalHostTestSession(requestTimeout: .milliseconds(200))
    let rejected = LocalHostTestSession(requestTimeout: .seconds(2))
    let restored = LocalHostTestSession(requestTimeout: .milliseconds(200))
    rejected.holdOwnerACK = true
    let host = batchHost(previous, waiting: 1) { _ in
        .init(requestedCapacity: 8, makeTestSession: { rejected }, restoreTestSession: { restored })
    }
    try await host.start()
    let first = try await host.acquire(previous.model.publicModelID)
    let firstResponse = try await host.responses.begin()
    let firstQueued = pending(host, response: firstResponse, model: previous.model.publicModelID)
    #expect(try await localHostEventually { await host.status.phase == .reconfiguring })
    await first.releaseToken.fire()
    #expect(try await localHostEventually { rejected.nativeCleanupObserved })
    firstResponse.disconnect()
    do { _ = try await firstQueued.value; Issue.record("Disconnected request acquired") } catch {}
    firstResponse.finish()
    let response = try await host.responses.begin()
    let began = ContinuousClock.now
    let queued = pending(host, response: response, model: previous.model.publicModelID)
    do { _ = try await queued.value; Issue.record("Expired new pending ticket acquired") }
    catch let error as MultiModelBatchSchedulerEngineError {
        #expect(error == .requestRejected(DistributedRequestQueue.waitedTooLongMessage))
    }
    #expect(ContinuousClock.now - began < .seconds(1))
    #expect(rejected.startCount == 0 && restored.startCount == 0)
    response.finish(); rejected.ack.complete()
    #expect(try await localHostEventually { await host.status.phase == .serving })
    #expect(await host.stop(until: localHostDeadline()).cleanupComplete)
}

@Test func distributedBatchReplacementRetriesStableDemandAfterTemporaryNoPlan() async throws {
    let previous = LocalHostTestSession(), next = LocalHostTestSession(), trace = BatchReplacementTrace()
    next.concurrentRequests = 8
    let host = batchHost(previous, retryDelay: .milliseconds(20)) { demand in
        await trace.plan(demand)
        if await trace.demands.count == 1 { return nil }
        return .init(requestedCapacity: 8, makeTestSession: { next })
    }
    try await host.start()
    let first = try await host.acquire(previous.model.publicModelID)
    let response = try await host.responses.begin()
    let queued = pending(host, response: response, model: previous.model.publicModelID)
    #expect(try await localHostEventually { await host.status.phase == .reconfiguring })
    let observed = await trace.demands
    #expect(observed.count == 2)
    #expect(observed[0].generationID == observed[1].generationID)
    #expect(observed[0].waitingRequests == 1 && observed[1].waitingRequests == 1)
    #expect(observed[0].activeRequests == 1 && observed[1].activeRequests == 1)
    await first.releaseToken.fire()
    let admitted = try await queued.value
    #expect(await host.generation.capacity == 8)
    await admitted.releaseToken.fire(); response.finish()
    #expect(await host.stop(until: localHostDeadline()).cleanupComplete)
}
