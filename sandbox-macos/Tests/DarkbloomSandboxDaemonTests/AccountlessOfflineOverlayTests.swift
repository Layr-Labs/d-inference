import Darwin
import Foundation
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessOfflineOverlayTests: XCTestCase {
    private enum Interrupted: Error { case copy }

    func testPublishesOnlyDeclaredFilesAndBootJobLastThenReplaysWithoutWriting() async throws {
        let f = try await fixture()
        var published: [String] = []
        var overlay = f.overlay
        overlay.didPublish = { published.append($0) }
        try f.stage(overlay)
        XCTAssertEqual(published.count, 10)
        XCTAssertEqual(published.last, f.plan.jobRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.staged.path))
        let inode = try inode(f.job)
        let receipt = try Data(contentsOf: f.staged)
        published.removeAll()
        try f.stage(overlay)
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(try self.inode(f.job), inode)
        XCTAssertEqual(try Data(contentsOf: f.staged), receipt)
        XCTAssertEqual(try String(contentsOf: f.data.appendingPathComponent("Library/preserve.txt"), encoding: .utf8), "unrelated guest file")
        for (relative, hash) in f.plan.files {
            let path = f.data.appendingPathComponent(relative)
            XCTAssertEqual(BaseGuestRelease.digest(try Data(contentsOf: path)), hash)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int,
                           Int(try f.plan.fileMode(relative)))
        }
    }

    func testPartialCopyResumesMissingFilesWithoutReplacingPublishedPrefix() async throws {
        let f = try await fixture()
        var published: [String] = []
        var overlay = f.overlay
        overlay.didPublish = {
            published.append($0)
            if published.count == 4 { throw Interrupted.copy }
        }
        XCTAssertThrowsError(try f.stage(overlay))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.job.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.staged.path))
        let prefix = try Dictionary(uniqueKeysWithValues: published.map { ($0, try inode(f.data.appendingPathComponent($0))) })
        published.removeAll()
        overlay.didPublish = { published.append($0) }
        try f.stage(overlay)
        XCTAssertEqual(published.count, 6)
        XCTAssertEqual(published.last, f.plan.jobRelativePath)
        for (path, original) in prefix { XCTAssertEqual(try inode(f.data.appendingPathComponent(path)), original) }
    }

    func testLostAcknowledgementAfterJobPublicationCanRecordMatchingStagedState() async throws {
        let f = try await fixture()
        var overlay = f.overlay
        overlay.didPublish = { if $0 == f.plan.jobRelativePath { throw Interrupted.copy } }
        XCTAssertThrowsError(try f.stage(overlay))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.job.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.staged.path))
        let original = try inode(f.job)
        overlay.didPublish = { _ in XCTFail("matching replay published another file") }
        try f.stage(overlay)
        XCTAssertEqual(try inode(f.job), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.staged.path))
    }

    func testConflictingLinkedSharedAndSpecialPartialFilesCannotResume() async throws {
        for mutation in ["changed", "symlink", "hardlink", "fifo", "shared", "extra"] {
            let f = try await fixture()
            var first: String?
            var overlay = f.overlay
            overlay.didPublish = { first = $0; throw Interrupted.copy }
            XCTAssertThrowsError(try f.stage(overlay))
            let path = f.data.appendingPathComponent(try XCTUnwrap(first))
            let safe = f.data.appendingPathComponent("Library/preserve.txt")
            switch mutation {
            case "changed":
                XCTAssertEqual(chmod(path.path, 0o600), 0)
                try Data("different".utf8).write(to: path)
                XCTAssertEqual(chmod(path.path, 0o400), 0)
            case "symlink":
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: safe)
            case "hardlink": try FileManager.default.linkItem(at: path, to: f.data.appendingPathComponent("alias"))
            case "fifo":
                try FileManager.default.removeItem(at: path)
                XCTAssertEqual(mkfifo(path.path, 0o400), 0)
            case "shared": XCTAssertEqual(chmod(path.path, 0o444), 0)
            default: try Data("unknown".utf8).write(to: f.stageDirectory.appendingPathComponent("extra"))
            }
            overlay.didPublish = { _ in XCTFail("conflicting replay wrote another file") }
            XCTAssertThrowsError(try f.stage(overlay), mutation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.job.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.staged.path))
            XCTAssertEqual(try String(contentsOf: safe, encoding: .utf8), "unrelated guest file")
        }
    }

    func testBootIntentClosesRecoveryEvenIfNoResultHasBeenWritten() async throws {
        let f = try await fixture()
        var overlay = f.overlay
        overlay.didPublish = { _ in
            try Data().write(to: f.journalDirectory.appendingPathComponent("boot-intent.json"))
            throw Interrupted.copy
        }
        XCTAssertThrowsError(try f.stage(overlay))
        XCTAssertThrowsError(try f.stage()) { error in
            guard case AccountlessInstallationError.stagingClosed = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.job.path))
    }

    func testExistingConflictingJobFailsBeforeCreatingPayloadDirectory() async throws {
        let f = try await fixture()
        try Data("another root job".utf8).write(to: f.job)
        XCTAssertEqual(chmod(f.job.path, 0o400), 0)
        XCTAssertThrowsError(try f.stage())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.stageDirectory.deletingLastPathComponent().path))
        XCTAssertEqual(try String(contentsOf: f.job, encoding: .utf8), "another root job")
    }

    func testCompletedStagingCannotRepairSubsequentlyMissingFiles() async throws {
        for removeJob in [false, true] {
            let f = try await fixture()
            try f.stage()
            let removed = removeJob ? f.job : f.stageDirectory.appendingPathComponent("first-boot.zsh")
            try FileManager.default.removeItem(at: removed)
            var overlay = f.overlay
            overlay.didPublish = { _ in XCTFail("completed staging repaired changed state") }
            XCTAssertThrowsError(try f.stage(overlay))
            XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        }
    }

    func testSignatureAttributesSurvivePublicationAndAreRequiredOnReplay() async throws {
        let f = try await fixture(verifySignatures: true)
        try f.stage()
        let manifest = f.data.appendingPathComponent(f.plan.stageRelativePath + "/release/release-manifest.json")
        let contents = try Data(contentsOf: manifest)
        XCTAssertEqual(chmod(manifest.path, 0o600), 0)
        let result = try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--remove-signature", manifest.path], timeoutSeconds: 10)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(chmod(manifest.path, 0o400), 0)
        XCTAssertEqual(try Data(contentsOf: manifest), contents)
        XCTAssertThrowsError(try f.stage())
    }

    func testReplacingMountedDirectoryCannotPublishTheBootJob() async throws {
        let f = try await fixture()
        let moved = f.data.appendingPathExtension("moved")
        var replaced = false
        var overlay = f.overlay
        overlay.didPublish = { _ in
            if !replaced {
                replaced = true
                try FileManager.default.moveItem(at: f.data, to: moved)
                try FileManager.default.createDirectory(at: f.data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
        XCTAssertThrowsError(try f.stage(overlay))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(f.plan.jobRelativePath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.job.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.staged.path))
    }

    private func fixture(verifySignatures: Bool = false) async throws -> AccountlessOfflineOverlayTestFixture {
        let f = try await AccountlessOfflineOverlayTestFixture(verifySignatures: verifySignatures)
        addTeardownBlock { f.remove() }; return f
    }
    private func inode(_ path: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? UInt64)
    }
}
