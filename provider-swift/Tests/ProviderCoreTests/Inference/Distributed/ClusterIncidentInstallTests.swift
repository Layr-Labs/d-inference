import DarkbloomClusterRemote
import Foundation
import ProviderCore
import Testing

@Suite("Cluster incident log: each install sees its own incidents")
struct ClusterIncidentInstallTests {
    @Test("A-13: records carry the install; each install's feed holds its own, and older records count as production")
    func feedsAreScopedToTheInstall() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("incidents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("incidents.json")
        let draft = ClusterIncidentDraft(severity: .warn, source: "test", stateCode: .peerLost, message: "a part ended")
        try ClusterIncidentLog(file: file).record(draft)                    // an older record: no install
        try ClusterIncidentLog(file: file, install: "dev").record(draft)
        try ClusterIncidentLog(file: file, install: "prod").record(draft)
        #expect(ClusterIncidentLog(file: file, install: "prod").feed().incidents.count == 2)
        #expect(ClusterIncidentLog(file: file, install: "dev").feed().incidents.count == 1)
        #expect(ClusterIncidentLog(file: file).feed().incidents.count == 3)
        #expect(ClusterIncidentLog.unstampedInstall == BuildEnvironment.prod.rawValue, "an unstamped record is production's")
        #expect(ClusterObservability(homeDirectory: folder, hostNames: [], userNames: []).incidents.install
                == BuildEnvironment.current.rawValue, "the provider's log stamps and reads this build's install")
    }
}
