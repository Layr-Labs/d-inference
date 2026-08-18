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
    @Test("local.json decodes the documented shape")
    func decodeDiscoveryFile() throws {
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
    }

    @Test("An unspecified bind dials loopback (0.0.0.0 is not dialable)")
    func unspecifiedBindDialsLoopback() {
        let info = LocalEndpointInfo(
            host: "0.0.0.0", port: 9000, apiKey: "", version: "1", pid: 1, updatedAt: "")
        #expect(info.baseURL == "http://127.0.0.1:9000/v1")
        let emptyHost = LocalEndpointInfo(
            host: "", port: 9000, apiKey: "", version: "1", pid: 1, updatedAt: "")
        #expect(emptyHost.baseURL == "http://127.0.0.1:9000/v1")
    }
}
