import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote

private final class OwnedFixtureChild: @unchecked Sendable {
    private let lock = NSLock()
    private var child: ClusterWorkerProcess?
    func remember(_ child: ClusterWorkerProcess) { lock.withLock { self.child = child } }
    func record() throws -> Data {
        guard let value = lock.withLock({ child }), value.nativeCleanupObserved,
              value.termination == .exited(7) else { throw OwnerWire.invalid("Missing actual child failure") }
        return value.diagnosticTail
    }
}

/// Runs the real owner service and real failing child. The test opens the gate
/// only after observing released, making the late-stderr regression deterministic.
@main struct LateDiagnosticOwner {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { Darwin.exit(64) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let behavior = CommandLine.arguments[3]
        let child = OwnedFixtureChild()
        try ClusterWorkerOwnerService.serveConfigured(input: STDIN_FILENO, output: STDOUT_FILENO,
            clusterID: "cpu-test", leaseDirectory: directory, maximumLifetimeNanoseconds: 10_000_000_000,
            binding: { epoch, lease, incarnation in
                guard epoch == fixtureIdentity.membershipEpoch else { throw OwnerWire.invalid("Fixture epoch differs") }
                return try .init(clusterID: "cpu-test", ownerIncarnation: incarnation, leaseID: lease,
                    identity: fixtureIdentity, profile: fixtureProfile, rank: 0, executionPlanSHA256: fixturePlan)
            }, native: { binding, deadline, _ in
                let value = try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [], environment: [:]),
                    expectedIdentity: binding.identity, rank: 0, profile: binding.profile,
                    executionPlanSHA256: binding.executionPlanSHA256, startupDeadline: deadline, lifetimeDeadline: deadline)
                child.remember(value)
                return value
            })
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
        let gate = directory.appendingPathComponent("emit-after-ack")
        while !FileManager.default.fileExists(atPath: gate.path) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { Darwin.exit(65) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        let bytes = try child.record()
        try bytes.write(to: directory.appendingPathComponent("emitted-diagnostic"), options: .withoutOverwriting)
        try FileHandle.standardError.write(contentsOf: bytes)
        if behavior == "abnormal" { Darwin.exit(9) }
        if behavior == "hang" {
            signal(SIGTERM, SIG_IGN)
            while true { Thread.sleep(forTimeInterval: 0.05) }
        }
    }
}
