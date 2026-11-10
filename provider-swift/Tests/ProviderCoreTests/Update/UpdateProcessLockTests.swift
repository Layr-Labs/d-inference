import Foundation
import Testing
@testable import ProviderCore
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

    /// 0.10.8 on a pair: "another update operation owns the lock (pid 9523, provider-instance)" for a single-Mac
    /// provider that was serving. The owner is named for what it is.
    @Test("a held provider-instance lock names the single-Mac provider serving, never an update")
    func providerInstanceOwnerIsNamed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-lock-named-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("provider.pid.lock")
        let held = try UpdateProcessLock.acquire(at: path, operation: "provider-instance")
        defer { held.release() }
        let error = #expect(throws: UpdateProcessLock.LockError.self) {
            _ = try UpdateProcessLock.acquire(at: path, operation: "provider-instance")
        }
        let text = error.map { String(describing: $0) } ?? ""
        #expect(text.contains("a single-Mac Darkbloom provider (process \(getpid())) is serving on this Mac"), "\(text)")
        #expect(text.contains("stop --solo"), "\(text)")
        #expect(!text.contains("update"), "\(text)")
    }

    @Test("an update, a rollback and a stop are each named as such")
    func otherOwnersAreNamed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-lock-kinds-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (operation, words) in [("manual-update-restart", "an update (process"), ("operator-rollback", "a rollback (process"),
                                   ("provider-lifecycle", "a stop or restart of the provider (process")] {
            let path = root.appendingPathComponent("\(operation).lock")
            let held = try UpdateProcessLock.acquire(at: path, operation: operation)
            defer { held.release() }
            let error = #expect(throws: UpdateProcessLock.LockError.self) { _ = try UpdateProcessLock.acquire(at: path, operation: "x") }
            let text = error.map { String(describing: $0) } ?? ""
            #expect(text.contains(words) && !text.contains("another update operation"), "\(operation): \(text)")
        }
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
            umask 0077;
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
            umask 0077;
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
            currentVersion: fixture.oldVersion,
            releaseCheck: .withoutPauses
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
