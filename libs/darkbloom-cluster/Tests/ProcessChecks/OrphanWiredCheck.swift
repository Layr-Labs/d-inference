import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

// The orphan-wired guard's decision and probes, and the owner's kill margin
// sized to planned bytes. The process probe is checked against real processes:
// copies of this binary under "darkbloom-..." names that sleep, exit into
// zombies, or list what they see from below a "darkbloom-..." ancestor.

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw Failure(description: message()) }
}
private let gib: UInt64 = 1 << 30

private func spawn(_ path: String, _ arguments: [String]) throws -> pid_t {
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, path, nil, nil, argv, environ)
    guard status == 0 else { throw Failure(description: "spawn \(path): \(status)") }
    return pid
}

private func copy(_ name: String, into directory: URL) throws -> String {
    let target = directory.appendingPathComponent(name).path
    try FileManager.default.copyItem(atPath: CommandLine.arguments[0], toPath: target)
    return target
}

@main struct OrphanWiredCheck {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count >= 2 {
            switch arguments[1] {
            case "--sleep": sleep(30); exit(0)
            case "--exit": exit(0)
            case "--list":
                print(ClusterOrphanWiredGuard.otherDarkbloomProcesses().joined(separator: ",")); exit(0)
            case "--spawn-lister":
                // A "darkbloom-..." ancestor of the lister, as an owner is of its worker.
                guard let pid = try? spawn(arguments[2], ["--list"]) else { exit(3) }
                var status: Int32 = 0; waitpid(pid, &status, 0); exit(0)
            default: break
            }
        }
        do {
            try decisions()
            try probes()
            try killMargins()
            print("{\"passed\":true,\"groups\":3,\"orphanWiredGuard\":true,\"killMarginFromPlannedBytes\":true,\"modelOrGPUExecution\":false}")
        } catch {
            FileHandle.standardError.write(Data("FAILED \(error)\n".utf8)); exit(1)
        }
    }

    static func decisions() throws {
        try require(ClusterOrphanWiredGuard.idleBaselineBytes(physicalBytes: 256 * gib) == 256 * gib / 10 + 1, "256 GiB baseline")
        try require(ClusterOrphanWiredGuard.idleBaselineBytes(physicalBytes: 128 * gib) == 16 * gib, "128 GiB baseline")
        try require(ClusterOrphanWiredGuard.idleBaselineBytes(physicalBytes: 64 * gib) == 16 * gib, "64 GiB baseline")
        // Idle figures measured on the pair are clear.
        for (wired, physical) in [(UInt64(8.9 * Double(gib)), 256 * gib), (UInt64(14.6 * Double(gib)), 256 * gib),
                                  (UInt64(5.2 * Double(gib)), 128 * gib), (UInt64(9.9 * Double(gib)), 128 * gib)] {
            guard case .clear = ClusterOrphanWiredGuard.decide(wiredBytes: wired, physicalBytes: physical, otherDarkbloomProcesses: []) else {
                throw Failure(description: "idle \(wired) on \(physical) was not clear")
            }
        }
        // The owner's orphans are refused, naming the measured value and the baseline.
        guard case .refused(let message) = ClusterOrphanWiredGuard.decide(wiredBytes: 92 * gib, physicalBytes: 128 * gib,
                                                                         otherDarkbloomProcesses: []) else {
            throw Failure(description: "92 GiB on 128 GiB was not refused")
        }
        try require(message.contains("92.0 GiB") && message.contains("16.0 GiB") && message.contains("restart this Mac"), message)
        guard case .refused = ClusterOrphanWiredGuard.decide(wiredBytes: 26 * gib, physicalBytes: 256 * gib, otherDarkbloomProcesses: []) else {
            throw Failure(description: "26 GiB on 256 GiB was not refused")
        }
        // Another Darkbloom process may hold the memory: never second-guessed.
        guard case .skipped(let why) = ClusterOrphanWiredGuard.decide(wiredBytes: 176 * gib, physicalBytes: 256 * gib,
                                                                     otherDarkbloomProcesses: ["darkbloom-cluster-worker"]) else {
            throw Failure(description: "a running worker did not skip the guard")
        }
        try require(why.contains("darkbloom-cluster-worker"), why)
        guard case .skipped = ClusterOrphanWiredGuard.decide(wiredBytes: 1, physicalBytes: 0, otherDarkbloomProcesses: []) else {
            throw Failure(description: "unknown physical memory did not skip")
        }
    }

    static func probes() throws {
        guard let wired = ClusterOrphanWiredGuard.wiredBytes() else { throw Failure(description: "wired unreadable") }
        try require(wired > gib && wired < ClusterOrphanWiredGuard.physicalBytes(), "implausible wired \(wired)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orphan-check-\(getpid())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleeper = try copy("darkbloom-orphan-check-sleeper", into: directory)
        let zombie = try copy("darkbloom-orphan-check-zombie", into: directory)
        let ancestor = try copy("darkbloom-orphan-check-ancestor", into: directory)
        let lister = try copy("darkbloom-orphan-check-lister", into: directory)

        let sleeping = try spawn(sleeper, ["--sleep"])
        defer { kill(sleeping, SIGTERM); var s: Int32 = 0; waitpid(sleeping, &s, 0) }
        let exited = try spawn(zombie, ["--exit"])
        usleep(500_000)   // the zombie stays unreaped until below
        let seen = ClusterOrphanWiredGuard.otherDarkbloomProcesses()
        try require(seen.contains("darkbloom-orphan-check-sleeper"), "a running darkbloom process was missed: \(seen)")
        try require(!seen.contains("darkbloom-orphan-check-zombie"), "a zombie counted as running: \(seen)")
        var status: Int32 = 0; waitpid(exited, &status, 0)

        // Seen from a worker whose ancestor is a darkbloom process: the ancestor
        // and the lister itself are excluded, the unrelated sleeper is not.
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ancestor)
        process.arguments = ["--spawn-lister", lister]
        process.standardOutput = output
        try process.run(); process.waitUntilExit()
        let listed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
        try require(listed.contains("darkbloom-orphan-check-sleeper"), "lister missed the sleeper: \(listed)")
        try require(!listed.contains("darkbloom-orphan-check-ancestor"), "an ancestor counted: \(listed)")
        try require(!listed.contains("darkbloom-orphan-check-lister"), "the caller counted itself: \(listed)")
    }

    static func killMargins() throws {
        typealias P = ClusterWorkerSignalPolicy
        let s: UInt64 = 1_000_000_000
        try require(P.killMarginNanoseconds(plannedBytes: 0) == 30 * s, "zero bytes")
        try require(P.killMarginNanoseconds(plannedBytes: 18 * gib) == 30 * s, "9B artifact is the floor")
        try require(P.killMarginNanoseconds(plannedBytes: 90 * gib) == 45 * s, "90 GiB is 45 s")
        try require(P.killMarginNanoseconds(plannedBytes: 200 * gib) == 100 * s, "200 GiB is 100 s")
        try require(P.killMarginNanoseconds(plannedBytes: 300 * gib) == 120 * s, "300 GiB is the cap")
        try require(P.killMarginNanoseconds(plannedBytes: .max) == 120 * s, "max bytes is the cap")
        let sized = P.sized(plannedBytes: 161 * gib, childEndsItselfAtStartupDeadline: true)
        try require(sized.childEndsItselfAtStartupDeadline && sized.terminateMarginNanoseconds == P.standard.terminateMarginNanoseconds
            && sized.reapMarginNanoseconds == P.standard.reapMarginNanoseconds && sized.killMarginNanoseconds == UInt64(80.5 * Double(s)),
            "sized policy \(sized)")
        try require(P.maximumAllowanceNanoseconds == 130 * s, "maximum allowance")
        // An owner accepts a sized policy up to the cap, and refuses beyond it.
        func process(_ policy: P) throws -> ClusterWorkerProcess {
            let now = DispatchTime.now().uptimeNanoseconds
            return try ClusterWorkerProcess(launch: .init(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:]),
                expectedIdentity: fixtureIdentity, rank: 0, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 10 * s, lifetimeDeadline: now + 20 * s, retirement: policy)
        }
        _ = try process(P.sized(plannedBytes: 400 * gib))
        let beyond = P(terminateMarginNanoseconds: 5 * s, killMarginNanoseconds: 121 * s, reapMarginNanoseconds: 5 * s)
        try require((try? process(beyond)) == nil, "a kill margin past 120 s was accepted")
    }
}
