import Darwin
import Foundation
@testable import SandboxRuntime
import XCTest

final class SystemProcessCleanupPolicyTests: XCTestCase {
    func testExplicitSystemPolicyPreservesHelperAfterForegroundExitWhileDefaultTerminatesIt() async throws {
        for preserve in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("system-helper-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let fifo = root.appendingPathComponent("gate"), marker = root.appendingPathComponent("helper-result")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            let gate = open(fifo.path, O_RDWR | O_CLOEXEC | O_NONBLOCK)
            XCTAssertGreaterThanOrEqual(gate, 0)
            defer { if gate >= 0 { _ = write(gate, "go\n", 3); close(gate) } }
            let execution = try ProcessExecution(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(read token < \"$GATE_PATH\"; printf survived > \"$MARKER_PATH\") </dev/null >/dev/null 2>&1 & exit 0"],
                environment: ["PATH": "/usr/bin:/bin", "GATE_PATH": fifo.path, "MARKER_PATH": marker.path],
                currentDirectory: nil, maximumOutputBytes: 4096, terminateDescendantsOnExit: !preserve)
            try execution.start()
            await execution.waitUntilExit()
            XCTAssertEqual(execution.result().exitCode, 0)
            // The helper may proceed only after foreground exit was observed.
            XCTAssertEqual(write(gate, "go\n", 3), 3)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            if preserve {
                while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "survived")
            } else {
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            }
            execution.cleanup()
        }
    }

    func testSystemToolEntryRejectsArbitraryProgramsAndUnprivilegedCallers() throws {
        XCTAssertThrowsError(try SandboxProcessRunner().startSystemTool(executable: URL(fileURLWithPath: "/bin/sh"), arguments: []))
        if geteuid() != 0 {
            XCTAssertThrowsError(try SandboxProcessRunner().startSystemTool(executable: URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: []))
        }
    }
}
