import Foundation
import Testing
@testable import ProviderCoreFoundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Install mutation lock", .serialized)
struct InstallMutationLockTests {
    @Test("primary lock rejects a concurrent owner and reopens after release")
    func primaryContentionAndRelease() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try InstallMutationLock.acquirePrimary(in: root, timeout: 0)
        do {
            _ = try InstallMutationLock.acquirePrimary(in: root, timeout: 0)
            Issue.record("a second owner acquired the primary installation lock")
        } catch InstallMutationLock.LockError.timedOut(let path) {
            #expect(path == InstallMutationLock.primaryLockURL(in: root).path)
        }

        first.release()
        let recovered = try InstallMutationLock.acquirePrimary(in: root, timeout: 0)
        recovered.release()
    }

    @Test("one-shot installer holds both current and legacy lock files")
    func oneShotInstallerCoversLegacyUpdater() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyPath = InstallMutationLock.legacyUpdateLockURL(in: root)
        try FileManager.default.createDirectory(
            at: legacyPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale-owner".utf8).write(to: legacyPath)

        let install = try InstallMutationLock.acquireForOneShotInstall(
            in: root,
            timeout: 0
        )
        defer { install.release() }
        #expect(try Data(contentsOf: legacyPath).isEmpty)

        let descriptor = open(legacyPath.path, O_RDWR | O_CLOEXEC)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { _ = close(descriptor) }

        errno = 0
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) != 0)
        #expect(errno == EWOULDBLOCK || errno == EAGAIN)
    }

    #if canImport(Darwin)
    @Test("macOS lockf interoperates and a killed owner needs no stale takeover")
    func lockfInteropAndCrashRecovery() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockPath = InstallMutationLock.primaryLockURL(in: root)
        let readyPath = root.appendingPathComponent("ready")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        child.arguments = [
            "-k",
            lockPath.path,
            "/bin/sh",
            "-c",
            "printf ready > \"$1\"; exec /bin/sleep 30",
            "lock-holder",
            readyPath.path,
        ]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning {
                _ = kill(child.processIdentifier, SIGKILL)
                child.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: readyPath.path),
              Date() < deadline
        {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(atPath: readyPath.path))

        do {
            _ = try InstallMutationLock.acquirePrimary(in: root, timeout: 0)
            Issue.record("Swift acquired the shell-owned installation lock")
        } catch InstallMutationLock.LockError.timedOut {
            // Expected.
        }

        _ = kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        let recovered = try InstallMutationLock.acquirePrimary(
            in: root,
            timeout: 1
        )
        recovered.release()
    }
    #endif

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-install-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }
}
