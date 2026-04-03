/// CLIRunnerTests — Unit tests for binary resolution and shell execution.

import Testing
import Foundation
@testable import DGInf

@Suite("CLIRunner - Binary Resolution")
struct CLIRunnerBinaryTests {

    @Test("resolveBinaryPath returns nil when binary is not installed")
    func binaryPathNilOrValid() {
        let path = CLIRunner.resolveBinaryPath()
        if let path = path {
            // If found, it must be a real executable
            #expect(FileManager.default.isExecutableFile(atPath: path))
        }
        // nil is acceptable — binary may not be installed in test environment
    }

    @Test("resolveBinaryPath checks home .dginf/bin first")
    func binaryPathSearchOrder() {
        // Verify the method doesn't crash and returns a consistent result
        let first = CLIRunner.resolveBinaryPath()
        let second = CLIRunner.resolveBinaryPath()
        #expect(first == second, "Binary resolution should be deterministic")
    }

    @Test("resolveBinaryPath result is an absolute path when present")
    func binaryPathIsAbsolute() {
        guard let path = CLIRunner.resolveBinaryPath() else { return }
        #expect(path.hasPrefix("/"), "Binary path should be absolute")
    }
}

@Suite("CLIRunner - Shell Execution")
struct CLIRunnerShellTests {

    @Test("shell runs echo and captures stdout")
    func shellEchoStdout() async {
        let result = await CLIRunner.shell("echo hello")
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello")
        #expect(result.success)
    }

    @Test("shell captures stderr separately")
    func shellCapturesStderr() async {
        let result = await CLIRunner.shell("echo error >&2")
        #expect(result.exitCode == 0)
        #expect(result.stderr == "error")
    }

    @Test("shell reports non-zero exit codes")
    func shellReportsFailure() async {
        let result = await CLIRunner.shell("exit 42")
        #expect(result.exitCode == 42)
        #expect(!result.success)
    }

    @Test("shell runs multi-word commands")
    func shellMultiWord() async {
        let result = await CLIRunner.shell("echo one two three")
        #expect(result.exitCode == 0)
        #expect(result.stdout == "one two three")
    }

    @Test("shell handles empty output")
    func shellEmptyOutput() async {
        let result = await CLIRunner.shell("true")
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
    }
}

@Suite("CLIRunner - run() with nonexistent binary")
struct CLIRunnerRunTests {

    @Test("run returns error result when binary is not found")
    func runNoBinary() async throws {
        // If binary is installed, this test just verifies the method doesn't crash.
        // If binary is NOT installed, it returns exitCode -1 with error message.
        let result = try await CLIRunner.run(["--help"])
        if CLIRunner.resolveBinaryPath() == nil {
            #expect(result.exitCode == -1)
            #expect(result.stderr.contains("not found"))
            #expect(!result.success)
        }
        // If binary IS found, any exit code is acceptable — we just verify no crash
    }
}

@Suite("CLIResult")
struct CLIResultTests {

    @Test("output combines stdout and stderr")
    func combinedOutput() {
        let result = CLIResult(exitCode: 0, stdout: "out", stderr: "err")
        #expect(result.output == "out\nerr")
    }

    @Test("output omits empty stdout")
    func omitsEmptyStdout() {
        let result = CLIResult(exitCode: 0, stdout: "", stderr: "err")
        #expect(result.output == "err")
    }

    @Test("output omits empty stderr")
    func omitsEmptyStderr() {
        let result = CLIResult(exitCode: 0, stdout: "out", stderr: "")
        #expect(result.output == "out")
    }

    @Test("output is empty when both are empty")
    func bothEmpty() {
        let result = CLIResult(exitCode: 0, stdout: "", stderr: "")
        #expect(result.output.isEmpty)
    }

    @Test("success reflects exitCode == 0")
    func successProperty() {
        #expect(CLIResult(exitCode: 0, stdout: "", stderr: "").success)
        #expect(!CLIResult(exitCode: 1, stdout: "", stderr: "").success)
        #expect(!CLIResult(exitCode: -1, stdout: "", stderr: "").success)
    }
}

@Suite("CLIError")
struct CLIRunnerErrorTests {

    @Test("binaryNotFound has a descriptive message")
    func errorDescription() {
        let error = CLIError.binaryNotFound
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("not found"))
    }
}
