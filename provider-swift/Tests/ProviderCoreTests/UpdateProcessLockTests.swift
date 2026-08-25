import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation
#if canImport(Darwin)
import Darwin
#endif

@Suite("Cross-process update lock", .serialized)
struct UpdateProcessLockTests {
    @Test("concurrent owner is refused")
    func contention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "update-lock-\(UUID().uuidString)",
            isDirectory: true
        )
        let path = root.appendingPathComponent("update.lock")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try UpdateProcessLock.acquire(at: path, operation: "first")
        defer { first.release() }
        do {
            _ = try UpdateProcessLock.acquire(at: path, operation: "second")
            Issue.record("second owner acquired an already-held lock")
        } catch UpdateProcessLock.LockError.busy(let owner) {
            #expect(owner?.operation == "first")
            #expect(owner?.pid == getpid())
            #expect(owner?.processIdentity == ProcessIdentity.current())
        }
    }

    @Test("lock path symlink is rejected without modifying its target")
    func symlinkPathIsRejected() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "update-lock-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let outside = root.appendingPathComponent("outside")
        let lockPath = root
            .appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent("update.lock")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: lockPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("preserve me".utf8).write(to: outside)
        try fileManager.createSymbolicLink(
            atPath: lockPath.path,
            withDestinationPath: outside.path
        )

        #expect(throws: UpdateProcessLock.LockError.self) {
            _ = try UpdateProcessLock.acquire(
                at: lockPath,
                operation: "must-not-follow"
            )
        }
        #expect(try Data(contentsOf: outside) == Data("preserve me".utf8))
        #expect(
            try fileManager.destinationOfSymbolicLink(atPath: lockPath.path)
                == outside.path
        )
    }

    @Test("self-updater session is blocked by the shared app installer lock")
    func updaterCoordinatesWithOneShotInstallers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shared-install-lock-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = try InstallMutationLock.acquirePrimary(
            in: root,
            timeout: 0
        )
        defer { installer.release() }
        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:1",
            installRoot: root,
            verifyCodeSignatures: false,
            currentVersion: "1.0.0"
        )

        do {
            _ = try updater.beginUpdateSession(
                operation: "must-not-race-installer",
                timeout: 0
            )
            Issue.record("self-updater acquired the one-shot installer lock")
        } catch UpdateError.lockBusy(_, let owner) {
            #expect(owner == nil)
        }
    }

    @Test("self-updater refuses a pending one-shot transaction and releases locks")
    func updaterRejectsShellRecoveryJournal() throws {
        for pendingName in [
            InstallMutationLock.appRelocationTransactionFileName,
            ".install-backup-123-456-789",
            ".install-staging-123-456-789",
        ] {
            try assertUpdaterRejectsPendingShellArtifact(named: pendingName)
        }
    }

    private func assertUpdaterRejectsPendingShellArtifact(
        named pendingName: String
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pending-shell-install-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = root.appendingPathComponent(
            pendingName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: pending,
            withIntermediateDirectories: true
        )
        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:1",
            installRoot: root,
            verifyCodeSignatures: false,
            currentVersion: "1.0.0"
        )

        do {
            _ = try updater.beginUpdateSession(
                operation: "must-recover-shell-first",
                timeout: 0
            )
            Issue.record(
                "self-updater ignored pending shell artifact \(pendingName)"
            )
        } catch UpdateError.replaceFailed(let reason) {
            #expect(reason.contains(pending.path))
        }

        try FileManager.default.removeItem(at: pending)
        let recovered = try updater.beginUpdateSession(
            operation: "locks-were-released",
            timeout: 0
        )
        recovered.release()
    }

    #if canImport(Darwin)
    @Test("kernel releases lock after owner is killed")
    func crashedOwnerRecovery() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "update-lock-crash-\(UUID().uuidString)",
            isDirectory: true
        )
        let path = root.appendingPathComponent("update.lock")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [
            "-e",
            """
            use Fcntl qw(:flock);
            $| = 1;
            open(my $fh, '>>', $ARGV[0]) or die $!;
            flock($fh, LOCK_EX) or die $!;
            print '1';
            sleep 30;
            """,
            path.path,
        ]
        let output = Pipe()
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning {
                _ = kill(child.processIdentifier, SIGKILL)
                child.waitUntilExit()
            }
        }
        let ready = output.fileHandleForReading.readData(ofLength: 1)
        #expect(ready == Data("1".utf8))

        do {
            _ = try UpdateProcessLock.acquire(at: path, operation: "parent")
            Issue.record("parent acquired child-owned lock")
        } catch UpdateProcessLock.LockError.busy {
            // Expected.
        }

        _ = kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()

        let recovered = try UpdateProcessLock.acquire(
            at: path,
            operation: "recovered",
            timeout: 1
        )
        recovered.release()
    }

    @Test("watchdog kills only matching stale provider lock owner")
    func watchdogRecoversWedgedProviderOwner() async throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let store = UpdateRecoveryStore(
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false
        )
        try FileManager.default.createDirectory(
            at: store.recoveryRoot,
            withIntermediateDirectories: true
        )
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [
            "-e",
            """
            use Fcntl qw(:flock);
            $| = 1;
            open(my $fh, '>>', $ARGV[0]) or die $!;
            flock($fh, LOCK_EX) or die $!;
            print '1';
            sleep 30;
            """,
            store.lockPath.path,
        ]
        let output = Pipe()
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning {
                _ = kill(child.processIdentifier, SIGKILL)
                child.waitUntilExit()
            }
        }
        #expect(
            output.fileHandleForReading.readData(ofLength: 1)
                == Data("1".utf8)
        )
        guard let identity = ProcessIdentity.read(
            pid: child.processIdentifier
        ) else {
            Issue.record("could not read child process identity")
            return
        }
        let owner = UpdateProcessLock.Owner(
            pid: child.processIdentifier,
            processIdentity: identity,
            operation: "wedged-provider-update",
            acquiredAt: 1
        )
        let ownerData = try JSONEncoder().encode(owner)
        let handle = try FileHandle(forWritingTo: store.lockPath)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: ownerData)
        try handle.synchronize()
        try handle.close()

        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:1",
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false,
            currentVersion: fixture.oldVersion
        )
        let service = WatchdogRecoveryService(
            updater: updater,
            dependencies: .init(
                kickstartIfLoaded: { true },
                launchSnapshot: { nil },
                providerStillLoaded: { true },
                terminateStaleLockOwner: { candidate in
                    guard candidate.processIdentity == identity,
                          identity.isCurrent()
                    else {
                        return false
                    }
                    _ = kill(identity.pid, SIGKILL)
                    child.waitUntilExit()
                    return !identity.isCurrent()
                },
                log: { _ in }
            )
        )
        let result = await service.recoverDownProvider(
            autoUpdateEnabled: false,
            inactiveProviderIdentity: identity,
            now: 100
        )
        #expect(result == .restartIssued(
            updatedTo: nil,
            rolledBackTo: nil
        ))
    }
    #endif
}
