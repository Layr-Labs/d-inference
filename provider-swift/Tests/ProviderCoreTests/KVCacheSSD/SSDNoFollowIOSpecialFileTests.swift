// Copyright © 2026 Eigen Labs.

import Darwin
import Foundation
import Testing
@testable import ProviderCore

@Suite("SSD no-follow special-file handling", .serialized)
struct SSDNoFollowIOSpecialFileTests {
    @Test func fifoReplacementCannotBlockRead() async throws {
        let root = try Self.makeRoot()
        defer { Self.removeRoot(root) }
        let fixturePath = root.path
        let result = await #expect(
            processExitsWith: .success,
            observing: [\.standardOutputContent]
        ) { [fixturePath = fixturePath as String] in
            SSDNoFollowIOSpecialFileTests.runFIFOChild(rootPath: fixturePath, touching: false)
        }
        // On the old implementation the watchdog terminates the child. The
        // framework reports SIGALRM; this parent-owned marker distinguishes
        // reaching the intended open from a setup failure. Cleanup follows
        // Swift Testing's reaping even when the expectation returns nil.
        let phase = try String(contentsOf: root.appendingPathComponent("phase"), encoding: .utf8)
        #expect(phase == "FIFO_READY" || phase == "FIFO_READ_REJECTED")
        if let result {
            #expect(result.exitStatus == .exitCode(0))
            #expect(phase == "FIFO_READ_REJECTED")
            #expect(String(decoding: result.standardOutputContent, as: UTF8.self).contains("FIFO_READ_REJECTED"))
        }
    }

    @Test func fifoReplacementCannotBlockTouch() async throws {
        let root = try Self.makeRoot()
        defer { Self.removeRoot(root) }
        let fixturePath = root.path
        let result = await #expect(
            processExitsWith: .success,
            observing: [\.standardOutputContent]
        ) { [fixturePath = fixturePath as String] in
            SSDNoFollowIOSpecialFileTests.runFIFOChild(rootPath: fixturePath, touching: true)
        }
        let phase = try String(contentsOf: root.appendingPathComponent("phase"), encoding: .utf8)
        #expect(phase == "FIFO_READY" || phase == "FIFO_TOUCH_REJECTED")
        if let result {
            #expect(result.exitStatus == .exitCode(0))
            #expect(phase == "FIFO_TOUCH_REJECTED")
            #expect(String(decoding: result.standardOutputContent, as: UTF8.self).contains("FIFO_TOUCH_REJECTED"))
        }
    }

    @Test func regularReadAndTouchRetainTheirContract() throws {
        let root = try Self.makeRoot()
        defer { Self.removeRoot(root) }
        let target = root.appendingPathComponent("target")
        let handle = try SSDNoFollowIO.openRegularFileForReading(at: target)
        defer { try? handle.close() }
        #expect(try handle.readToEnd() == Data("synthetic fixture".utf8))
        SSDNoFollowIO.touchRegularFile(at: target, modificationDate: Date(timeIntervalSince1970: 123))
        var info = stat()
        #expect(lstat(target.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFREG)
        #expect(info.st_mtimespec.tv_sec == 123)
    }

    @Test func directoryAndSymlinkStayRejected() throws {
        let root = try Self.makeRoot()
        defer { Self.removeRoot(root) }
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("target"))
        for target in [directory, link] {
            #expect(throws: SSDBlockStoreError.self) {
                let handle = try SSDNoFollowIO.openRegularFileForReading(at: target)
                try handle.close()
            }
        }
        let original = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("target").path)[.modificationDate]
        SSDNoFollowIO.touchRegularFile(at: link, modificationDate: Date(timeIntervalSince1970: 1))
        let retained = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("target").path)[.modificationDate]
        #expect((original as? Date) == (retained as? Date))
        let directoryDate = try FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate]
        SSDNoFollowIO.touchRegularFile(at: directory, modificationDate: Date(timeIntervalSince1970: 1))
        let unchangedDirectoryDate = try FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate]
        #expect((directoryDate as? Date) == (unchangedDirectoryDate as? Date))
        #expect(SSDNoFollowIO.regularFileStatus(at: directory) == .invalid)
    }

    private static func makeRoot() throws -> URL {
        let root = try SSDTestDirectory.parent()
            .appendingPathComponent("ssd-nofollow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            try Data("synthetic fixture".utf8).write(to: root.appendingPathComponent("target"))
            try Data("CREATED".utf8).write(to: root.appendingPathComponent("phase"))
        } catch {
            removeRoot(root)
            throw error
        }
        return root
    }

    private static func removeRoot(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Failed to remove owned special-file fixture: \(error)") }
    }

    private static func runFIFOChild(rootPath: String, touching: Bool) -> Never {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_DFL
        action.sa_flags = 0
        guard sigemptyset(&action.sa_mask) == 0,
              sigaction(SIGALRM, &action, nil) == 0 else { Darwin.exit(70) }
        var mask = sigset_t()
        guard sigemptyset(&mask) == 0, sigaddset(&mask, SIGALRM) == 0,
              pthread_sigmask(SIG_UNBLOCK, &mask, nil) == 0 else { Darwin.exit(71) }
        _ = alarm(5)
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let target = root.appendingPathComponent("target")
        let hook: @Sendable (SSDActiveIOOperation) -> Void = { _ in
            guard unlink(target.path) == 0,
                  mkfifo(target.path, S_IRUSR | S_IWUSR) == 0 else { Darwin.exit(72) }
            var times = [timespec(tv_sec: 123456, tv_nsec: 0), timespec(tv_sec: 123456, tv_nsec: 0)]
            guard utimensat(AT_FDCWD, target.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { Darwin.exit(73) }
            do { try Data("FIFO_READY".utf8).write(to: root.appendingPathComponent("phase")) }
            catch { Darwin.exit(74) }
        }
        if touching {
            SSDNoFollowIO.touchRegularFile(at: target, modificationDate: Date(timeIntervalSince1970: 1), beforeOperation: hook)
        } else {
            do {
                let handle = try SSDNoFollowIO.openRegularFileForReading(at: target, beforeOperation: hook)
                try? handle.close()
                Darwin.exit(75)
            } catch SSDBlockStoreError.ioFailure(let reason) {
                guard reason == "read target is not a regular file" else { Darwin.exit(76) }
            } catch { Darwin.exit(77) }
        }
        var info = stat()
        guard lstat(target.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFIFO,
              info.st_mtimespec.tv_sec == 123456,
              info.st_mtimespec.tv_nsec == 0 else { Darwin.exit(78) }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0,
              let descriptors = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
        else { Darwin.exit(80) }
        // Process teardown must not conceal a leaked target or parent FD.
        // Disappearing unrelated descriptors are harmless; never open the FIFO.
        for name in descriptors {
            guard let descriptor = Int32(name) else { continue }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else { continue }
            let targetLeaked = opened.st_dev == info.st_dev && opened.st_ino == info.st_ino
            let parentLeaked = opened.st_dev == rootInfo.st_dev && opened.st_ino == rootInfo.st_ino
            guard !targetLeaked, !parentLeaked else { Darwin.exit(81) }
        }
        _ = alarm(0)
        let success = touching ? "FIFO_TOUCH_REJECTED" : "FIFO_READ_REJECTED"
        do {
            try Data(success.utf8).write(to: root.appendingPathComponent("phase"))
            try FileHandle.standardOutput.write(contentsOf: Data((success + "\n").utf8))
        } catch { Darwin.exit(79) }
        Darwin.exit(0)
    }
}
