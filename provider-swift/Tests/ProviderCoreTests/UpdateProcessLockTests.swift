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
    #endif
}
