import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterSecurity
@testable import DarkbloomClusterRemote

@main struct ReleaseDrainChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { Darwin.exit(64) }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(30)
        let owner = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        #if OWNER_RELEASE_EOF_DRAIN
        let cases = ["valid", "missing", "wrong", "abnormal"]
        #else
        let cases = ["valid"]
        #endif
        for behavior in cases { try run(owner: owner, root: root, behavior: behavior) }
        #if OWNER_RELEASE_EOF_DRAIN
        print("owner-release-eof-drain: 4 actual-owner/child groups passed")
        #else
        print("owner-release-eof-drain: baseline buffered-ACK loss reproduced")
        #endif
        alarm(0)
    }

    static func run(owner: URL, root: URL, behavior: String) throws {
        let directory = root.appendingPathComponent(behavior)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let start = try drainStart(), hold = ReleaseDrainHold(directory: directory)
        let begin = DispatchTime.now().uptimeNanoseconds, deadline = begin + 5_000_000_000
        let relay = try ClusterOwnerNativeKeyRelay(start: start, deadlineUptimeNanoseconds: deadline,
            profile: .nativeKeyPreludeMesh2,
            exchange: { _, _ in throw ReleaseDrainFailure.invalid("Forbidden Ready child must not bootstrap") },
            cancel: { hold.cancel() })
        let endpoint = try ClusterRemoteWorkerEndpoint(transport: .init(executable: owner,
            arguments: [directory.path, behavior], environment: ["PATH": "/usr/bin:/bin"]),
            clusterID: "cpu-test", expectedIdentity: fixtureIdentity, profile: fixtureProfile, rank: 0,
            executionPlanSHA256: fixturePlan, lifetimeDeadlineUptimeNanoseconds: deadline, nativeKeyRelay: relay)
        let released = endpoint.waitForOwnerReleased(deadline: deadline)
        try drainRequire(hold.ownerExitedBeforeReturn, "Fixture did not place owner exit inside terminal callback")
        try drainRequire(endpoint.nativeCleanupObserved && endpoint.readiness == nil, "Actual cleanup missing or forbidden Ready escaped")
        let nativePID = try drainPID("native-pid", in: directory)
        try drainRequire(Darwin.kill(nativePID, 0) == -1 && errno == ESRCH, "Actual CPU native child survived")
        let journal = try Data(contentsOf: directory.appendingPathComponent("native-device.lease"))
        try drainRequire(journal.isEmpty, "Actual Service did not resolve its private journal")
        let gate = try ClusterDeviceExclusion(directoryURL: directory)
        withExtendedLifetime(gate) {}
        let actual = try Data(contentsOf: directory.appendingPathComponent("actual-service-released.jsonl"))
        let frame = try OwnerWire.decode(actual, commandStream: false)
        try drainRequire(frame.kind == "released" && frame.lease == start.leaseID && frame.incarnation == start.ownerIncarnation,
            "Fixture did not retain the actual current-owner release ACK")
        #if OWNER_RELEASE_EOF_DRAIN
        if behavior == "valid" {
            try drainRequire(released && endpoint.ownerDeviceLeaseReleasedObserved && endpoint.ownerTermination == .exited(0),
                "Buffered actual release ACK was lost after owner exit")
        } else if behavior == "abnormal" {
            try drainRequire(!released && endpoint.ownerDeviceLeaseReleasedObserved && endpoint.ownerTermination == .exited(9),
                "Abnormal owner exit was accepted")
        } else {
            try drainRequire(!released && !endpoint.ownerDeviceLeaseReleasedObserved && endpoint.ownerTermination == .exited(0),
                "Missing or wrong ACK was accepted from local journal/exit alone")
        }
        #else
        try drainRequire(!released && !endpoint.ownerDeviceLeaseReleasedObserved && endpoint.ownerTermination == .exited(0),
            "Baseline no longer reproduces its buffered ACK loss")
        #endif
        let row: [String: Any] = ["behavior": behavior, "ownerExitedDuringTerminalCallback": hold.ownerExitedBeforeReturn,
            "nativeCleanupObserved": endpoint.nativeCleanupObserved, "ownerACKObserved": endpoint.ownerDeviceLeaseReleasedObserved,
            "released": released, "nativePID": nativePID, "journalEmpty": journal.isEmpty,
            "elapsedNanoseconds": DispatchTime.now().uptimeNanoseconds - begin]
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]).write(
            to: directory.appendingPathComponent("result.json"), options: .withoutOverwriting)
    }
}
