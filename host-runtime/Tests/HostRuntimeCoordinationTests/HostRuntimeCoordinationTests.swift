import Darwin
import Foundation
@testable import HostRuntimeCoordination
import XCTest

final class HostRuntimeCoordinationTests: XCTestCase {
    func testLegacyInferenceDoesNotCreateAuthority() throws {
        let fixture = try Fixture(createAuthority: false)
        defer { fixture.remove() }
        XCTAssertNil(try fixture.authority.acquireInferenceIfInstalled())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertThrowsError(try fixture.authority.acquireSandbox()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .authorityMissing)
        }
    }

    func testExistingDirectoryWithMissingLockFailsClosedForBothRoles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.lock)
        XCTAssertThrowsError(try fixture.authority.acquireInferenceIfInstalled())
        XCTAssertThrowsError(try fixture.authority.acquireSandbox())
    }

    func testSharedInferenceProcessesExcludeSandboxUntilBothExit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try Probe(fixture: fixture, role: "inference")
        defer { first.finish() }
        let second = try Probe(fixture: fixture, role: "inference")
        defer { second.finish() }
        XCTAssertEqual(first.readiness, "acquired\n")
        XCTAssertEqual(second.readiness, "acquired\n")
        XCTAssertThrowsError(try fixture.authority.acquireSandbox()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .occupied)
        }
        first.finish()
        XCTAssertThrowsError(try fixture.authority.acquireSandbox())
        second.finish()
        let lease = try fixture.authority.acquireSandbox()
        try lease.validate()
        withExtendedLifetime(lease) {}
    }

    func testSandboxProcessExcludesInferenceAndReleasesOnExit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sandbox = try Probe(fixture: fixture, role: "sandbox")
        defer { sandbox.finish() }
        XCTAssertEqual(sandbox.readiness, "acquired\n")
        XCTAssertThrowsError(try fixture.authority.acquireInferenceIfInstalled()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .occupied)
        }
        sandbox.finish()
        let lease = try XCTUnwrap(fixture.authority.acquireInferenceIfInstalled())
        try lease.validate()
    }

    func testRejectsSymlinksHardlinksAndWritableAuthority() throws {
        for mutation in ["symlink", "hardlink", "directory-write", "lock-mode"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            switch mutation {
            case "symlink":
                let original = fixture.directory.appendingPathComponent("original.lock")
                try FileManager.default.moveItem(at: fixture.lock, to: original)
                try FileManager.default.createSymbolicLink(at: fixture.lock, withDestinationURL: original)
            case "hardlink":
                try FileManager.default.linkItem(at: fixture.lock, to: fixture.directory.appendingPathComponent("alias"))
            case "directory-write":
                try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: fixture.directory.path)
            default:
                try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fixture.lock.path)
            }
            XCTAssertThrowsError(try fixture.authority.acquireSandbox(), mutation)
        }
    }

    func testHeldLeaseDetectsLockAndDirectoryReplacement() throws {
        for replaceDirectory in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let lease = try fixture.authority.acquireSandbox()
            if replaceDirectory {
                try FileManager.default.moveItem(at: fixture.directory,
                                                  to: fixture.root.appendingPathComponent("old-authority"))
                try fixture.createAuthority()
            } else {
                try FileManager.default.moveItem(at: fixture.lock,
                                                  to: fixture.directory.appendingPathComponent("old.lock"))
                try fixture.createLock()
            }
            XCTAssertThrowsError(try lease.validate()) {
                XCTAssertEqual($0 as? HostRuntimeOwnershipError, .authorityChanged)
            }
        }
    }

    func testProductionPolicyRejectsUserOwnedAuthority() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        guard geteuid() != 0 else { throw XCTSkip("requires non-root fixture owner") }
        let production = HostRuntimeAuthority(directory: fixture.directory)
        XCTAssertThrowsError(try production.acquireSandbox())
    }

    func testInheritedVMLeaseSurvivesParentReleaseUntilChildExit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var parentLease: HostRuntimeLease? = try fixture.authority.acquireSandbox()
        let child = try XCTUnwrap(parentLease).withInheritedDescriptor { descriptor in
            XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
            return try InheritedProbe(descriptor: descriptor)
        }
        defer { child.finish() }
        XCTAssertEqual(child.readiness, "acquired\n")
        parentLease = nil
        XCTAssertThrowsError(try fixture.authority.acquireInferenceIfInstalled()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .occupied)
        }
        child.finish()
        let inference = try XCTUnwrap(fixture.authority.acquireInferenceIfInstalled())
        try inference.validate()
    }

    func testSharedInferenceLeaseCannotAuthorizeVMInstallation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shared = try XCTUnwrap(fixture.authority.acquireInferenceIfInstalled())
        XCTAssertNoThrow(try shared.validate())
        XCTAssertThrowsError(try shared.validateExclusive()) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .insecureAuthority)
        }
    }

    private struct Fixture {
        let root: URL
        let directory: URL
        var lock: URL { directory.appendingPathComponent(HostRuntimeAuthority.lockName) }
        var authority: HostRuntimeAuthority {
            HostRuntimeAuthority(testDirectory: directory, ownerUID: geteuid(), groupID: getegid())
        }
        init(createAuthority: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("host-runtime-\(UUID().uuidString)")
            directory = root.appendingPathComponent("authority")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            if createAuthority { try self.createAuthority() }
        }
        func createAuthority() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o750])
            try createLock()
        }
        func createLock() throws {
            let descriptor = open(lock.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o660)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { close(descriptor) }
            guard fchmod(descriptor, 0o660) == 0, fchown(descriptor, geteuid(), getegid()) == 0 else {
                throw POSIXError(.EIO)
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class Probe {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let readiness: String
        private var finished = false
        init(fixture: Fixture, role: String) throws {
            let executable = Bundle(for: HostRuntimeCoordinationTests.self).bundleURL
                .deletingLastPathComponent().appendingPathComponent("HostRuntimeLockProbe")
            process.executableURL = executable
            process.arguments = [fixture.directory.path, role, String(geteuid()), String(getegid())]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            readiness = String(decoding: output.fileHandleForReading.readData(ofLength: 9), as: UTF8.self)
        }
        func finish() {
            guard !finished else { return }
            finished = true
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        deinit { finish() }
    }

    private final class InheritedProbe {
        private var child: pid_t = 0
        private var inputWriter: Int32 = -1
        let readiness: String
        init(descriptor: Int32) throws {
            var input = [Int32](repeating: -1, count: 2)
            var output = [Int32](repeating: -1, count: 2)
            guard pipe(&input) == 0, pipe(&output) == 0 else { throw POSIXError(.EIO) }
            defer { close(input[0]); close(output[1]) }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0,
                  posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.EIO) }
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            guard posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, descriptor, 4) == 0,
                  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
            else { throw POSIXError(.EIO) }
            let executable = Bundle(for: HostRuntimeCoordinationTests.self).bundleURL
                .deletingLastPathComponent().appendingPathComponent("HostRuntimeLockProbe").path
            let values: [String] = [executable, "inherited", "4"]
            let strings = values.map { value in value.withCString { strdup($0) } }
            defer { for string in strings { free(string) } }
            var arguments = strings + [nil]
            var environment: [UnsafeMutablePointer<CChar>?] = [nil]
            let status = posix_spawn(&child, executable, &actions, &attributes, &arguments, &environment)
            guard status == 0 else {
                close(input[1]); close(output[0])
                throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
            }
            inputWriter = input[1]
            let reader = FileHandle(fileDescriptor: output[0], closeOnDealloc: true)
            readiness = String(decoding: reader.readData(ofLength: 9), as: UTF8.self)
        }
        func finish() {
            guard child > 0 else { return }
            close(inputWriter)
            inputWriter = -1
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
            child = 0
        }
        deinit { finish() }
    }
}
