import Foundation
import SandboxGuestProtocol
import Testing

@testable import SandboxGuestAgentCore

// swift-testing rather than XCTest on purpose: XCTest has no linkable
// framework under Command Line Tools, so an XCTest file here could only ever
// be compile-checked. These run.
//
// Nothing is mocked. A mocked executor would hide exactly the bugs that matter:
// a pipe that deadlocks, a deadline that does not reach a grandchild, an
// environment a command can override.

private let executor = SandboxGuestCommandExecutor(home: "/tmp")

private func wire(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:],
    timeoutSeconds: UInt32 = 30
) -> SandboxGuestCommandWire {
    SandboxGuestCommandWire(
        idempotencyKey: UUID().uuidString,
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: "/tmp",
        timeoutSeconds: timeoutSeconds
    )
}

@Test("echo produces exact stdout and a zero exit")
func echoProducesExactStdout() {
    let result = executor.execute(wire("/bin/echo", ["hello", "world"]))
    #expect(result.isSelfConsistent)
    #expect(result.exitCode == 0)
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "hello world\n")
    #expect(result.standardError.isEmpty)
    #expect(!result.timedOut)
    #expect(!result.standardOutputTruncated)
}

@Test("exit codes are preserved")
func exitCodesArePreserved() {
    #expect(executor.execute(wire("/usr/bin/false")).exitCode == 1)
    #expect(executor.execute(wire("/bin/sh", ["-c", "exit 42"])).exitCode == 42)
}

@Test("streams stay separate")
func streamsStaySeparate() {
    let result = executor.execute(wire("/bin/sh", ["-c", "echo out; echo err 1>&2"]))
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "out\n")
    #expect(String(decoding: result.standardError, as: UTF8.self) == "err\n")
}

@Test("oversized output is capped, flagged, and does not deadlock")
func oversizedOutputIsCappedAndDoesNotDeadlock() {
    // Two MiB through a pipe whose buffer is far smaller: the supervisor has to
    // keep reading past the cap or the command never exits.
    let result = executor.execute(
        wire(
            "/bin/sh",
            ["-c", "/usr/bin/yes 0123456789 | /usr/bin/head -c 2097152"],
            timeoutSeconds: 120
        )
    )
    #expect(result.isSelfConsistent)
    #expect(result.standardOutput.count == SandboxGuestLimits.maximumStreamBytes)
    #expect(result.standardOutputTruncated)
    #expect(!result.standardErrorTruncated)
    #expect(!result.timedOut)
}

@Test("the deadline reports a timeout and returns promptly")
func deadlineReportsTimeout() {
    let started = Date()
    let result = executor.execute(wire("/bin/sleep", ["30"], timeoutSeconds: 2))
    let elapsed = Date().timeIntervalSince(started)

    #expect(result.isSelfConsistent)
    #expect(result.timedOut)
    #expect(result.exitCode == SandboxGuestCommandExecutor.timeoutExitCode)
    #expect(elapsed < 20, "must not wait out the full sleep")
}

@Test("the deadline kills the whole process group")
func deadlineKillsTheProcessGroup() {
    // The direct child exits quickly but leaves a grandchild holding the pipe.
    // Only a process-group kill ends this.
    let started = Date()
    let result = executor.execute(
        wire("/bin/sh", ["-c", "/bin/sleep 30 & wait"], timeoutSeconds: 2)
    )
    #expect(result.timedOut)
    #expect(Date().timeIntervalSince(started) < 20, "grandchild must be killed too")
}

@Test("the deadline fires even when the command closes both streams")
func deadlineFiresWithClosedStreams() {
    // Regression: the deadline used to live only in the drain loop, so a
    // command that closed stdout and stderr reached EOF immediately and then
    // ran unbounded inside waitpid. A session serves one command at a time, so
    // that wedged the whole agent.
    let started = Date()
    let result = executor.execute(
        wire("/bin/sh", ["-c", "exec 1>&- 2>&-; /bin/sleep 20; exit 3"], timeoutSeconds: 2)
    )
    let elapsed = Date().timeIntervalSince(started)

    #expect(result.timedOut, "the deadline must bound the process, not the pipes")
    #expect(result.exitCode == SandboxGuestCommandExecutor.timeoutExitCode)
    #expect(elapsed < 15, "must not run to the command's own completion")
}

@Test("a fast exit with a background child is not reported as a timeout")
func fastExitWithBackgroundChildIsNotATimeout() {
    // Regression: a grandchild holding the pipe open kept the loop running to
    // the deadline, so `cmd & exit 7` was reported as a 124 timeout with its
    // real exit code discarded.
    let started = Date()
    let result = executor.execute(
        wire("/bin/sh", ["-c", "echo done; /bin/sleep 30 & exit 7"], timeoutSeconds: 8)
    )
    let elapsed = Date().timeIntervalSince(started)

    #expect(!result.timedOut, "the command finished; it did not time out")
    #expect(result.exitCode == 7, "the real exit code must survive")
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "done\n")
    #expect(elapsed < 6, "must not wait out the orphan")
}

@Test("reserved environment keys are refused, not overridden", arguments: [
    "PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "ENV", "BASH_ENV", "ZDOTDIR",
    "DYLD_INSERT_LIBRARIES", "DARKBLOOM_IDEMPOTENCY_KEY",
])
func reservedEnvironmentKeysAreRefused(key: String) {
    // The host rejects these at construction, so a request carrying one is a
    // buggy host or a hostile peer. The agent's validator must never be weaker
    // than the host's.
    let result = executor.execute(wire("/bin/echo", ["x"], environment: [key: "/evil"]))
    #expect(result.exitCode == 70, "\(key) must be refused before the spawn")
}

@Test("invalid environment keys are refused", arguments: [
    "bad-key", "1LEADING", "has space", "",
])
func invalidEnvironmentKeysAreRefused(key: String) {
    let result = executor.execute(wire("/bin/echo", ["x"], environment: [key: "v"]))
    #expect(result.exitCode == 70, "'\(key)' must be refused")
}

@Test("oversized aggregate input is refused before the spawn")
func oversizedAggregateInputIsRefused() {
    // Without this the spawn fails deep inside posix_spawn as an opaque E2BIG
    // instead of a clean validation refusal.
    let huge = String(repeating: "a", count: 16_000)
    var environment: [String: String] = [:]
    for index in 0..<10 { environment["VAR\(index)"] = huge }
    #expect(executor.execute(wire("/bin/echo", ["x"], environment: environment)).exitCode == 70)
}

@Test("the fixed environment is applied and caller values pass through")
func fixedEnvironmentIsApplied() {
    let result = executor.execute(
        wire(
            "/bin/sh",
            ["-c", "printf '%s|%s|%s' \"$PATH\" \"$HOME\" \"$USER_DEFINED\""],
            environment: ["USER_DEFINED": "kept"]
        )
    )
    #expect(
        String(decoding: result.standardOutput, as: UTF8.self)
            == "/usr/bin:/bin:/usr/sbin:/sbin|/tmp|kept"
    )
}

@Test("the idempotency key is exposed to the command")
func idempotencyKeyIsExposed() {
    let request = wire("/bin/sh", ["-c", "printf '%s' \"$DARKBLOOM_IDEMPOTENCY_KEY\""])
    let result = executor.execute(request)
    #expect(
        String(decoding: result.standardOutput, as: UTF8.self) == request.idempotencyKey
    )
}

@Test("a malformed request is refused without spawning")
func malformedRequestIsRefused() {
    let result = executor.execute(
        SandboxGuestCommandWire(
            idempotencyKey: "k",
            executable: "echo",  // relative: never legal
            arguments: [],
            environment: [:],
            workingDirectory: "/tmp",
            timeoutSeconds: 30
        )
    )
    #expect(result.exitCode == 70)
    #expect(!result.timedOut)
    #expect(result.isSelfConsistent)
}

@Test("a missing executable fails closed rather than hanging")
func missingExecutableFailsClosed() {
    let result = executor.execute(
        wire("/nonexistent/definitely-not-here", [], timeoutSeconds: 10)
    )
    #expect(result.isSelfConsistent)
    #expect(result.exitCode != 0)
    #expect(!result.timedOut)
}

@Test("the working directory is honoured")
func workingDirectoryIsHonoured() {
    let text = String(decoding: executor.execute(wire("/bin/pwd")).standardOutput, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // /tmp is a symlink to /private/tmp on macOS.
    #expect(text == "/tmp" || text == "/private/tmp", "got \(text)")
}

@Test("stdin is closed so commands cannot block on it")
func stdinIsClosed() {
    let started = Date()
    let result = executor.execute(wire("/bin/cat", [], timeoutSeconds: 10))
    #expect(!result.timedOut, "cat with no stdin must exit on EOF")
    #expect(Date().timeIntervalSince(started) < 8)
}

// MARK: - Bounded sink

@Test("bounded sink keeps everything under the limit")
func sinkKeepsUnderLimit() {
    var sink = BoundedSink(limit: 10)
    sink.append([UInt8]("abc".utf8))
    sink.append([UInt8]("de".utf8))
    #expect(sink.bytes == Data("abcde".utf8))
    #expect(!sink.truncated)
}

@Test("bounded sink flags and clips at the limit")
func sinkFlagsAtLimit() {
    var sink = BoundedSink(limit: 4)
    sink.append([UInt8]("abcdef".utf8))
    #expect(sink.bytes == Data("abcd".utf8))
    #expect(sink.truncated)
}

@Test("landing exactly on the limit is not truncation")
func exactLimitIsNotTruncation() {
    var sink = BoundedSink(limit: 2)
    sink.append([UInt8]("ab".utf8))
    #expect(!sink.truncated)
    sink.append([UInt8]("c".utf8))
    #expect(sink.truncated)
    #expect(sink.bytes.count == 2)
}

@Test("an empty append at the limit does not flag truncation")
func emptyAppendAtLimit() {
    var sink = BoundedSink(limit: 1)
    sink.append([UInt8]("a".utf8))
    sink.append([UInt8]())
    #expect(!sink.truncated)
}

// MARK: - Wait status decoding

@Test("wait status decoding covers normal and signalled exits")
func waitStatusDecoding() {
    #expect(SandboxGuestProcessSpawn.exitCode(from: 0) == 0)
    #expect(SandboxGuestProcessSpawn.exitCode(from: 1 << 8) == 1)
    #expect(SandboxGuestProcessSpawn.exitCode(from: 42 << 8) == 42)
    // Signalled: shell convention, clamped into the envelope's legal range.
    #expect(SandboxGuestProcessSpawn.exitCode(from: SIGKILL) == 137)
    #expect(SandboxGuestProcessSpawn.exitCode(from: SIGTERM) == 143)
    #expect(SandboxGuestProcessSpawn.exitCode(from: 0x7F) == 255)
}
