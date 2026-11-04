import Darwin
import Foundation
import Testing

@testable import darkbloom

/// Ctrl-C at a terminal while a sandbox command runs its child. Each case runs
/// the built `darkbloom` as the foreground job of a pseudo-terminal of its own
/// and types Ctrl-C there, so the kernel signals the job's process group
/// exactly as in a terminal window. Foundation starts the command's child in a
/// process group of its own, which that signal does not reach: the command
/// must pass Ctrl-C on, or the terminal stays stuck.
@Suite("darkbloom sandbox: Ctrl-C at a terminal")
struct SandboxInterruptTests {
    @Test("logs -f ends at Ctrl-C and leaves no tail running")
    func followedLogEndsAtInterrupt() throws {
        let fixture = try SandboxTerminalFixture()
        defer { fixture.remove() }
        let log = fixture.addonRoot.appendingPathComponent("agent/agent.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("agent started\n".utf8).write(to: log)

        let job = try TerminalJob(fixture.darkbloom, ["sandbox", "logs", "-f"], environment: fixture.environment)
        defer { job.end() }
        // `tail -F` has printed the log, so it is following it.
        try #require(job.wait(seconds: 20) { job.text.contains("agent started") }, "tail never started: \(job.text)")
        let started = job.descendants
        try #require(!started.isEmpty)

        job.typeInterrupt()

        let status = try #require(job.exitStatus(within: 10), "still running 10 s after Ctrl-C: \(job.text)")
        #expect(TerminalJob.describe(status) == "exit 130")
        #expect(job.allEnded(started, within: 5), "tail outlived the command")
    }

    @Test("Ctrl-C reaches the add-on's own foreground child too, as at a terminal")
    func interruptReachesWholeChildGroup() throws {
        let fixture = try SandboxTerminalFixture()
        defer { fixture.remove() }
        // A shell that alone got Ctrl-C would wait for `sleep` to end first.
        try fixture.installAddon(uninstall: "echo 'fake add-on running'; sleep 600; echo 'still here'")

        let job = try TerminalJob(fixture.darkbloom, ["sandbox", "uninstall", "--yes"], environment: fixture.environment)
        defer { job.end() }
        try #require(job.wait(seconds: 20) { job.text.contains("fake add-on running") && job.descendants.count >= 2 },
                     "the add-on never started its sleep: \(job.text)")
        let started = job.descendants

        job.typeInterrupt()

        let status = try #require(job.exitStatus(within: 10), "still running 10 s after Ctrl-C: \(job.text)")
        // The add-on ended by SIGINT, so uninstall fails without saying it is done.
        #expect(TerminalJob.describe(status) == "exit 1")
        #expect(!job.text.contains("still here") && !job.text.contains("Set it up again"))
        #expect(job.allEnded(started, within: 5), "the add-on outlived the command")
    }

    @Test("a child that keeps running after Ctrl-C is killed by the second one")
    func secondInterruptKillsChild() throws {
        let fixture = try SandboxTerminalFixture()
        defer { fixture.remove() }
        try fixture.installAddon(uninstall: """
            trap 'echo "ignoring Ctrl-C"' INT
            echo 'fake add-on running'
            while :; do sleep 1; done
            """)

        let job = try TerminalJob(fixture.darkbloom, ["sandbox", "uninstall", "--yes"], environment: fixture.environment)
        defer { job.end() }
        try #require(job.wait(seconds: 20) { job.text.contains("fake add-on running") && job.descendants.count >= 2 },
                     "the add-on never started: \(job.text)")

        job.typeInterrupt()
        try #require(job.wait(seconds: 10) { job.text.contains("ignoring Ctrl-C") },
                     "the first Ctrl-C never reached the add-on: \(job.text)")
        // The command waits for the child that outlived the first Ctrl-C.
        #expect(job.exitStatus(within: 1) == nil)
        let started = job.descendants

        job.typeInterrupt()

        let status = try #require(job.exitStatus(within: 10), "still running 10 s after a second Ctrl-C: \(job.text)")
        #expect(TerminalJob.describe(status) == "exit 1")
        #expect(job.allEnded(started, within: 5), "the add-on outlived the command")
    }
}

/// A temporary home, with the add-on root in it, for the built `darkbloom`.
private struct SandboxTerminalFixture {
    let home: URL
    var addonRoot: URL { home.appendingPathComponent("DarkbloomSandbox", isDirectory: true) }

    /// The `darkbloom` executable built beside this test bundle.
    var darkbloom: URL {
        let bundle = Bundle(for: SandboxTerminalBundleAnchor.self).bundleURL
        let products = bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle
        return products.appendingPathComponent("darkbloom")
    }

    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment[SandboxAddon.rootOverrideVariable] = addonRoot.path
        environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
        environment["NO_COLOR"] = "1"
        return environment
    }

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-interrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// A fake `darkbloom-sandbox` whose `uninstall` runs `body`. Its status
    /// fails, which reads as no jobs running.
    func installAddon(uninstall body: String) throws {
        try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
        let command = addonRoot.appendingPathComponent("darkbloom-sandbox")
        try Data("#!/bin/sh\n[ \"$1\" = uninstall ] || exit 1\n\(body)\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

private final class SandboxTerminalBundleAnchor {}

/// A command run as the only job of a new session on a pseudo-terminal, as a
/// shell in a terminal window runs it: its process group is the terminal's
/// foreground job, so Ctrl-C typed on the master end makes the kernel signal
/// that group, never this test process.
private final class TerminalJob {
    let pid: pid_t
    private let master: Int32
    private var output = Data()
    private var status: Int32?

    init(_ executable: URL, _ arguments: [String], environment: [String: String]) throws {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw POSIXError(.ENXIO) }
        defer { close(slave) }
        var name = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard ttyname_r(slave, &name, name.count) == 0 else {
            close(master)
            throw POSIXError(.ENOTTY)
        }
        let terminal = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_adddup2(&actions, slave, descriptor)
        }
        // As a shell starts a command: every signal at its default, none blocked.
        var every = sigset_t(), none = sigset_t()
        sigfillset(&every)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &every)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // A session leader takes a terminal as its controlling terminal when it
        // opens it. posix_spawn sets up descriptors before the new session, so
        // the shell opens the terminal again, then becomes the command.
        let script = #"terminal=$1; shift; exec "$@" <"$terminal""#
        let argumentStrings = (["/bin/sh", "-c", script, "sh", terminal, executable.path] + arguments).map { strdup($0) }
        let environmentStrings = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (argumentStrings + environmentStrings).forEach { free($0) } }
        var identifier: pid_t = 0
        let result = posix_spawn(&identifier, "/bin/sh", &actions, &attributes,
                                 argumentStrings + [nil], environmentStrings + [nil])
        guard result == 0 else {
            close(master)
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
        }
        pid = identifier
        self.master = master
    }

    /// What the job has written to the terminal so far.
    var text: String {
        drain()
        return String(decoding: output, as: UTF8.self)
    }

    /// The processes the job started that are still its descendants.
    var descendants: [pid_t] {
        var found: [pid_t] = [], parents = [pid]
        while let parent = parents.popLast() {
            var children = [pid_t](repeating: 0, count: 64)
            let count = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.stride))
            let direct = children.prefix(max(0, Int(count))).filter { $0 > 0 }
            found += direct
            parents += direct
        }
        return found
    }

    /// Ctrl-C on the terminal's keyboard, its default interrupt character.
    func typeInterrupt() {
        var interrupt: UInt8 = 0x03
        _ = write(master, &interrupt, 1)
    }

    /// Whether `condition` came to hold within `seconds`.
    func wait(seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            drain()
            usleep(20_000)
        }
        return true
    }

    /// The job's wait status once it has ended within `seconds`; nil while it runs.
    func exitStatus(within seconds: Double) -> Int32? {
        _ = wait(seconds: seconds) { reap() }
        return status
    }

    /// Whether every process in `started` ended within `seconds`. Kills the
    /// ones that did not: they were just seen running, so their identifiers
    /// still name them.
    func allEnded(_ started: [pid_t], within seconds: Double) -> Bool {
        let ended = wait(seconds: seconds) { started.allSatisfy(Self.isGone) }
        if !ended { started.filter { !Self.isGone($0) }.forEach { kill($0, SIGKILL) } }
        return ended
    }

    /// Kills the job and everything it started if it still runs, then closes the terminal.
    func end() {
        if !reap() {
            for process in descendants + [pid] { kill(process, SIGKILL) }
            var value: Int32 = 0
            while waitpid(pid, &value, 0) < 0 && errno == EINTR {}
        }
        close(master)
    }

    /// `exit N` or `signal N` for a wait status.
    static func describe(_ status: Int32) -> String {
        status & 0x7F == 0 ? "exit \((status >> 8) & 0xFF)" : "signal \(status & 0x7F)"
    }

    private static func isGone(_ process: pid_t) -> Bool { kill(process, 0) == -1 && errno == ESRCH }

    private func reap() -> Bool {
        if status != nil { return true }
        var value: Int32 = 0
        guard waitpid(pid, &value, WNOHANG) == pid else { return false }
        status = value
        return true
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else { return }
            output.append(contentsOf: buffer[..<count])
        }
    }
}
