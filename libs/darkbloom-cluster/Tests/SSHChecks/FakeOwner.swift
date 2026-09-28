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
        if behavior == "inflight-round" {
            let pipe = try ClusterOwnerPipe(input: STDIN_FILENO, output: STDOUT_FILENO, readingCommands: true)
            let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
            guard let line = try pipe.read(until: deadline) else { return }
            let open = try OwnerWire.decode(line, commandStream: true), incarnation = UUID(), launch = UUID()
            let binding = try ClusterOwnerBinding(clusterID: "cpu-test", ownerIncarnation: incarnation, leaseID: open.lease,
                identity: fixtureIdentity, profile: fixtureProfile, rank: rank, executionPlanSHA256: fixturePlan)
            let lease = try ClusterDeviceLease(directoryURL: directory)
            try lease.record(binding: binding, launchID: launch)
            let child = try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [String(rank), "hang"], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: rank, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: deadline, lifetimeDeadline: deadline)
            try child.launch()
            _ = try child.receiveWorkerEvent(until: deadline)
            try pipe.write(OwnerWire(kind: "hello", epoch: open.epoch, lease: open.lease, incarnation: incarnation, sequence: 0,
                launchID: launch, bootstrapProfile: .mesh2).encoded(commandStream: false), until: deadline)
            guard let stop = try pipe.read(until: deadline), try OwnerWire.decode(stop, commandStream: true).kind == "fence" else {
                child.requestNativeCleanup(); child.waitForNativeCleanup(); return
            }
            // Controlled transit: this valid round arrives after local invalidation.
            try pipe.write(OwnerWire(kind: "bootstrapRound", epoch: open.epoch, lease: open.lease, incarnation: incarnation, sequence: 1,
                bootstrapSequence: 0, bootstrapBytes: Data([2, 0, 0, 0])).encoded(commandStream: false), until: deadline)
            child.requestNativeCleanup(); child.waitForNativeCleanup()
            guard case .signalled(let signal) = child.termination else { throw ClusterOwnerStateError.invalid("Expected actual native signal exit") }
            try pipe.write(OwnerWire(kind: "terminal", epoch: open.epoch, lease: open.lease, incarnation: incarnation, sequence: 2,
                launchID: launch, termination: .signalled(signal: signal)).encoded(commandStream: false), until: deadline)
            guard let release = try pipe.read(until: deadline), try OwnerWire.decode(release, commandStream: true).kind == "release" else { return }
            try lease.resolve()
            try pipe.write(OwnerWire(kind: "released", epoch: open.epoch, lease: open.lease, incarnation: incarnation, sequence: 3)
                .encoded(commandStream: false), until: deadline)
            return
        }
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
        try ClusterWorkerOwnerService.serveConfigured(input: STDIN_FILENO, output: STDOUT_FILENO,
            clusterID: "cpu-test", leaseDirectory: directory, maximumLifetimeNanoseconds: 20_000_000_000,
            bootstrapProfile: behavior.hasPrefix("bootstrap") ? .mesh2 : nil,
            binding: { epoch, lease, incarnation in
                guard epoch == fixtureIdentity.membershipEpoch else { throw ClusterOwnerStateError.invalid("Fake epoch differs") }
                return try .init(clusterID: "cpu-test", ownerIncarnation: incarnation, leaseID: lease,
                    identity: fixtureIdentity, profile: fixtureProfile, rank: rank, executionPlanSHA256: fixturePlan)
            }, native: { binding, deadline, attachment in
                try .init(launch: .init(executable: executable, arguments: [String(rank), behavior] + (attachment?.workerArguments ?? []), environment: [:]),
                    expectedIdentity: binding.identity, rank: rank, profile: binding.profile,
                    executionPlanSHA256: binding.executionPlanSHA256,
                    startupDeadline: min(deadline, DispatchTime.now().uptimeNanoseconds + 3_000_000_000), lifetimeDeadline: deadline)
            })
    }
}
