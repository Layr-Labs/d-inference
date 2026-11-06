import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterSecurity
@testable import DarkbloomClusterRemote

private final class ReleaseDrainPump: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false
    let done = DispatchGroup()
    init() { done.enter() }
    var succeeded: Bool { lock.withLock { complete } }
    func run(input: Int32, directory: URL, behavior: String, deadline: UInt64) {
        defer { done.leave() }
        do {
            let pipe = try ClusterOwnerPipe(input: input, output: STDOUT_FILENO, readingCommands: false)
            var observed: [String] = []
            while DispatchTime.now().uptimeNanoseconds < deadline {
                guard let raw = try pipe.read(until: min(deadline, DispatchTime.now().uptimeNanoseconds + 20_000_000)) else { continue }
                let frame = try OwnerWire.decode(raw, commandStream: false)
                observed.append(frame.kind)
                if frame.kind == "released" {
                    try drainRequire(observed == ["hello", "terminal", "released"], "Real Service frame order differs")
                    try raw.write(to: directory.appendingPathComponent("actual-service-released.jsonl"), options: .withoutOverwriting)
                    switch behavior {
                    case "missing": break
                    case "wrong":
                        let changed = OwnerWire(kind: "released", epoch: frame.epoch, lease: frame.lease,
                            incarnation: UUID(), sequence: frame.sequence)
                        try pipe.write(changed.encoded(commandStream: false), until: deadline)
                    case "valid", "abnormal": try pipe.write(raw, until: deadline)
                    default: throw ReleaseDrainFailure.invalid("Unknown ACK behavior")
                    }
                    lock.withLock { complete = true }
                    return
                }
                try drainRequire(frame.kind == "hello" || frame.kind == "terminal", "Unexpected native Ready/event escaped owner")
                try pipe.write(raw, until: deadline)
            }
        } catch { }
    }
}

// One actual Service-owned CPU native child, with a test-only output relay.
// Negative cases change only the already emitted release ACK or owner exit code.
@main struct ReleaseDrainOwner {
    static func main() throws {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(8)
        let args = CommandLine.arguments
        if args.count == 3 && args[1] == "--worker" {
            let directory = URL(fileURLWithPath: args[2])
            try drainWrite("\(getpid())\n", "native-pid", in: directory)
            let start = try drainStart()
            let ready = ClusterWorkerReady(identity: fixtureIdentity, rank: 0, profile: fixtureProfile,
                executionPlanSHA256: fixturePlan, requestCapacityBytes: 4096)
            let frame = ClusterWorkerEventFrame(membershipEpoch: start.common.epoch, sequence: 0,
                requestID: nil, event: .ready(ready))
            try FileHandle.standardOutput.write(contentsOf: ClusterWorkerCodec.encode(frame))
            return
        }
        guard args.count == 3 else { Darwin.exit(64) }
        let directory = URL(fileURLWithPath: args[1]), behavior = args[2]
        try drainRequire(["valid", "missing", "wrong", "abnormal"].contains(behavior), "Unknown fixture mode")
        let start = try drainStart(), pipe = Pipe(), pump = ReleaseDrainPump()
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        try drainWrite("\(getpid())\n", "owner-pid", in: directory)
        DispatchQueue(label: "fixture.owner-release-wire").async {
            pump.run(input: pipe.fileHandleForReading.fileDescriptor, directory: directory, behavior: behavior, deadline: deadline)
        }
        let executable = URL(fileURLWithPath: args[0])
        try ClusterWorkerOwnerService.serveConfigured(input: STDIN_FILENO,
            output: pipe.fileHandleForWriting.fileDescriptor, clusterID: "cpu-test", leaseDirectory: directory,
            maximumLifetimeNanoseconds: 5_000_000_000, bootstrapProfile: .nativeKeyPreludeMesh2,
            authorizeNativeStart: { value in
                try drainRequire(value.canonicalBytes == start.canonicalBytes, "Fixture start differs")
            }, binding: { epoch, lease, incarnation in
                try .init(clusterID: "cpu-test", ownerIncarnation: incarnation, leaseID: lease,
                    identity: fixtureIdentity, profile: fixtureProfile, rank: 0, executionPlanSHA256: fixturePlan)
            }, native: { binding, end, attachment in
                try drainRequire(attachment?.profile == .nativeKeyPreludeMesh2, "Missing actual owner attachment")
                return try ClusterWorkerProcess(launch: .init(executable: executable,
                    arguments: ["--worker", directory.path], environment: ["PATH": "/usr/bin:/bin"]),
                    expectedIdentity: binding.identity, rank: binding.rank, profile: binding.profile,
                    executionPlanSHA256: binding.executionPlanSHA256, startupDeadline: end, lifetimeDeadline: end)
            })
        try drainRequire(pump.done.wait(timeout: .init(uptimeNanoseconds: deadline)) == .success && pump.succeeded,
            "Real Service release was not relayed")
        try drainWrite("returned\n", "service-returned", in: directory)
        try pipe.fileHandleForWriting.close(); try pipe.fileHandleForReading.close()
        if behavior == "abnormal" { Darwin.exit(9) }
    }
}
