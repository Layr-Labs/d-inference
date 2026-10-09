import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

final class RotationTestFactory: @unchecked Sendable {
    let sessions: [any DistributedLocalServerSession]
    private let lock = NSLock()
    private var calls = 0
    let hold = LocalHostLatch()
    var holdFactory = false
    var count: Int { lock.withLock { calls } }
    init(_ sessions: [any DistributedLocalServerSession]) { self.sessions = sessions }
    func make() async throws -> any DistributedLocalServerSession {
        let index = lock.withLock { calls += 1; return calls }
        guard index < sessions.count, sessions[index - 1].httpCanRotate else {
            throw DistributedLocalServerError.replacementNotReleased
        }
        if holdFactory { await hold.wait() } // Deliberately returns after cancellation.
        return sessions[index]
    }
    func host(discovery: LocalHostDiscovery? = nil) -> DistributedLocalServer {
        .init(session: sessions[0], config: .init(host: "127.0.0.1", port: 0),
              tokenizerLoader: { _ in TokenizerHandle(DistributedTestTokenizer()) },
              discovery: discovery?.client, replacementSessionFactory: { try await self.make() })
    }
}

@Test func distributedLocalRotationKeepsPortDiscoveryAndRejectsOldGeneration() async throws {
    let sessions = [LocalHostTestSession(), LocalHostTestSession(), LocalHostTestSession()]
    let factory = RotationTestFactory(sessions), discovery = LocalHostDiscovery()
    let host = factory.host(discovery: discovery)
    try await host.start()
    let started = await host.status
    let port = try #require(started.boundPort), initialDiscovery = discovery.value
    let old = await host.generation
    let acquired = try await host.acquire(sessions[0].model.publicModelID)
    let response = try old.responses.begin()
    sessions[0].exhaustRequests()
    #expect(try await localHostEventually { await host.status.phase == .rotating })
    #expect(factory.count == 0)
    let (_, health) = try await localHostGET(port: port, path: "/health")
    #expect(health.statusCode == 200 && discovery.value == initialDiscovery)
    await acquired.releaseToken.fire()
    try await Task.sleep(for: .milliseconds(30))
    #expect(factory.count == 0) // An actual response hold still owns this generation.
    response.finish()
    #expect(try await localHostEventually {
        let phase = await host.status.phase
        return sessions[1].startCount == 1 && phase == .serving
    })
    let second = await host.generation
    #expect(second.id != old.id && second.session.expectedIdentity != old.session.expectedIdentity)
    let stale = DistributedHTTPResponse(generationID: old.id)
    do {
        _ = try await DistributedHTTPResponseScope.$current.withValue(stale) { try await host.acquire(sessions[1].model.publicModelID) }
        Issue.record("Old response acquired a replacement generation")
    } catch {}
    do { _ = try old.responses.begin(); Issue.record("Old registry reopened") } catch {}
    sessions[0].base.losePeer()
    await host.beginQuotaRotation(old)
    await host.startLifetimeMonitor(old, deadline: DispatchTime.now().uptimeNanoseconds)
    try await Task.sleep(for: .milliseconds(30))
    let afterLate = await host.status
    #expect(afterLate.phase == .serving && !afterLate.failed && afterLate.boundPort == port)
    sessions[1].exhaustRequests()
    #expect(try await localHostEventually {
        let phase = await host.status.phase
        return sessions[2].startCount == 1 && phase == .serving
    })
    #expect(factory.count == 2 && discovery.writeCount == 1 && discovery.value == initialDiscovery)
    let done = await host.stop(until: localHostDeadline())
    #expect(done.cleanupComplete)
}

@Test func distributedLocalRotationMissingACKBlocksFactoryAndRetainsOwnership() async throws {
    let first = LocalHostTestSession(), second = LocalHostTestSession()
    first.holdOwnerACK = true
    let factory = RotationTestFactory([first, second]), host = factory.host()
    try await host.start(); first.exhaustRequests()
    #expect(try await localHostEventually { first.nativeCleanupObserved })
    #expect(factory.count == 0 && second.startCount == 0)
    let done = await host.stop(until: localHostDeadline(20))
    #expect(done.phase == .quarantined && !done.cleanupComplete)
    first.ack.complete()
    #expect(try await localHostEventually { await host.status.cleanupComplete })
    #expect(factory.count == 0 && second.startCount == 0)
}

@Test func distributedLocalRotationStopDuringReplacementStartupRetainsCandidate() async throws {
    let first = LocalHostTestSession(), second = LocalHostTestSession()
    second.startDelay = .seconds(10); second.holdOwnerACK = true
    let factory = RotationTestFactory([first, second]), host = factory.host()
    try await host.start(); first.exhaustRequests()
    #expect(try await localHostEventually { second.startCount == 1 })
    let done = await host.stop(until: localHostDeadline(20))
    #expect(done.phase == .quarantined && !done.cleanupComplete && factory.count == 1)
    let retained = await host.generation
    #expect(retained.session === second)
    second.ack.complete()
    #expect(try await localHostEventually { await host.status.cleanupComplete })
    let final = await host.status
    #expect(final.phase == .stopped && factory.count == 1)
}

@Test func distributedLocalRotationLateFactoryResultIsStoppedWithoutStart() async throws {
    let first = LocalHostTestSession(), second = LocalHostTestSession()
    let factory = RotationTestFactory([first, second]); factory.holdFactory = true
    let host = factory.host()
    try await host.start(); first.exhaustRequests()
    #expect(try await localHostEventually { factory.count == 1 })
    let done = await host.stop(until: localHostDeadline(20))
    #expect(done.phase == .quarantined && !done.cleanupComplete)
    factory.hold.complete()
    #expect(try await localHostEventually { await host.status.cleanupComplete })
    #expect(second.startCount == 0 && second.status == .released && factory.count == 1)
}

@Test func distributedLocalRotationFirstIncrementStillStopsAtFixedLifetime() async throws {
    let first = LocalHostTestSession(), second = LocalHostTestSession()
    first.lifetimeNanoseconds = 250_000_000
    let factory = RotationTestFactory([first, second]), host = factory.host()
    try await host.start()
    let done = await host.waitUntilStopped()
    #expect(done.cleanupComplete && factory.count == 0 && second.startCount == 0)
}
