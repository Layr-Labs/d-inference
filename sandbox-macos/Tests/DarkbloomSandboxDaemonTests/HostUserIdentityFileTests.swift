import Darwin
import Foundation
@testable import DarkbloomSandboxDaemon
import XCTest

final class HostUserIdentityFileTests: XCTestCase {
    func testStableDescriptorReadAndExactFileModes() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        XCTAssertEqual(try fixture.read(), Data("public binding".utf8))
        for mode: mode_t in [0o644, 0o4440, 0o440, 0o400] {
            XCTAssertEqual(chmod(fixture.file.path, mode), 0)
            XCTAssertThrowsError(try fixture.read())
        }
    }

    func testSymlinkHardlinkNonregularAndOversizeRefused() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.file)
        XCTAssertThrowsError(try fixture.read(name: "alias"))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.linkItem(at: fixture.file, to: alias)
        XCTAssertThrowsError(try fixture.read())
        try FileManager.default.removeItem(at: alias)
        let fifo = fixture.root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o444), 0)
        XCTAssertThrowsError(try fixture.read(name: "fifo"))
        XCTAssertEqual(chmod(fixture.file.path, 0o644), 0)
        try Data(repeating: 1, count: HostUserIdentityFile.maximumBytes + 1).write(to: fixture.file)
        XCTAssertEqual(chmod(fixture.file.path, 0o444), 0)
        XCTAssertThrowsError(try fixture.read())
    }

    func testParentLinksWritableParentAndACLRefused() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.directory)
        XCTAssertThrowsError(try fixture.read(directory: "alias"))
        XCTAssertEqual(chmod(fixture.directory.path, 0o775), 0)
        XCTAssertThrowsError(try fixture.read())
        XCTAssertEqual(chmod(fixture.directory.path, 0o755), 0)
        guard let acl = acl_from_text("!#acl 1\nuser:FFFFEEEE-DDDD-CCCC-BBBB-AAAA000001F5:operator:501:allow:read\n") else {
            return XCTFail("fixture ACL text rejected")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_set_file(fixture.file.path, ACL_TYPE_EXTENDED, acl), 0)
        XCTAssertThrowsError(try fixture.read())
    }

    func testLeafAndAncestorReplacementDuringReadFailClosed() throws {
        for replaceParent in [false, true] {
            let fixture = try Fixture(); defer { fixture.remove() }
            XCTAssertThrowsError(try fixture.read(afterRead: {
                if replaceParent {
                    try FileManager.default.moveItem(at: fixture.directory, to: fixture.root.appendingPathComponent("old"))
                    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
                                                           attributes: [.posixPermissions: 0o755])
                } else { try FileManager.default.removeItem(at: fixture.file) }
                try fixture.write()
            }))
        }
    }

    private struct Fixture {
        let root: URL
        var directory: URL { root.appendingPathComponent("binding") }
        var file: URL { directory.appendingPathComponent("host-user.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("host-identity-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o755])
            try write()
        }

        func write() throws {
            try Data("public binding".utf8).write(to: file)
            guard chmod(file.path, 0o444) == 0 else { throw HostUserIdentityError.insecureFile }
        }

        func read(directory name: String = "binding", name fileName: String = "host-user.json",
                  afterRead: () throws -> Void = {}) throws -> Data {
            let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw HostUserIdentityError.insecureFile }
            defer { close(descriptor) }
            return try HostUserIdentityFile.read(components: fileName == "fifo" || fileName == "alias"
                ? [fileName] : [name, fileName], root: descriptor, ownerUID: geteuid(), afterRead: afterRead)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
