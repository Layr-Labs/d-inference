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

    @Test("recovery scan recognizes every unresolved transaction prefix")
    func recoveryArtifactScanRecognizesPendingState() throws {
        for name in [
            InstallMutationLock.appRelocationTransactionFileName,
            ".install-backup-123-456-789",
            ".install-staging-123-456-789",
        ] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let pending = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: pending,
                withIntermediateDirectories: false
            )

            #expect(
                try InstallMutationLock.pendingOneShotTransaction(in: root)?
                    .lastPathComponent == name
            )
        }
    }

    @Test("shell-only recovery scan excludes the app relocation journal")
    func shellRecoveryScanExcludesAppRelocation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(
            to: InstallMutationLock.appRelocationTransactionURL(in: root)
        )

        #expect(
            try InstallMutationLock.pendingShellInstallTransaction(in: root)
                == nil
        )
        #expect(
            try InstallMutationLock.pendingOneShotTransaction(in: root)?
                .lastPathComponent
                == InstallMutationLock.appRelocationTransactionFileName
        )
    }

    @Test("recovery scan ignores cleanup-only and nonexistent transaction prefixes")
    func recoveryArtifactScanIgnoresNonPendingState() throws {
        for name in [
            ".install-garbage-123-456-789",
            ".install-restore-123-456-789",
            ".install-legacy-bin-123-456",
            ".install-transaction-interrupted",
        ] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: false
            )

            #expect(
                try InstallMutationLock.pendingOneShotTransaction(in: root) == nil
            )
        }
    }

    @Test("recovery scan fails closed when the install root is unavailable")
    func recoveryArtifactScanFailure() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-install-root-\(UUID().uuidString)")

        #expect(throws: InstallMutationLock.LockError.self) {
            try InstallMutationLock.pendingOneShotTransaction(in: missing)
        }
    }

    #if canImport(Darwin)
    @Test("macOS shell flock interoperates and a killed owner needs no takeover")
    func shellFlockInteropAndCrashRecovery() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockPath = InstallMutationLock.primaryLockURL(in: root)
        let readyPath = root.appendingPathComponent("ready")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [
            "-MFcntl=:flock",
            "-e",
            """
            open(my $lock, ">>", $ARGV[0]) or die $!;
            flock($lock, LOCK_EX) or die $!;
            open(my $ready, ">", $ARGV[1]) or die $!;
            print {$ready} "ready";
            close($ready) or die $!;
            sleep 30;
            """,
            lockPath.path,
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
