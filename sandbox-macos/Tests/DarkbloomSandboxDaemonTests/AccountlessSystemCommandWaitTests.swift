import Foundation
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessSystemCommandWaitTests: XCTestCase {
    func testCancellationDoesNotSignalTheSystemClient() async throws {
        let child = try SandboxProcessRunner().start(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.25; printf complete"])
        let task = Task { try await AccountlessSystemCommandWait.naturalExit(of: child, seconds: 5) }
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "complete")
    }

    func testDeadlineRetainsClientAfterTheCallersWrapperGoesAway() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("system-wait-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("natural-exit")
        do {
            let child = try SandboxProcessRunner().start(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 2; printf complete > \"$MARKER_PATH\""], environment: ["MARKER_PATH": marker.path])
            do {
                _ = try await AccountlessSystemCommandWait.naturalExit(of: child, seconds: 1)
                XCTFail("expected an observation deadline")
            } catch { XCTAssertEqual(error as? AccountlessDiskError, .systemOperationPending) }
            XCTAssertTrue(child.isRunning)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "complete")
    }
}
