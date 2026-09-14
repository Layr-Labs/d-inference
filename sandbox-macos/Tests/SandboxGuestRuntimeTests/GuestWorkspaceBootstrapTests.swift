import Darwin
import Foundation
import SandboxGuestProtocol
@testable import SandboxGuestRuntime
import XCTest

final class GuestWorkspaceBootstrapTests: XCTestCase {
    func testMaliciousTemporaryDirectorySymlinkCannotChangeOutsideTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("privileged-target")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o755])
        let link = fixture.workspace.appendingPathComponent(".tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        var before = stat(), after = stat()
        XCTAssertEqual(lstat(outside.path, &before), 0)
        XCTAssertThrowsError(try fixture.prepareDirectories())
        XCTAssertEqual(lstat(outside.path, &after), 0)
        XCTAssertEqual(after.st_uid, before.st_uid)
        XCTAssertEqual(after.st_gid, before.st_gid)
        XCTAssertEqual(after.st_mode, before.st_mode)
        var linkInfo = stat()
        XCTAssertEqual(lstat(link.path, &linkInfo), 0)
        XCTAssertEqual(linkInfo.st_mode & S_IFMT, S_IFLNK)
    }

    func testRestartWaitsForTenantQuiescenceBeforeTouchingWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = QuiescenceGate()
        let prepare = Task {
            try await GuestWorkspaceBootstrap.prepare(path: fixture.workspace.path,
                tenantUID: geteuid(), tenantGID: getegid(), supervisorUID: geteuid(),
                requireSeparateVolume: false, quiesce: { await gate.quiesce() })
        }
        await gate.waitUntilEntered()
        // Represents a surviving tenant during launchd restart. No privileged
        // directory mutation is allowed before its cleanup proof completes.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent(".tmp").path))
        var before = stat()
        XCTAssertEqual(lstat(fixture.workspace.path, &before), 0)
        XCTAssertEqual(before.st_mode & 0o7777, 0o755)
        await gate.finish()
        _ = try await prepare.value
        var workspace = stat(), temporary = stat()
        XCTAssertEqual(lstat(fixture.workspace.path, &workspace), 0)
        XCTAssertEqual(workspace.st_mode & 0o7777, 0o1770)
        XCTAssertEqual(lstat(fixture.workspace.appendingPathComponent(".tmp").path, &temporary), 0)
        XCTAssertEqual(temporary.st_mode & 0o7777, 0o700)
        XCTAssertEqual(temporary.st_dev, workspace.st_dev)
        XCTAssertEqual(temporary.st_uid, geteuid())
    }

    func testUnprovenTenantCleanupLeavesWorkspaceUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        do {
            _ = try await GuestWorkspaceBootstrap.prepare(path: fixture.workspace.path,
                tenantUID: geteuid(), tenantGID: getegid(), supervisorUID: geteuid(),
                requireSeparateVolume: false, quiesce: { throw GuestProtocolError.cleanupUncertain })
            XCTFail("unproven cleanup must reject bootstrap")
        } catch GuestProtocolError.cleanupUncertain {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent(".tmp").path))
        var info = stat()
        XCTAssertEqual(lstat(fixture.workspace.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o755)
    }

    private struct Fixture: @unchecked Sendable {
        let root: URL
        let workspace: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("guest-bootstrap-\(UUID().uuidString)")
            workspace = root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o755])
        }
        func prepareDirectories() throws {
            try GuestWorkspaceBootstrap.prepareDirectories(path: workspace.path,
                tenantUID: geteuid(), tenantGID: getegid(), supervisorUID: geteuid(), requireSeparateVolume: false)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private actor QuiescenceGate {
        private var entered = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?
        func quiesce() async {
            entered = true
            for continuation in enteredWaiters { continuation.resume() }
            enteredWaiters.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }
        func finish() { release?.resume(); release = nil }
    }
}
