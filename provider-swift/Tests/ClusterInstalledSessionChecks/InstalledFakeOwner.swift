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
        try ClusterWorkerOwnerService.serveKeyed(input: STDIN_FILENO,
            output: filtered ? pipe.fileHandleForWriting.fileDescriptor : STDOUT_FILENO,
            clusterID: "installed-fixture", leaseDirectory: directory,
            // The installed selection: the native key prelude, then the mesh
            // rounds, relayed by the session; this stand-in admits the
            // committed start of its own epoch and rank only.
            bootstrapProfile: .nativeKeyPreludeMesh2, authorizeNativeStart: { start in
                guard start.common.epoch == fixtureIdentity.membershipEpoch, start.rank == rank else {
                    throw ClusterOwnerStateError.invalid("Fixture native start differs")
                }
            }, binding: { epoch, lease, incarnation in
                guard epoch == fixtureIdentity.membershipEpoch else { throw ClusterOwnerStateError.invalid("Fixture epoch differs") }
                return try .init(clusterID: "installed-fixture", ownerIncarnation: incarnation, leaseID: lease,
                    identity: fixtureIdentity, profile: fixtureProfile, rank: rank, executionPlanSHA256: fixturePlan)
            }, native: { binding, deadline, attachment, trust in
                // The real owner service has already checked the credential's
                // epoch/rank. This CPU worker reports only synthetic readiness.
                if let trust {
                    let value = try ClusterWorkerCodec.decodeDataPlaneTrust(trust)
                    guard value.rank == rank, value.membershipEpoch == fixtureIdentity.membershipEpoch else {
                        throw ClusterOwnerStateError.invalid("Fixture credential differs")
                    }
                }
                // The combined profile's attachment reaches the stand-in worker
                // exactly as it reaches an installed worker.
                guard let attachment, attachment.profile == .nativeKeyPreludeMesh2, attachment.nativeStart?.rank == rank else {
                    throw ClusterOwnerStateError.invalid("Fixture received no or another bootstrap attachment")
                }
                return try .init(launch: .init(executable: worker,
                    // "workers:a,b" selects the stand-in worker behaviour per rank.
                    arguments: [String(rank), behavior.hasPrefix("workers:")
                        ? String(behavior.dropFirst(8).split(separator: ",")[rank]) : "normal"] + attachment.workerArguments,
                    environment: ["FIXTURE_READY_PATH": ProcessInfo.processInfo.environment["FIXTURE_READY_PATH"]!]),
                    expectedIdentity: binding.identity, rank: rank, profile: binding.profile,
                    executionPlanSHA256: binding.executionPlanSHA256, startupDeadline: deadline, initialLeaseDeadline: deadline)
            })
        if behavior == "nonzero-owner" { exit(7) }
    }
}
