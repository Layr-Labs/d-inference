import Darwin
import Foundation

// The one forced exit (ProcessForcedExit) and the deadline thread that takes it
// (ProcessDeadline), compiled from the runtime's own sources without MLX. Each
// case runs this binary again as a child that ends the way the case says, with
// a stand-in release that only writes a marker; the parent checks the status,
// the time, and the order of what the child wrote.

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw Failure(description: message()) }
}
private func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
private func mark(_ text: String) {
    let bytes = Array((text + "\n").utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
}
private func say(_ text: String) {
    let bytes = Array((text + "\n").utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
}
private func sleepForever() -> Never { while true { sleep(60) } }
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

// MARK: Children

private func child(_ scenario: String) throws -> Never {
    let releases = Counter()
    let marker: @Sendable () -> String = { mark("test-release \(releases.next())"); return "detail=stub" }
    switch scenario {
    case "deadline":
        ProcessForcedExit.install(release: marker)
        try ProcessDeadline.arm(uptimeNanoseconds: now() + 300_000_000, status: 124)
        sleepForever()
    case "hung-release":
        ProcessForcedExit.install(release: { mark("test-release-hangs"); sleepForever() }, deadManNanoseconds: 800_000_000)
        ProcessForcedExit.exit(status: 77, reason: "test")
    case "once":
        ProcessForcedExit.install(release: marker)
        guard ProcessForcedExit.begin(status: 5, reason: "first") else { mark("first begin lost"); Darwin._exit(90) }
        Thread.detachNewThread { ProcessForcedExit.exit(status: 6, reason: "second") }
        usleep(200_000)
        if ProcessForcedExit.begin(status: 7, reason: "third") { mark("third begin won"); Darwin._exit(91) }
        guard ProcessForcedExit.claim == .init(status: 5, reason: "first") else { mark("claim changed"); Darwin._exit(92) }
        ProcessForcedExit.finish(status: 9, reason: "finish")
    case "sigterm", "sigint-ignored", "sighup":
        ProcessForcedExit.install(release: marker)
        let routed = try ProcessForcedExit.routeTerminationSignals()
        say("ready " + routed.map(String.init).joined(separator: ","))
        sleepForever()
    case "sigalrm":
        ProcessForcedExit.install(release: marker)
        try ProcessForcedExit.routeTerminationSignals()
        alarm(1)
        sleepForever()
    case "no-release":
        ProcessForcedExit.exit(status: 3, reason: "test")
    case "signal-during-release":
        ProcessForcedExit.install(release: {
            mark("test-release-slow"); say("ready"); usleep(1_500_000); return "detail=slow"
        }, deadManNanoseconds: 5_000_000_000)
        try ProcessForcedExit.routeTerminationSignals()
        ProcessForcedExit.exit(status: 9, reason: "path")
    case "clean-finish":
        ProcessForcedExit.install(release: marker)
        ProcessForcedExit.finish(status: 0, reason: "shutdown-complete")
    default:
        throw Failure(description: "unknown scenario \(scenario)")
    }
}

// MARK: Parent

private struct Outcome { let status: Int32?; let signal: Int32?; let stderr: String; let seconds: Double }

/// Spawns this binary as `child SCENARIO`. `during` gets the child's pid and a
/// reader of its stdout lines, and may signal it.
private func run(_ scenario: String, ignoreInterruptInChild: Bool = false,
                 during: (pid_t, () -> String?) throws -> Void = { _, _ in }) throws -> Outcome {
    var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
    guard pipe(&out) == 0, pipe(&err) == 0 else { throw Failure(description: "pipe") }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, out[0]); posix_spawn_file_actions_addclose(&actions, err[0])
    let executable = CommandLine.arguments[0]
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("child"), strdup(scenario), nil]
    defer { argv.forEach { free($0) } }
    // An ignored disposition is inherited across exec, as the pair driver's
    // launch script leaves SIGINT and SIGHUP for the worker.
    let previous = ignoreInterruptInChild ? signal(SIGINT, SIG_IGN) : nil
    // Whatever this check runner inherited, each child starts from the default
    // dispositions and an empty mask, except for the ignore the case asks for.
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    var defaults = sigset_t(), empty = sigset_t()
    sigemptyset(&defaults); sigemptyset(&empty)
    for value in [SIGTERM, SIGHUP, SIGALRM] + (ignoreInterruptInChild ? [] : [SIGINT]) { sigaddset(&defaults, value) }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &empty)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    var pid: pid_t = 0
    let begin = now()
    let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
    if ignoreInterruptInChild { signal(SIGINT, previous) }
    posix_spawnattr_destroy(&attributes)
    posix_spawn_file_actions_destroy(&actions)
    close(out[1]); close(err[1])
    guard spawned == 0 else { throw Failure(description: "spawn \(spawned)") }
    let reader = FileHandle(fileDescriptor: out[0], closeOnDealloc: true)
    var buffered = Data()
    let nextLine: () -> String? = {
        while true {
            if let index = buffered.firstIndex(of: 10) {
                let line = String(decoding: buffered[..<index], as: UTF8.self)
                buffered.removeSubrange(...index); return line
            }
            let chunk = reader.availableData
            if chunk.isEmpty { return nil }
            buffered.append(chunk)
        }
    }
    var diagnostics = Data()
    let errDone = DispatchSemaphore(value: 0)
    let errReader = FileHandle(fileDescriptor: err[0], closeOnDealloc: true)
    nonisolated(unsafe) var collected = Data()
    Thread.detachNewThread { collected = errReader.readDataToEndOfFile(); errDone.signal() }
    do { try during(pid, nextLine) } catch { kill(pid, SIGKILL); throw error }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    let seconds = Double(now() - begin) / 1e9
    errDone.wait(); diagnostics = collected
    let exited = (status & 0x7f) == 0
    return .init(status: exited ? (status >> 8) & 0xff : nil, signal: exited ? nil : status & 0x7f,
                 stderr: String(decoding: diagnostics, as: UTF8.self), seconds: seconds)
}

private func ordered(_ text: String, _ markers: [String]) -> Bool {
    var rest = Substring(text)
    for marker in markers {
        guard let range = rest.range(of: marker) else { return false }
        rest = rest[range.upperBound...]
    }
    return true
}

private func count(_ text: String, _ marker: String) -> Int { text.components(separatedBy: marker).count - 1 }

private func parent() throws {
    var passed = 0
    func check(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { throw Failure(description: "\(name): \(error)") }
        passed += 1; print("ok \(name)")
    }
    try check("deadline-thread-releases-then-exits-124") {
        let o = try run("deadline")
        try require(o.status == 124, "status \(String(describing: o.status)) signal \(String(describing: o.signal)): \(o.stderr)")
        try require(o.seconds >= 0.3 && o.seconds < 3, "took \(o.seconds) s")
        try require(ordered(o.stderr, ["status=124 reason=process-deadline phase=claimed", "test-release 1", "phase=released detail=stub"]), o.stderr)
    }
    try check("hung-release-ends-at-the-dead-man-with-the-claimed-status") {
        let o = try run("hung-release")
        try require(o.status == 77, "status \(String(describing: o.status)): \(o.stderr)")
        try require(o.seconds >= 0.8 && o.seconds < 3, "took \(o.seconds) s")
        try require(ordered(o.stderr, ["status=77 reason=test phase=claimed dead_man_ms=800", "test-release-hangs"]), o.stderr)
        try require(!o.stderr.contains("phase=released"), "a hung release reported done")
    }
    try check("first-claim-wins-later-paths-only-wait-and-finish-keeps-its-status") {
        let o = try run("once")
        try require(o.status == 5, "status \(String(describing: o.status)): \(o.stderr)")
        try require(count(o.stderr, "phase=claimed") == 1 && o.stderr.contains("status=5 reason=first phase=claimed"), o.stderr)
        // The claim's release, and once more at finish; never for the losers.
        try require(count(o.stderr, "test-release ") == 2, o.stderr)
        try require(!o.stderr.contains("reason=second") && !o.stderr.contains("reason=third"), o.stderr)
    }
    try check("sigterm-is-routed-to-the-release-and-exits-143") {
        let o = try run("sigterm") { pid, line in
            guard let ready = line(), ready.hasPrefix("ready ") else { throw Failure(description: "no ready line") }
            try require(ready == "ready \(SIGTERM),\(SIGINT),\(SIGHUP),\(SIGALRM)", ready)
            kill(pid, SIGTERM)
        }
        try require(o.status == 143 && o.signal == nil, "status \(String(describing: o.status)) signal \(String(describing: o.signal)): \(o.stderr)")
        try require(ordered(o.stderr, ["status=143 reason=signal-15 phase=claimed", "test-release 1", "phase=released"]), o.stderr)
    }
    try check("sighup-is-routed-when-not-ignored") {
        let o = try run("sighup") { pid, line in
            _ = line(); kill(pid, SIGHUP)
        }
        try require(o.status == 129, "status \(String(describing: o.status)): \(o.stderr)")
    }
    try check("an-inherited-sigint-ignore-is-kept") {
        let o = try run("sigint-ignored", ignoreInterruptInChild: true) { pid, line in
            guard let ready = line() else { throw Failure(description: "no ready line") }
            try require(ready == "ready \(SIGTERM),\(SIGHUP),\(SIGALRM)", "SIGINT was routed although ignored: \(ready)")
            kill(pid, SIGINT); usleep(400_000)
            try require(kill(pid, 0) == 0, "the child ended on an ignored SIGINT")
            kill(pid, SIGTERM)
        }
        try require(o.status == 143, "status \(String(describing: o.status)): \(o.stderr)")
        try require(count(o.stderr, "phase=claimed") == 1, o.stderr)
    }
    try check("sigalrm-exits-124-through-the-release") {
        let o = try run("sigalrm")
        try require(o.status == 124 && o.seconds >= 0.9 && o.seconds < 4, "status \(String(describing: o.status)) in \(o.seconds) s: \(o.stderr)")
        try require(ordered(o.stderr, ["status=124 reason=signal-14 phase=claimed", "test-release 1"]), o.stderr)
    }
    try check("a-signal-during-a-release-only-waits") {
        let o = try run("signal-during-release") { pid, line in
            _ = line(); kill(pid, SIGTERM)
        }
        try require(o.status == 9, "status \(String(describing: o.status)): \(o.stderr)")
        try require(o.seconds >= 1.4 && o.seconds < 4, "took \(o.seconds) s")
        try require(count(o.stderr, "phase=claimed") == 1 && !o.stderr.contains("signal-15 phase=claimed"), o.stderr)
    }
    try check("without-a-release-the-exit-says-so") {
        let o = try run("no-release")
        try require(o.status == 3 && o.stderr.contains("status=3 phase=released release=none"), "\(String(describing: o.status)): \(o.stderr)")
    }
    try check("the-clean-end-releases-and-exits-0") {
        let o = try run("clean-finish")
        try require(o.status == 0, "status \(String(describing: o.status)): \(o.stderr)")
        try require(ordered(o.stderr, ["status=0 reason=shutdown-complete phase=claimed", "test-release 1"]), o.stderr)
    }
    print("{\"passed\":true,\"cases\":\(passed),\"forcedExit\":\"actual-runtime-sources\",\"modelOrGPUExecution\":false}")
}

@main struct ExitCheck {
    static func main() {
        let arguments = CommandLine.arguments
        do {
            if arguments.count == 3 && arguments[1] == "child" { try child(arguments[2]) }
            try parent()
        } catch {
            FileHandle.standardError.write(Data("FAILED \(error)\n".utf8)); exit(1)
        }
    }
}
