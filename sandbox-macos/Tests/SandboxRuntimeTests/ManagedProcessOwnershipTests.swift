import Darwin
import Foundation
import SandboxRuntime
import XCTest

final class ManagedProcessOwnershipTests: XCTestCase, @unchecked Sendable {
    func testAwaitedTimeoutRetainsExclusiveChildOwnershipUntilCooperativeExit() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let process = try fixture.start()
        try await fixture.waitFor("ready")
        XCTAssertFalse(try fixture.canAcquireShared())
        do {
            _ = try await process.wait(timeoutSeconds: 1, cooperativeGracePeriod: .seconds(1), signalGracePeriod: .milliseconds(100))
            XCTFail("owner should time out")
        } catch let error as SandboxRuntimeError { XCTAssertEqual(error, .operationTimedOut("managed process")) }
        XCTAssertTrue(fixture.exists("exited"))
        XCTAssertFalse(fixture.exists("signal"))
        XCTAssertTrue(try fixture.canAcquireShared())
    }

    func testAwaitCancellationWaitsForCooperativeOwnerAndReleasesLockAfterExit() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let process = try fixture.start()
        try await fixture.waitFor("ready")
        let task = Task { try await process.wait(timeoutSeconds: 30, cooperativeGracePeriod: .seconds(1), signalGracePeriod: .milliseconds(100)) }
        XCTAssertFalse(try fixture.canAcquireShared()); task.cancel()
        do { _ = try await task.value; XCTFail("owner wait should cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.exists("exited")); XCTAssertFalse(fixture.exists("signal"))
        XCTAssertTrue(try fixture.canAcquireShared())
    }

    func testAlreadyCancelledWaitStillCleansUpSpawnedOwner() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let process = try fixture.start()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await process.wait(timeoutSeconds: 30, cooperativeGracePeriod: .seconds(1), signalGracePeriod: .milliseconds(100))
        }
        do { _ = try await task.value; XCTFail("cancelled wait must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.exists("exited")); XCTAssertTrue(try fixture.canAcquireShared())
    }

    func testBrokerDeathSignalsEOFButChildKeepsExclusiveLockUntilItsOwnExit() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let executable = Bundle(for: ManagedProcessOwnershipTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("SandboxProcessLifecycleProbe")
        let broker = try ManagedProcessBrokerFixture(executable: executable, directory: fixture.directory)
        defer {
            try? Data().write(to: fixture.directory.appendingPathComponent("release"))
            do { try broker.killAndWait() }
            catch { XCTFail("broker fixture cleanup failed: \(error)") }
        }
        try await fixture.waitFor("ready")
        XCTAssertFalse(try fixture.canAcquireShared())
        try broker.killAndWait()
        try await fixture.waitFor("eof")
        XCTAssertFalse(try fixture.canAcquireShared(), "child must keep machine ownership after broker death")
        try Data().write(to: fixture.directory.appendingPathComponent("release"))
        try await fixture.waitFor("exited")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(try fixture.canAcquireShared()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try fixture.canAcquireShared())
    }

    private struct Fixture: Sendable {
        let directory: URL
        var lock: URL { directory.appendingPathComponent("ownership.lock") }
        init() throws {
            directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("managed-ownership-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data().write(to: lock); _ = chmod(lock.path, 0o600)
            try Data(Self.child.utf8).write(to: directory.appendingPathComponent("child.py"))
        }
        func start() throws -> SandboxManagedProcess {
            let descriptor = open(lock.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EWOULDBLOCK) }
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
            guard duplicate >= 64 else { throw POSIXError(.EIO) }
            defer { close(duplicate) }
            return try SandboxProcessRunner().start(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [directory.appendingPathComponent("child.py").path, directory.path, "normal"],
                cooperativeControl: SandboxCooperativeProcessControl(environmentVariable: "DARKBLOOM_TEST_OWNER_EOF"),
                runtimeAuthorityDescriptor: duplicate)
        }
        func canAcquireShared() throws -> Bool {
            let fd = open(lock.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
            if flock(fd, LOCK_SH | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK else { throw POSIXError(.EIO) }; return false
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
        func waitFor(_ name: String) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !exists(name), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard exists(name) else { throw SandboxRuntimeError.operationTimedOut("test owner marker \(name)") }
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        static let child = #"""
        import fcntl,os,pathlib,signal,sys,time
        root=pathlib.Path(sys.argv[1]);fd=int(os.environ['DARKBLOOM_HOST_RUNTIME_FD'])
        assert fd==4
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        def signalled(number,frame):
            (root/'signal').write_text(str(number));sys.exit(70)
        signal.signal(signal.SIGTERM,signalled)
        (root/'ready').write_text(str(os.getpid()))
        assert os.read(int(os.environ['DARKBLOOM_TEST_OWNER_EOF']),1)==b''
        (root/'eof').write_text('observed')
        if sys.argv[2]=='hold':
            deadline=time.monotonic()+5
            while not (root/'release').exists() and time.monotonic()<deadline:time.sleep(.01)
        else:time.sleep(.1)
        (root/'exited').write_text('cooperative')
        os.close(fd)
        """#
    }
}
