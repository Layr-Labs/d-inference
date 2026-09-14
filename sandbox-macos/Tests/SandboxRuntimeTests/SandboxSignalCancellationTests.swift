import Darwin
import Foundation
import SandboxRuntime
import XCTest

final class SandboxSignalCancellationTests: XCTestCase {
    func testTerminationSignalsCancelAndAwaitCleanupInOwnedChild() async throws {
        for signal in [SIGTERM, SIGINT] {
            try await probe(mode: "--signal-cancel", signal: signal, expectedExit: 0, cleanup: true)
        }
    }

    func testScopeRestoresThePreviousDefaultSignalDisposition() async throws {
        try await probe(mode: "--signal-restore", signal: SIGTERM, expectedExit: 128 + SIGTERM, cleanup: false)
    }

    private func probe(mode: String, signal: Int32, expectedExit: Int32, cleanup: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("signal-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = Bundle(for: SandboxSignalCancellationTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SandboxProcessLifecycleProbe")
        let child = try ManagedProcessBrokerFixture(executable: executable, directory: directory, mode: mode)
        defer { do { try child.killAndWait() } catch { XCTFail("child cleanup failed: \(error)") } }
        let ready = directory.appendingPathComponent("ready")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        try child.send(signal: signal)
        XCTAssertEqual(try child.waitForExit(), expectedExit)
        XCTAssertEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cleanup").path), cleanup)
    }
}
