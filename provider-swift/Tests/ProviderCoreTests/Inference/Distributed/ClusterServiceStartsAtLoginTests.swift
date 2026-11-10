import Foundation
import Testing
@testable import ProviderCore

@Suite("A Mac's cluster service tells the other Mac whether it starts at login")
struct ClusterServiceStartsAtLoginTests {
    @Test("P2-11: at login only under its login agent's supervisor with the agent installed; the field travels, nil from older builds")
    func startsAtLoginIsReported() throws {
        let supervised = [ClusterSupervisionFiles.healthPathEnvironmentKey: "/private/tmp/health.json"]
        #expect(ClusterServiceAgent.startsAtLogin(environment: supervised, installedAgents: { ["dev.darkbloom.cluster"] }))
        #expect(!ClusterServiceAgent.startsAtLogin(environment: [:], installedAgents: { ["dev.darkbloom.cluster"] }))
        #expect(!ClusterServiceAgent.startsAtLogin(environment: supervised, installedAgents: { [] }))
        let older = Data(#"{"serving":true,"sessionLeader":false,"child":{"running":true,"starts":1}}"#.utf8)
        var status = try JSONDecoder().decode(ClusterServiceStatus.self, from: older)
        #expect(status.startsAtLogin == nil, "an older build's status says nothing about login")
        status.startsAtLogin = false
        let sent = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        #expect(sent.contains(#""startsAtLogin":false"#), "\(sent)")
        #expect(try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(sent.utf8)).startsAtLogin == false)
    }
}
