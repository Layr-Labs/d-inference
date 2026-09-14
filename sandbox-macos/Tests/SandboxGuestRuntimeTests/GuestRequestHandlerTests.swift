import Darwin
import CryptoKit
import Foundation
import XCTest
import SandboxGuestProtocol
@testable import SandboxGuestRuntime

private actor ControlledExecutor: GuestCommandExecuting {
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    var uncertain = false
    func makeCleanupUncertain() { uncertain = true }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func execute(_ command: GuestCommand, id: UUID) async throws -> GuestResponse {
        started = true; startWaiter?.resume(); startWaiter = nil
        var result = GuestResponse(id: id, success: true)
        do { try await Task.sleep(for: .seconds(60)) }
        catch { result.cancelled = true }
        result.requiresVMStop = uncertain
        return result
    }
}

final class GuestRequestHandlerTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (GuestRequestHandler, ControlledExecutor) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guest-handler-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = try GuestWorkspace(path: root.path, tenantUID: getuid(), tenantGID: getgid(), requireSeparateVolume: false)
        let executor = ControlledExecutor()
        return (GuestRequestHandler(executor: executor, workspace: workspace), executor)
    }

    func testCancelReachesActiveExecutionWhileSecondExecutionAndFilesAreRejected() async throws {
        let (handler, executor) = try fixture(), id = UUID()
        let execution = Task { await handler.handle(GuestRequest(id: id, operation: .execute, command: GuestCommand(executable: "/usr/bin/true"))) }
        await executor.waitStarted()
        let concurrent = await handler.handle(GuestRequest(operation: .execute, command: GuestCommand(executable: "/usr/bin/true")))
        XCTAssertEqual(concurrent.errorCode, "guest_busy")
        let files = await handler.handle(GuestRequest(operation: .mkdir, path: "a"))
        XCTAssertEqual(files.errorCode, "guest_busy")
        let cancelled = await handler.handle(GuestRequest(operation: .cancel, transferID: id))
        XCTAssertEqual(cancelled.cancelled, true)
        let result = await execution.value
        XCTAssertEqual(result.cancelled, true)
    }

    func testDisconnectedSessionCannotScheduleLaterExecution() async throws {
        let (handler, _) = try fixture()
        await handler.disconnect()
        let result = await handler.handle(GuestRequest(operation: .execute, command: GuestCommand(executable: "/usr/bin/true")))
        XCTAssertFalse(result.success)
    }

    func testUploadSurvivesAuthenticatedReconnect() async throws {
        let (handler, _) = try fixture(), id = UUID()
        let digest = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let begun = await handler.handle(GuestRequest(operation: .uploadBegin, transferID: id, path: "file", size: 0, sha256: digest))
        XCTAssertTrue(begun.success)
        await handler.disconnect()
        try await handler.beginSession()
        let status = await handler.handle(GuestRequest(operation: .uploadStatus, transferID: id))
        XCTAssertEqual(status.upload?.offset, 0)
        let committed = await handler.handle(GuestRequest(operation: .uploadCommit, transferID: id))
        XCTAssertEqual(committed.upload?.committed, true)
    }

    func testCleanupUncertaintySurvivesReconnect() async throws {
        let (handler, executor) = try fixture(), id = UUID()
        await executor.makeCleanupUncertain()
        let execution = Task { await handler.handle(GuestRequest(id: id, operation: .execute, command: GuestCommand(executable: "/usr/bin/true"))) }
        await executor.waitStarted()
        _ = await handler.handle(GuestRequest(operation: .cancel, transferID: id))
        _ = await execution.value
        await handler.disconnect()
        try await handler.beginSession()
        let result = await handler.handle(GuestRequest(operation: .ping))
        XCTAssertEqual(result.requiresVMStop, true)
        XCTAssertEqual(result.errorCode, "tenant_cleanup_uncertain")
    }
}
