import Foundation
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessPayloadPathTests: XCTestCase {
    func testPrivateTmpPayloadPathsCanBePublishedAndInventoried() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("payload-alias-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try AccountlessInstallationPayloadFiles(destination: root.appendingPathComponent("output"))
        let directory = try output.createDirectory("data-overlay/Library")
        try output.write(Data("payload".utf8), to: directory.appendingPathComponent("payload.txt"), mode: 0o400)
        XCTAssertEqual(try output.inventory().keys.sorted(), ["Library/payload.txt"])
        try output.synchronize()
    }

    func testRelativeTraversalCannotEscapeAnOwnedPayloadRoot() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("payload-traversal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("output")
        let output = try AccountlessInstallationPayloadFiles(destination: directory)
        let escaped = URL(fileURLWithPath: directory.path + "/../escaped")
        XCTAssertThrowsError(try output.write(Data("must not write".utf8), to: escaped, mode: 0o400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path))
    }
}
