import Foundation
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessInstallationGuestChecksTests: XCTestCase, @unchecked Sendable {
    func testDiagnosticLimitDoesNotLimitInstallerFileWrites() async throws {
        let directory = try fixture(), log = directory.appendingPathComponent("installer.log")
        let output = directory.appendingPathComponent("ordinary-output")
        let result = try await run(log: log, command: ["/usr/bin/python3", "-c",
            "import pathlib,sys;pathlib.Path(sys.argv[1]).write_bytes(b'x'*131072);print('ok')", output.path])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "0:0:false:3")
        XCTAssertEqual(try Data(contentsOf: log), Data("ok\n".utf8))
        XCTAssertEqual(try Data(contentsOf: output).count, 131072)
    }

    func testOverflowIsExplicitAndRetainedOutputIsBounded() async throws {
        let directory = try fixture(), log = directory.appendingPathComponent("installer.log")
        let result = try await run(log: log, command: ["/usr/bin/python3", "-c", "import os;os.write(1,b'x'*131072)"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(String(decoding: result.standardOutput, as: UTF8.self).contains(":true:65536"))
        XCTAssertEqual(try Data(contentsOf: log).count, 65536)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["installer.log"])
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("accountless-log-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func run(log: URL, command: [String]) async throws -> SandboxProcessResult {
        try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", AccountlessInstallationGuestChecks.shell +
                "\nrun_bounded_log \"$@\" || exit 70\nprint -r -- \"$command_exit:$capture_exit:$capture_overflow:$diagnostic_bytes\"",
                "bounded-log-test", log.path] + command, timeoutSeconds: 10, maximumOutputBytes: 16 * 1024)
    }
}
