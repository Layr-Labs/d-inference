import Darwin
import Foundation
import SandboxRuntimeLume
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessMountAttemptTests: XCTestCase {
    func testCompletionCannotBeCopiedToADifferentAttemptWithTheSameImageAndPlan() throws {
        let f = try fixture(), attempts = try f.attempts()
        let first = try attempts.create()
        try first.begin(f.intent)
        try first.recordDetached(image: f.disk)
        let second = try attempts.create()
        try second.begin(.init(schemaVersion: 1, attemptName: "0002", maintenanceSHA256: f.digest,
            imagePath: f.intent.imagePath, image: f.disk, writable: true, baseline: []))
        let destination = second.directory.appendingPathComponent("completed.json")
        try Data(contentsOf: first.directory.appendingPathComponent("completed.json")).write(to: destination)
        XCTAssertEqual(chmod(destination.path, 0o600), 0)
        XCTAssertThrowsError(try second.completion())
    }

    func testIntentPrecedesIOAndCompletionClosesTheAttemptAcrossReopen() throws {
        let f = try fixture(), attempts = try f.attempts()
        let attempt = try attempts.create()
        XCTAssertNil(try attempt.intent())
        XCTAssertThrowsError(try attempts.create())
        try attempt.begin(f.intent)
        XCTAssertEqual(try attempt.intent(), f.intent)
        try attempt.recordDetached(image: f.disk)
        let second = try attempts.create()
        XCTAssertTrue(second.directory.path.hasSuffix("/0002"))
        let reopened = try AccountlessMountAttempt(directory: attempt.directory, maintenanceSHA256: f.digest)
        XCTAssertNotNil(try reopened.completion())
        XCTAssertThrowsError(try reopened.begin(f.intent))
    }

    func testInterruptedDirectoryCreationCanCloseWithoutAuthorizingAnAttach() throws {
        let f = try fixture(), attempt = try f.attempts().create()
        try attempt.requireEmptyMountpoint(create: true)
        XCTAssertNil(try attempt.intent())
        try attempt.recordDetached(image: f.disk)
        XCTAssertNil(try attempt.completion()?.intentSHA256)
        XCTAssertThrowsError(try attempt.begin(f.intent))
    }

    func testDifferentIntentCannotReplacePublishedBinding() throws {
        let f = try fixture(), attempt = try f.attempts().create()
        try attempt.begin(f.intent)
        let path = attempt.directory.appendingPathComponent("intent.json"), before = try Data(contentsOf: path)
        XCTAssertThrowsError(try attempt.begin(f.intent))
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertThrowsError(try AccountlessMountAttempt(directory: attempt.directory, maintenanceSHA256: String(repeating: "b", count: 64)).intent())
    }

    func testUnsafeRecordAndReplacedDirectoryCannotBeRepaired() throws {
        for kind in ["fifo", "shared", "link", "directory"] {
            let f = try fixture(), attempt = try f.attempts().create()
            let path = attempt.directory.appendingPathComponent("intent.json")
            if kind == "fifo" { XCTAssertEqual(mkfifo(path.path, 0o600), 0) }
            else {
                try attempt.begin(f.intent)
                if kind == "shared" { XCTAssertEqual(chmod(path.path, 0o644), 0) }
                else if kind == "link" { try FileManager.default.linkItem(at: path, to: f.root.appendingPathComponent("alias")) }
                else {
                    try FileManager.default.moveItem(at: attempt.directory, to: f.root.appendingPathComponent("old"))
                    try FileManager.default.createDirectory(at: attempt.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
            }
            XCTAssertThrowsError(try attempt.intent(), kind)
            XCTAssertThrowsError(try attempt.recordDetached(image: f.disk), kind)
        }
    }

    func testOnlyEmptyPrivatePublicationPrefixMayBeScavenged() throws {
        for contents in [Data(), Data("preserve".utf8)] {
            let f = try fixture(), attempt = try f.attempts().create()
            let path = attempt.directory.appendingPathComponent(".mount-record-\(UUID().uuidString.lowercased()).partial")
            try contents.write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0)
            if contents.isEmpty {
                try attempt.validate()
                XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
            } else {
                XCTAssertThrowsError(try attempt.validate())
                XCTAssertEqual(try Data(contentsOf: path), contents)
            }
        }
    }

    func testNonemptyOrRedirectedMountpointCannotRecordCleanup() throws {
        let f = try fixture(), attempt = try f.attempts().create()
        try attempt.begin(f.intent)
        try Data("preserve".utf8).write(to: attempt.mountpoint.appendingPathComponent("unexpected"))
        XCTAssertThrowsError(try attempt.recordDetached(image: f.disk))
        XCTAssertNil(try attempt.completion())
    }

    private func fixture() throws -> MountFixture {
        let f = try MountFixture(); addTeardownBlock { try? FileManager.default.removeItem(at: f.root) }; return f
    }
}

private struct MountFixture {
    let root: URL
    let digest = String(repeating: "a", count: 64)
    let disk: LumeCandidateDiskIdentity
    var intent: AccountlessMountAttempt.Intent {
        .init(schemaVersion: 1, attemptName: "0001", maintenanceSHA256: digest, imagePath: root.appendingPathComponent("image").path,
            image: disk, writable: true, baseline: [])
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("mount-journal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("attempts"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let image = root.appendingPathComponent("image")
        try Data("image".utf8).write(to: image)
        var info = stat(); guard lstat(image.path, &info) == 0 else { throw POSIXError(.EIO) }
        disk = .init(info)
    }
    func attempts() throws -> AccountlessMountAttempts { try .init(directory: root.appendingPathComponent("attempts"), maintenanceSHA256: digest) }
}
