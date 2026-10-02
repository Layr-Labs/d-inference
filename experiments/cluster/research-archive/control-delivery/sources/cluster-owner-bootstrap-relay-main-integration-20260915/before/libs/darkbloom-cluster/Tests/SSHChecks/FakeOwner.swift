import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote

@main struct FakeOwner {
    static func main() throws {
        guard CommandLine.arguments.count == 5, let rank = Int(CommandLine.arguments[3]) else { exit(64) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let behavior = CommandLine.arguments[4]
        if behavior == "transport-exit" { return }
        if behavior == "wrong-terminal" {
            let pipe = try ClusterOwnerPipe(input: STDIN_FILENO, output: STDOUT_FILENO, readingCommands: true)
            let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            guard let line = try pipe.read(until: end) else { return }
            let open = try OwnerWire.decode(line, commandStream: true), inc = UUID(), launch = UUID()
            try pipe.write(OwnerWire(kind: "hello", epoch: open.epoch, lease: open.lease, incarnation: inc,
                sequence: 0, launchID: launch).encoded(commandStream: false), until: end)
            try pipe.write(OwnerWire(kind: "terminal", epoch: open.epoch, lease: open.lease, incarnation: UUID(),
                sequence: 1, launchID: launch, termination: .exited(status: 0)).encoded(commandStream: false), until: end)
            return
        }
        try ClusterWorkerOwnerService.serve(input: STDIN_FILENO, output: STDOUT_FILENO,
            clusterID: "cpu-test", leaseDirectory: directory, maximumLifetimeNanoseconds: 20_000_000_000,
            binding: { epoch, lease, incarnation in
                guard epoch == fixtureIdentity.membershipEpoch else { throw ClusterOwnerStateError.invalid("Fake epoch differs") }
                return try .init(clusterID: "cpu-test", ownerIncarnation: incarnation, leaseID: lease,
                    identity: fixtureIdentity, profile: fixtureProfile, rank: rank, executionPlanSHA256: fixturePlan)
            }, native: { binding, deadline in
                try .init(launch: .init(executable: executable, arguments: [String(rank), behavior], environment: [:]),
                    expectedIdentity: binding.identity, rank: rank, profile: binding.profile,
                    executionPlanSHA256: binding.executionPlanSHA256,
                    startupDeadline: min(deadline, DispatchTime.now().uptimeNanoseconds + 3_000_000_000), lifetimeDeadline: deadline)
            })
    }
}
