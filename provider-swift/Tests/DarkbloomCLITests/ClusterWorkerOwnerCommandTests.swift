import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Installed worker-owner CLI")
struct ClusterWorkerOwnerCommandTests {
    @Test("fixed stdio command parses without IO")
    func fixedCommand() throws {
        let command = try Cluster.WorkerOwner.parse(["--stdio"])
        #expect(command.stdio)
        #expect(try Darkbloom.parseAsRoot(["cluster", "worker-owner", "--stdio"]) is Cluster.WorkerOwner)
    }

    @Test("worker-owner does not accept runtime settings or an alternate config path")
    func refusedOverrides() {
        for arguments in [[], ["--stdio", "--config", "/tmp/other"], ["--stdio", "--model-dir", "/model"],
            ["--stdio", "--environment", "KEY=VALUE"], ["--stdio", "--capacity", "1"],
            ["--stdio", "--ready-template", "fixture"], ["--stdio", "--lease-directory", "/tmp/other"]] {
            #expect(throws: (any Error).self) { _ = try Cluster.WorkerOwner.parse(arguments) }
        }
    }
}
