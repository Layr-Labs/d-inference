import Foundation
import Testing

@testable import darkbloom

/// These tests run only /bin/sh, /bin/echo and /bin/sleep. They change no
/// system state.
@Suite("Fan process runner")
struct FanProcessRunnerTests {
    @Test("a successful command returns status 0 and its output")
    func successReturnsOutput() {
        let result = FanProcessRunner.run("/bin/echo", arguments: ["fan", "ok"])

        #expect(result == FanProcessResult(status: 0, output: "fan ok\n"))
        #expect(result.succeeded)
    }

    @Test("a failing command returns its status with stdout and stderr together")
    func failureMergesOutput() {
        let result = FanProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2; exit 3"]
        )

        #expect(result.status == 3)
        #expect(!result.succeeded)
        #expect(result.output.contains("out\n"))
        #expect(result.output.contains("err\n"))
    }

    @Test("a missing executable returns status -1 and the launch error")
    func missingExecutable() {
        let result = FanProcessRunner.run(
            "/nonexistent/darkbloom-fan-test-\(UUID().uuidString)",
            arguments: []
        )

        #expect(result.status == -1)
        #expect(!result.output.isEmpty)
    }

    @Test("a command that runs past the timeout is stopped")
    func timeoutStopsCommand() {
        let started = Date()
        let result = FanProcessRunner.run("/bin/sleep", arguments: ["30"], timeout: 1)

        #expect(result == FanProcessResult(status: -1, output: "command timed out after 1 seconds"))
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test("output is capped at 64 KiB")
    func outputIsCapped() {
        let result = FanProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "/usr/bin/yes fan | /usr/bin/head -c 200000"]
        )

        #expect(result.status == 0)
        #expect(result.output.utf8.count == 64 * 1024)
        #expect(result.output.hasPrefix("fan\nfan\n"))
    }
}
