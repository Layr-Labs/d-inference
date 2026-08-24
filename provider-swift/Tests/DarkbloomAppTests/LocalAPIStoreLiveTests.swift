import Foundation
import Testing
@testable import DarkbloomApp
import ProviderCoreFoundation

@Suite("Live Local API store reads the discovery record and probes the endpoint")
@MainActor
struct LocalAPIStoreLiveTests {
    // MARK: Stubs

    private func testInfo(
        apiKey: String = "dk-local-test-key",
        pid: Int32 = 4002,
        startTimeMicros: UInt64 = 200_000,
        port: UInt16 = 8000
    ) -> LocalEndpointInfo {
        let identity = ProcessIdentity(
            pid: pid,
            startTimeMicros: startTimeMicros
        )
        return LocalEndpointInfo(
            host: "127.0.0.1",
            port: port,
            apiKey: apiKey,
            version: "0.8.5",
            pid: pid,
            processIdentity: identity,
            updatedAt: "2026-06-17T19:30:00Z"
        )
    }

    /// Fake probe client: `listModels` succeeds, 404s, or fails per setup.
    /// `@unchecked Sendable` for the same reason as other suite stubs —
    /// single sequential call flow, reads after awaits.
    final class ProbeStub: @unchecked Sendable {
        enum Behavior {
            case succeeds([String])
            case catalogMissing      // HTTP 404
            case transportFailure    // nothing listening
        }

        var behavior: Behavior = .succeeds(["gpt-oss-20b"])
        var probeCount = 0
        var usedAPIKey: String?

        func makeClient(for info: LocalEndpointInfo) -> LocalEndpointClient {
            let stub = self
            return LocalEndpointClient(
                baseURL: URL(string: info.baseURL)!,
                apiKey: info.apiKey,
                dataTransport: { request in
                    stub.probeCount += 1
                    stub.usedAPIKey = request.value(forHTTPHeaderField: "Authorization")
                    switch stub.behavior {
                    case .succeeds(let ids):
                        let entries = ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
                        let data = #"{"object":"list","data":[\#(entries)]}"#.data(using: .utf8)!
                        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    case .catalogMissing:
                        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
                    case .transportFailure:
                        throw URLError(.cannotConnectToHost)
                    }
                },
                lineTransport: { _ in
                    (AsyncThrowingStream { $0.finish() }, HTTPURLResponse(url: URL(string: "http://127.0.0.1:8000/v1")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            )
        }
    }

    /// Mutable discovery source so individual tests can flip the record
    /// mid-lifecycle (endpoint stops, key rotates).
    final class DiscoverySource: @unchecked Sendable {
        var info: LocalEndpointInfo?
    }

    private func makeStore(
        discovery: DiscoverySource,
        probe: ProbeStub,
        alive: Bool = true,
        processIdentityReader: (@Sendable (Int32) -> ProcessIdentity?)? = nil
    ) -> LocalAPIStore {
        let identityReader: @Sendable (Int32) -> ProcessIdentity? = processIdentityReader ?? { pid in
            guard alive, discovery.info?.pid == pid else { return nil }
            return discovery.info?.processIdentity
        }
        LocalAPIStore.live(
            discoveryReader: { discovery.info },
            processIdentityReader: identityReader,
            pollInterval: .seconds(3),
            staleAfter: 15,
            clientFactory: { info in probe.makeClient(for: info) }
        )
    }

    // MARK: Bootstrap

    @Test("Without a discovery record the store boots stopped")
    func bootsStoppedWithoutDiscovery() {
        let store = makeStore(discovery: DiscoverySource(), probe: ProbeStub())
        guard case .stopped(let message) = store.state else {
            Issue.record("Expected .stopped, got \(store.state)")
            return
        }
        #expect(message.contains("discovery record") )
        #expect(store.endpoint == nil)
    }

    @Test("With a discovery record the store boots checking + loading before the first probe")
    func bootsCheckingWithDiscovery() throws {
        let discovery = DiscoverySource()
        discovery.info = testInfo()
        let store = makeStore(discovery: discovery, probe: ProbeStub())

        let endpoint = try #require(store.endpoint)
        #expect(endpoint.health == .checking)
        #expect(endpoint.modelCatalog == .loading)
        #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:8000/v1")
        #expect(endpoint.requiresAuthentication == true)
        #expect(endpoint.mode == nil)  // local.json does not record the serve mode
        #expect(endpoint.version == "0.8.5")
    }

    @Test("An empty discovery API key maps to an open endpoint")
    func emptyKeyMeansNoAuth() {
        let discovery = DiscoverySource()
        discovery.info = testInfo(apiKey: "")
        let store = makeStore(discovery: discovery, probe: ProbeStub())
        #expect(store.endpoint?.requiresAuthentication == false)
        #expect(store.endpoint?.apiKey == nil)
    }

    @Test("A dead recorded process reads as stopped, not checking")
    func deadProcessBootsStopped() {
        let discovery = DiscoverySource()
        discovery.info = testInfo()
        let store = makeStore(discovery: discovery, probe: ProbeStub(), alive: false)
        guard case .stopped = store.state else {
            Issue.record("Expected .stopped for a dead recorded process")
            return
        }
    }

    @Test("Legacy PID-only discovery fails closed before sending its bearer token")
    func legacyIdentityDoesNotProbe() async {
        let discovery = DiscoverySource()
        var legacy = testInfo()
        legacy.processIdentity = nil
        discovery.info = legacy
        let probe = ProbeStub()
        let store = makeStore(discovery: discovery, probe: probe)

        await store.refreshNow(forceProbe: true)

        guard case .stopped = store.state else {
            Issue.record("Expected legacy discovery to remain stopped")
            return
        }
        #expect(probe.probeCount == 0)
        #expect(probe.usedAPIKey == nil)
    }

    @Test("A reused PID fails closed before sending its bearer token")
    func reusedPIDDoesNotProbe() async {
        let discovery = DiscoverySource()
        let info = testInfo()
        discovery.info = info
        let probe = ProbeStub()
        let reused = ProcessIdentity(
            pid: info.pid,
            startTimeMicros: info.processIdentity!.startTimeMicros + 1
        )
        let store = makeStore(
            discovery: discovery,
            probe: probe,
            processIdentityReader: { _ in reused }
        )

        await store.refreshNow(forceProbe: true)

        guard case .stopped = store.state else {
            Issue.record("Expected PID-reused discovery to remain stopped")
            return
        }
        #expect(probe.probeCount == 0)
        #expect(probe.usedAPIKey == nil)
    }

    // MARK: Probing

    @Test("A successful probe publishes health and the model catalog")
    func probeSuccess() async {
        let discovery = DiscoverySource()
        discovery.info = testInfo()
        let probe = ProbeStub()
        probe.behavior = .succeeds(["gpt-oss-20b", "gemma-4"])
        let store = makeStore(discovery: discovery, probe: probe)

        await store.refreshNow()

        #expect(store.endpoint?.health == .reachable)
        #expect(store.endpoint?.availableModelIDs == ["gpt-oss-20b", "gemma-4"])
        #expect(probe.probeCount == 1)
        #expect(probe.usedAPIKey == "Bearer dk-local-test-key")
    }

    @Test("A 404 catalog keeps the endpoint reachable with a failed catalog")
    func probeCatalog404() async {
        let discovery = DiscoverySource()
        discovery.info = testInfo()
        let probe = ProbeStub()
        probe.behavior = .catalogMissing
        let store = makeStore(discovery: discovery, probe: probe)

        await store.refreshNow()

        #expect(store.endpoint?.health == .reachable)
        #expect(store.endpoint?.modelCatalog == .failed)
    }

    @Test("A connection failure flips health to unreachable and the catalog to failed")
    func probeTransportFailure() async {
        let discovery = DiscoverySource()
        discovery.info = testInfo()
        let probe = ProbeStub()
        probe.behavior = .transportFailure
        let store = makeStore(discovery: discovery, probe: probe)

        await store.refreshNow()

        #expect(store.endpoint?.health == .unreachable)
        #expect(store.endpoint?.modelCatalog == .failed)
    }

    @Test("Retrying health from an unreachable endpoint performs a real re-probe")
    func liveHealthRetryReprobes() async {
        let discovery = DiscoverySource()
        discovery.info = testInfo()
        let probe = ProbeStub()
        probe.behavior = .transportFailure
        let store = makeStore(discovery: discovery, probe: probe)

        await store.refreshNow()
        #expect(store.endpoint?.health == .unreachable)

        // Endpoint recovers; the same view-facing retry method now reprobes live.
        probe.behavior = .succeeds(["gpt-oss-20b"])
        store.retryPreviewHealth()
        #expect(store.endpoint?.health == .checking)  // synchronously optimistic
        // Let the spawned probe task land.
        for _ in 0..<200 where store.endpoint?.health == .checking {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.endpoint?.health == .reachable)
        #expect(store.endpoint?.availableModelIDs == ["gpt-oss-20b"])
        #expect(probe.probeCount == 2)
    }

    @Test("Catalog retry performs a real re-request in live mode")
    func liveCatalogRetryReprobes() async {
        let discovery = DiscoverySource()
        discovery.info = testInfo()
        let probe = ProbeStub()
        probe.behavior = .catalogMissing
        let store = makeStore(discovery: discovery, probe: probe)

        await store.refreshNow()
        #expect(store.endpoint?.modelCatalog == .failed)

        probe.behavior = .succeeds(["gpt-oss-20b"])
        store.retryPreviewModelCatalog()
        for _ in 0..<200 where probe.probeCount == 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.endpoint?.availableModelIDs == ["gpt-oss-20b"])
    }

    // MARK: Monitoring

    @Test("Monitoring adopts the endpoint disappearing from disk")
    func monitoringAdoptsDisappearance() async {
        let discovery = DiscoverySource()
        discovery.info = testInfo()
        let probe = ProbeStub()
        let store = LocalAPIStore.live(
            discoveryReader: { discovery.info },
            processIdentityReader: { pid in
                guard discovery.info?.pid == pid else { return nil }
                return discovery.info?.processIdentity
            },
            pollInterval: .milliseconds(20),
            clientFactory: { info in probe.makeClient(for: info) }
        )
        store.startMonitoring()
        defer { store.stopMonitoring() }

        // Wait for the first probe cycle to reach a settled state.
        for _ in 0..<300 where probe.probeCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.endpoint?.health == .reachable)

        discovery.info = nil
        for _ in 0..<300 {
            if case .stopped = store.state { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard case .stopped = store.state else {
            Issue.record("Expected .stopped once the discovery record disappears, got \(store.state)")
            return
        }
    }

    @Test("Monitoring does not run for fixture stores")
    func fixtureMonitoringIsInert() async {
        let store = LocalAPIStore(fixture: .active)
        store.startMonitoring()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(store.endpoint?.health == .reachable)  // fixture value, unchanged
        store.stopMonitoring()
    }
}
