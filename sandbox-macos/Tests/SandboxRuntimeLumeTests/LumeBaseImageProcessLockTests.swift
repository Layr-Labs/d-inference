import Darwin
import Foundation
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeBaseImageProcessLockTests: XCTestCase {
    func testNativeOwnerRecordLockSurvivesRevalidationAndReleasesAtScopeEnd() async throws {
        let f = try fixture()
        do {
            let locks = try f.acquire()
            try await checkOwnerLock(f.ownerLock, blocked: true)
            try locks.validateIdentity()
            try locks.validateUnchanged()
            try await checkOwnerLock(f.ownerLock, blocked: true)
        }
        try await checkOwnerLock(f.ownerLock, blocked: false)
    }

    func testLiveNativeOwnerPreventsOfflineLockAcquisition() async throws {
        let f = try fixture()
        do { let locks = try f.acquire(); try locks.validateUnchanged() }
        let ready = f.vm.directory.appendingPathComponent("native-owner-ready")
        let script = """
        import fcntl, os, pathlib, sys, time
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOFOLLOW)
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        pathlib.Path(sys.argv[2]).write_text('ready')
        time.sleep(30)
        """
        let process = try SandboxProcessRunner().start(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, f.ownerLock.path, ready.path], maximumOutputBytes: 4096)
        let observation: Result<Void, Error>
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: ready.path), process.isRunning,
                  ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
            XCTAssertTrue(process.isRunning)
            XCTAssertThrowsError(try f.acquire())
            observation = .success(())
        } catch { observation = .failure(error) }
        _ = await process.stop(cooperativeGracePeriod: .zero, signalGracePeriod: .milliseconds(100))
        XCTAssertFalse(process.isRunning)
        try observation.get()
        let recovered = try f.acquire()
        try recovered.validateUnchanged()
    }

    private func checkOwnerLock(_ path: URL, blocked: Bool) async throws {
        let script = """
        import errno, fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOFOLLOW)
        blocked = False
        try:
            fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN): raise
            blocked = True
        sys.exit(0 if blocked == (sys.argv[2] == 'blocked') else 1)
        """
        let result = try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, path.path, blocked ? "blocked" : "free"], timeoutSeconds: 5, maximumOutputBytes: 4096)
        XCTAssertEqual(result.exitCode, 0, String(decoding: result.standardError, as: UTF8.self))
    }

    private func fixture() throws -> LumeRootSourceTestFixture {
        let f = try LumeRootSourceTestFixture(); addTeardownBlock { f.remove() }; return f
    }
}
