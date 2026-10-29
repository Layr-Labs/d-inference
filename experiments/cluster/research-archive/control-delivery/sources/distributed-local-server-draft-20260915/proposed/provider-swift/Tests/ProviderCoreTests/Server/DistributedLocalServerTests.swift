import Foundation
import Testing
@testable import ProviderCore

@Test func distributedLocalServerActualBindPublicRouteAndPinnedShutdown() async throws {
    let session = LocalHostTestSession(), discovery = LocalHostDiscovery()
    let host = localHost(session, discovery: discovery)
    try await host.start()
    let started = await host.status
    let port = try #require(started.boundPort)
    #expect(started.phase == .serving && discovery.value?.port == port)
    #expect(session.validationCount == 2 && session.startCount == 1)
    let (models, response) = try await localHostGET(port: port, path: "/v1/models")
    #expect(response.statusCode == 200)
    #expect(String(decoding: models, as: UTF8.self).contains(session.model.publicModelID))
    #expect(!String(decoding: models, as: UTF8.self).contains(session.expectedIdentity.modelID))
    let wrongRoute = try await localHostPOST(port: port, model: session.expectedIdentity.modelID)
    #expect(wrongRoute.statusCode == 404 && session.base.reserveCount == 0)
    do { _ = try await host.acquire(session.expectedIdentity.modelID); Issue.record("Accepted native ID as public route") }
    catch let error as MultiModelBatchSchedulerEngineError { #expect(error == .modelNotLoaded(session.expectedIdentity.modelID)) }
    let acquired = try await host.acquire(session.model.publicModelID)
    #expect(acquired.container == nil && !acquired.isVLM && acquired.engineV2Bridge != nil)
    let stopped = await host.stop(until: localHostDeadline(20))
    #expect(stopped.phase == .quarantined && stopped.acquisitions == 1 && !stopped.cleanupComplete)
    #expect(discovery.value == nil)
    await acquired.releaseToken.fire(); await acquired.releaseToken.fire()
    #expect(try await localHostEventually { await host.status.cleanupComplete })
    let finished = await host.waitUntilStopped()
    #expect(finished.cleanupComplete && finished.acquisitions == 0)
}

@Test func distributedLocalServerPortCollisionNeverPublishesForeignListener() async throws {
    let first = localHost(LocalHostTestSession())
    try await first.start()
    let firstStatus = await first.status
    let port = try #require(firstStatus.boundPort)
    let secondSession = LocalHostTestSession(), secondDiscovery = LocalHostDiscovery()
    let second = localHost(secondSession, port: port, discovery: secondDiscovery)
    do { try await second.start(); Issue.record("Port collision accepted") } catch {}
    let stopped = await second.waitUntilStopped()
    #expect(stopped.cleanupComplete && secondDiscovery.writeCount == 0)
    let (_, response) = try await localHostGET(port: port, path: "/health")
    #expect(response.statusCode == 200)
    _ = await first.stop(until: localHostDeadline())
}

@Test func distributedLocalServerStartupCancellationRetainsCleanup() async throws {
    let session = LocalHostTestSession(); session.startDelay = .seconds(10); session.holdOwnerACK = true
    let host = localHost(session)
    let start = Task { try await host.start() }
    #expect(try await localHostEventually { session.startCount == 1 })
    start.cancel()
    do { try await start.value; Issue.record("Canceled startup returned success") } catch {}
    let status = await host.stop(until: localHostDeadline(20))
    #expect(status.phase == .quarantined && !status.cleanupComplete)
    #expect(session.nativeCleanupObserved)
    session.ack.complete()
    #expect(try await localHostEventually { await host.status.cleanupComplete })
    let done = await host.waitUntilStopped()
    #expect(done.cleanupComplete)
}

@Test func distributedLocalServerExpiryStopsWithoutHTTPRequests() async throws {
    let session = LocalHostTestSession(); session.lifetimeNanoseconds = 1_000_000_000
    let discovery = LocalHostDiscovery()
    let host = localHost(session, discovery: discovery)
    try await host.start()
    let done = await host.waitUntilStopped()
    #expect(done.cleanupComplete && session.base.reserveCount == 0 && discovery.value == nil)
}

@Test func distributedLocalServerDoesNotEquateListenerExitOrNativeCleanupWithOwnerACK() async throws {
    let session = LocalHostTestSession(); session.holdOwnerACK = true
    let host = localHost(session)
    try await host.start()
    let observer = Task { await host.waitUntilStopped() }
    #expect(try await localHostEventually { await host.stopWaiters.count == 1 })
    let stopped = await host.stop(until: localHostDeadline(25))
    #expect(stopped.phase == .quarantined && !stopped.cleanupComplete)
    #expect(session.nativeCleanupObserved)
    let observed = await observer.value
    #expect(observed.phase == .quarantined && !observed.cleanupComplete)
    let retained = await host.entry
    #expect(retained != nil)
    session.ack.complete()
    #expect(try await localHostEventually { await host.status.cleanupComplete })
    let done = await host.waitUntilStopped()
    #expect(done.cleanupComplete)
}

@Test func distributedLocalServerExplicitUnresolvedQuarantineIsRetained() async throws {
    let session = LocalHostTestSession(); session.retainQuarantine = true
    let host = localHost(session)
    try await host.start()
    _ = await host.stop(until: localHostDeadline())
    let done = await host.waitUntilStopped()
    #expect(done.phase == .quarantined && done.session == .quarantined && !done.cleanupComplete)
    let retained = await host.entry
    #expect(retained != nil)
}

@Test func distributedLocalServerDiscoveryRemovesOnlyExactOwnRecord() async throws {
    let discovery = LocalHostDiscovery()
    let host = localHost(LocalHostTestSession(), discovery: discovery)
    try await host.start()
    let owned = try #require(discovery.value)
    var competitor = owned; competitor.pid = 456; competitor.updatedAt = "two"
    discovery.replace(competitor)
    _ = await host.stop(until: localHostDeadline())
    #expect(discovery.value == competitor)
    discovery.client.removeIfOwned(competitor)
    #expect(discovery.value == nil)
}

@Test func distributedLocalServerChangedTokenizerMetadataRefusesBeforeOwnerStart() async throws {
    let session = LocalHostTestSession(); session.failSecondValidation = true
    let discovery = LocalHostDiscovery()
    let host = localHost(session, discovery: discovery)
    do { try await host.start(); Issue.record("Changed tokenizer inputs admitted") } catch {}
    let done = await host.waitUntilStopped()
    #expect(session.startCount == 0 && session.validationCount == 2 && done.cleanupComplete && discovery.writeCount == 0)
}

@Test func distributedLocalServerDrainClosesAdmissionsAndWaitsForExplicitRelease() async throws {
    let session = LocalHostTestSession(); session.holdDrain = true
    let host = localHost(session)
    try await host.start()
    let acquired = try await host.acquire(session.model.publicModelID)
    let started = await host.status
    let port = try #require(started.boundPort)
    let draining = Task { await host.drain(until: localHostDeadline()) }
    #expect(try await localHostEventually { session.didEnterDrain })
    let refused = try await localHostPOST(port: port, model: session.model.publicModelID)
    #expect(refused.statusCode == 503 && session.base.reserveCount == 0)
    do { _ = try await host.acquire(session.model.publicModelID); Issue.record("Drain admitted request") }
    catch let error as MultiModelBatchSchedulerEngineError {
        guard case .requestRejected = error else { throw error }
    }
    #expect(!session.nativeCleanupObserved)
    session.drained.complete()
    await acquired.releaseToken.fire()
    let result = await draining.value
    #expect(result.cleanupComplete)
}

@Test func distributedLocalServerExhaustionKeepsLastResponseAcquisitionUntilRelease() async throws {
    let session = LocalHostTestSession()
    let serving = localHost(session)
    try await serving.start()
    let acquired = try await serving.acquire(session.model.publicModelID)
    session.exhaustRequests()
    try await Task.sleep(for: .milliseconds(150))
    let held = await serving.status
    #expect(held.phase == .serving && held.acquisitions == 1 && !session.nativeCleanupObserved)
    await acquired.releaseToken.fire()
    let done = await serving.waitUntilStopped()
    #expect(done.cleanupComplete)
}
