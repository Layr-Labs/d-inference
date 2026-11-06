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

    @Test("A-13: each install keeps its own file in its own folder, which an older build never reads or rewrites")
    func nonProductionInstallsHaveTheirOwnFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("incident-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let production = BuildEnvironment.prod.installDirectory(home: home), devnet = BuildEnvironment.dev.installDirectory(home: home)
        let shared = ClusterIncidentLog.defaultFile(installDirectory: production)
        #expect(shared.path == home.path + "/.darkbloom/cluster/incidents.json", "production's log is where it always was")
        #expect(ClusterIncidentLog.defaultFile(installDirectory: production, install: "prod") == shared)
        #expect(ClusterIncidentLog.defaultFile(installDirectory: production, install: nil) == shared)
        let dev = ClusterIncidentLog.defaultFile(installDirectory: devnet, install: "dev")
        #expect(dev.path == home.path + "/.darkbloom-dev/cluster/incidents.dev.json", "DevNet's is in DevNet's own folder")
        let draft = ClusterIncidentDraft(severity: .warn, source: "test", stateCode: .peerLost, message: "a part ended")
        try ClusterIncidentLog(file: dev, install: "dev").record(draft)
        // An older build knows only production's file: what it records, and each rewrite, stays there.
        try ClusterIncidentLog(file: shared).record(draft)
        try ClusterIncidentLog(file: shared).record(draft)
        let devFeed = ClusterIncidentLog(file: dev, install: "dev").feed()
        #expect(devFeed.incidents.count == 1)
        #expect(devFeed.incidents.first?.install == "dev")
        #expect(ClusterIncidentLog(file: shared, install: "prod").feed().incidents.count == 2)
        #expect(ClusterIncidentLog(file: shared).feed().incidents.count == 2, "production's file holds none of DevNet's records")
        #expect(ClusterObservabilitySnapshot.read(installDirectory: devnet, install: "dev").incidents?.total == 1)
        #expect(ClusterObservabilitySnapshot.read(installDirectory: production, install: "prod").incidents?.total == 2)
        let this = ClusterIncidentLog.forThisInstall(homeDirectory: home)
        #expect(this.file == ClusterIncidentLog.defaultFile(installDirectory: BuildEnvironment.current.installDirectory(home: home),
                                                            install: BuildEnvironment.current.rawValue))
        #expect(this.install == BuildEnvironment.current.rawValue)
    }
}
