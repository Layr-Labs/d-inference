import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import SandboxGuestRuntime
import SandboxGuestProtocol

final class GuestWorkspaceTests: XCTestCase {
    private func fixture() throws -> (URL, GuestWorkspace) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guest-workspace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try GuestWorkspace(path: root.path, tenantUID: getuid(), tenantGID: getgid(), requireSeparateVolume: false))
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    func testChunkedUploadIsInvisibleUntilVerifiedCommitAndDoesNotOverwrite() throws {
        let (root, workspace) = try fixture()
        try workspace.makeDirectory("sources")
        try workspace.makeDirectory("sources")
        let bytes = Data("hello world".utf8), id = UUID()
        try workspace.begin(id: id, path: "sources/build.txt", size: UInt64(bytes.count), sha256: digest(bytes))
        try workspace.append(id: id, offset: 0, data: bytes.prefix(5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sources/build.txt").path))
        XCTAssertThrowsError(try workspace.append(id: id, offset: 0, data: bytes.suffix(6)))
        try workspace.append(id: id, offset: 5, data: bytes.suffix(6))
        try workspace.commit(id: id)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sources/build.txt")), bytes)
        let first = try workspace.download(path: "sources/build.txt", offset: 0, maximumBytes: 6)
        let read = try workspace.download(path: "sources/build.txt", offset: 6, maximumBytes: 10, version: first.version)
        XCTAssertEqual(read.data, Data("world".utf8)); XCTAssertEqual(read.size, 11)
        let again = UUID()
        try workspace.begin(id: again, path: "sources/build.txt", size: UInt64(bytes.count), sha256: digest(bytes))
        try workspace.append(id: again, offset: 0, data: bytes)
        XCTAssertThrowsError(try workspace.commit(id: again))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sources/build.txt")), bytes)
    }

    func testWrongHashAbortsPublication() throws {
        let (root, workspace) = try fixture(), id = UUID()
        try workspace.begin(id: id, path: "x", size: 1, sha256: String(repeating: "0", count: 64))
        try workspace.append(id: id, offset: 0, data: Data([1]))
        XCTAssertThrowsError(try workspace.commit(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("x").path))
        XCTAssertThrowsError(try workspace.commit(id: id))
    }

    func testDownloadRejectsMixedRevisionsAndMissingVersionOnContinuation() throws {
        let (root, workspace) = try fixture()
        let file = root.appendingPathComponent("artifact")
        try Data("abcdef".utf8).write(to: file)
        let first = try workspace.download(path: "artifact", offset: 0, maximumBytes: 3)
        XCTAssertEqual(first.data, Data("abc".utf8))
        let version = try XCTUnwrap(first.version)
        XCTAssertEqual(version.count, 64)
        XCTAssertThrowsError(try workspace.download(path: "artifact", offset: 3, maximumBytes: 3)) {
            XCTAssertEqual($0 as? GuestProtocolError, .fileChanged)
        }
        let next = try workspace.download(path: "artifact", offset: 3, maximumBytes: 3, version: version)
        XCTAssertEqual(next.data, Data("def".utf8))
        try Data("ghijkl".utf8).write(to: file)
        XCTAssertThrowsError(try workspace.download(path: "artifact", offset: 3, maximumBytes: 3, version: version)) {
            XCTAssertEqual($0 as? GuestProtocolError, .fileChanged)
        }
        let fresh = try workspace.download(path: "artifact", offset: 0, maximumBytes: 3)
        XCTAssertNotEqual(fresh.version, version)
        XCTAssertEqual(fresh.data, Data("ghi".utf8))
    }

    func testTraversalSymlinkHardLinkAndSpecialFileAreRejected() throws {
        let (root, workspace) = try fixture()
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try workspace.begin(id: UUID(), path: "outside/file", size: 0, sha256: digest(Data())))
        XCTAssertThrowsError(try workspace.download(path: "../outside", offset: 0, maximumBytes: 100))
        let file = root.appendingPathComponent("file")
        try Data("data".utf8).write(to: file)
        XCTAssertEqual(link(file.path, root.appendingPathComponent("hardlink").path), 0)
        XCTAssertThrowsError(try workspace.download(path: "hardlink", offset: 0, maximumBytes: 100))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try workspace.download(path: "pipe", offset: 0, maximumBytes: 100))
    }

    func testChunkLimitsAndIncompleteCommit() throws {
        let (_, workspace) = try fixture(), id = UUID()
        try workspace.begin(id: id, path: "big", size: 1024, sha256: digest(Data()))
        XCTAssertThrowsError(try workspace.append(id: id, offset: 0, data: Data(repeating: 0, count: GuestProtocolLimits.maximumChunkBytes + 1)))
        XCTAssertThrowsError(try workspace.commit(id: id))
        XCTAssertEqual(try workspace.status(id: id).offset, 0)
    }

    func testUploadBeginChunkCommitRetriesPreserveIdentityAndNeverPublishTwice() throws {
        let (root, workspace) = try fixture(), id = UUID()
        let data = Data("abcdef".utf8)
        try workspace.begin(id: id, path: "file", size: 6, sha256: digest(data))
        try workspace.append(id: id, offset: 0, data: data.prefix(3))
        try workspace.begin(id: id, path: "file", size: 6, sha256: digest(data))
        XCTAssertEqual(try workspace.status(id: id).offset, 3)
        try workspace.append(id: id, offset: 0, data: data.prefix(3))
        XCTAssertEqual(try workspace.status(id: id).offset, 3)
        XCTAssertThrowsError(try workspace.append(id: id, offset: 0, data: Data("xxx".utf8)))
        XCTAssertThrowsError(try workspace.begin(id: id, path: "different", size: 6, sha256: digest(data)))
        try workspace.append(id: id, offset: 3, data: data.suffix(3))
        try workspace.commit(id: id)
        XCTAssertTrue(try workspace.status(id: id).committed)
        try FileManager.default.removeItem(at: root.appendingPathComponent("file"))
        try workspace.commit(id: id)
        try workspace.begin(id: id, path: "file", size: 6, sha256: digest(data))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("file").path))
        XCTAssertThrowsError(try workspace.begin(id: id, path: "different", size: 6, sha256: digest(data)))
    }

    func testAbortedTransferRetainsItsIdentityAndStatus() throws {
        let (_, workspace) = try fixture(), id = UUID()
        try workspace.begin(id: id, path: "file", size: 0, sha256: digest(Data()))
        try workspace.abort(id: id)
        try workspace.abort(id: id)
        XCTAssertEqual(try workspace.status(id: id).state, .aborted)
        try workspace.begin(id: id, path: "file", size: 0, sha256: digest(Data()))
        XCTAssertEqual(try workspace.status(id: id).state, .aborted)
        XCTAssertThrowsError(try workspace.begin(id: id, path: "other", size: 0, sha256: digest(Data())))
        XCTAssertThrowsError(try workspace.commit(id: id))
    }

    func testProductionWorkspaceAndConfigurationFailClosedWithoutRootOrDistinctVolume() throws {
        let (root, _) = try fixture()
        XCTAssertThrowsError(try GuestWorkspace(path: root.path, tenantUID: 2001, tenantGID: 2001))
        XCTAssertThrowsError(try GuestConfiguration.loadProduction(from: root.appendingPathComponent("instance.json").path))
    }
}
