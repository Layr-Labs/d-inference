import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote

@main enum InstalledFakeOwner {
    static func main() throws {
        guard CommandLine.arguments.count == 5, let rank = Int(CommandLine.arguments[3]) else { exit(64) }
        let worker = URL(fileURLWithPath: CommandLine.arguments[1]), directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let behavior = CommandLine.arguments[4]
        if behavior == "no-proof" { return }
        let filtered = behavior == "drop-release"
        let pipe = Pipe(), finished = DispatchGroup()
        if filtered {
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                var buffered = Data()
                while true {
                    let bytes = pipe.fileHandleForReading.availableData
                    if bytes.isEmpty { break }; buffered.append(bytes)
                    while let index = buffered.firstIndex(of: 10) {
                        let line = Data(buffered.prefix(through: index)); buffered.removeSubrange(...index)
                        if let frame = try? OwnerWire.decode(line, commandStream: false), frame.kind == "released" { continue }
                        try! FileHandle.standardOutput.write(contentsOf: line)
                    }
                }
            }
        }
        defer { try? pipe.fileHandleForWriting.close(); if filtered { finished.wait() } }
        try ClusterWorkerOwnerService.serveConfigured(input: STDIN_FILENO,
            output: filtered ? pipe.fileHandleForWriting.fileDescriptor : STDOUT_FILENO,
            clusterID: "installed-fixture", leaseDirectory: directory, maximumLifetimeNanoseconds: 20_000_000_000,
            bootstrapProfile: .mesh2, binding: { epoch, lease, incarnation in
                guard epoch == fixtureIdentity.membershipEpoch else { throw ClusterOwnerStateError.invalid("Fixture epoch differs") }
                return try .init(clusterID: "installed-fixture", ownerIncarnation: incarnation, leaseID: lease,
                    identity: fixtureIdentity, profile: fixtureProfile, rank: rank, executionPlanSHA256: fixturePlan)
            }, native: { binding, deadline, attachment in
                guard let attachment else { throw ClusterOwnerStateError.invalid("Fixture attachment missing") }
                return try .init(launch: .init(executable: worker,
                    arguments: [String(rank), "bootstrap"] + attachment.workerArguments,
                    environment: ["FIXTURE_READY_PATH": ProcessInfo.processInfo.environment["FIXTURE_READY_PATH"]!]),
                    expectedIdentity: binding.identity, rank: rank, profile: binding.profile,
                    executionPlanSHA256: binding.executionPlanSHA256, startupDeadline: deadline, lifetimeDeadline: deadline)
            })
        if behavior == "nonzero-owner" { exit(7) }
    }
}
