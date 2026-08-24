import Foundation
import Testing
@testable import ProviderCoreFoundation

@Suite("Provider service labels keep app + CLI pointed at the same launchd entry")
struct DarkbloomServiceLabelsTests {
    @Test("The canonical label and plist path are pinned")
    func labelPinned() {
        #expect(DarkbloomServiceLabels.providerLaunchAgent == "io.darkbloom.provider")
        #expect(DarkbloomServiceLabels.providerLaunchAgentLegacy == ["dev.darkbloom.provider"])
        #expect(DarkbloomServiceLabels.providerLaunchAgentSupported
            == ["io.darkbloom.provider", "dev.darkbloom.provider"])
        let path = DarkbloomServiceLabels.launchAgentPlistPath(
            label: DarkbloomServiceLabels.providerLaunchAgent)
        #expect(path.lastPathComponent == "io.darkbloom.provider.plist")
        #expect(path.path.contains("/Library/LaunchAgents/"))
    }
}

@Suite("Local endpoint discovery contract")
struct LocalEndpointInfoTests {
    @Test("legacy local.json remains decodable but has no trusted identity")
    func decodeLegacyDiscoveryFile() throws {
        let json = """
        {
          "base_url": "http://127.0.0.1:8000/v1",
          "api_key": "dk-local-abc",
          "host": "127.0.0.1",
          "port": 8000,
          "pid": 4242,
          "version": "0.8.5",
          "updated_at": "2026-08-18T22:00:00Z"
        }
        """
        let info = try JSONDecoder().decode(LocalEndpointInfo.self, from: Data(json.utf8))
        #expect(info.baseURL == "http://127.0.0.1:8000/v1")
        #expect(info.apiKey == "dk-local-abc")
        #expect(info.port == 8000)
        #expect(info.pid == 4242)
        #expect(info.processIdentity == nil)
        #expect(!LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info,
            readIdentity: { _ in ProcessIdentity(pid: 4242, startTimeMicros: 100) }
        ))
    }

    @Test("PID plus kernel start identity is required for live discovery")
    func validatesExactProcessIdentity() throws {
        let json = """
        {
          "base_url": "http://127.0.0.1:8000/v1",
          "api_key": "dk-local-abc",
          "host": "127.0.0.1",
          "port": 8000,
          "pid": 4242,
          "process_identity": {
            "pid": 4242,
            "start_time_micros": 100
          },
          "version": "0.8.5",
          "updated_at": "2026-08-18T22:00:00Z"
        }
        """
        let info = try JSONDecoder().decode(LocalEndpointInfo.self, from: Data(json.utf8))
        let recorded = try #require(info.processIdentity)

        #expect(LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info,
            readIdentity: { _ in recorded }
        ))
        #expect(!LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info,
            readIdentity: {
                ProcessIdentity(pid: $0, startTimeMicros: recorded.startTimeMicros + 1)
            }
        ))
        #expect(!LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info,
            readIdentity: { _ in nil }
        ))

        let encoded = String(
            decoding: try JSONEncoder().encode(info),
            as: UTF8.self
        )
        #expect(encoded.contains(#""start_time_micros":100"#))
        #expect(!encoded.contains("startTimeMicros"))
    }

    @Test("An unspecified bind dials loopback (0.0.0.0 is not dialable)")
    func unspecifiedBindDialsLoopback() {
        let identity = ProcessIdentity(pid: 1, startTimeMicros: 100)
        let info = LocalEndpointInfo(
            host: "0.0.0.0", port: 9000, apiKey: "", version: "1",
            pid: identity.pid, processIdentity: identity, updatedAt: "")
        #expect(info.baseURL == "http://127.0.0.1:9000/v1")
        let emptyHost = LocalEndpointInfo(
            host: "", port: 9000, apiKey: "", version: "1",
            pid: identity.pid, processIdentity: identity, updatedAt: "")
        #expect(emptyHost.baseURL == "http://127.0.0.1:9000/v1")
    }
}
