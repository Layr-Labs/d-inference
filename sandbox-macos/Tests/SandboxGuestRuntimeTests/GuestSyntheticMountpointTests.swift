import Darwin
import Foundation
import SandboxGuestProtocol
@testable import SandboxGuestRuntime
import XCTest

final class GuestSyntheticMountpointTests: XCTestCase {
    func testStagesOneColumnMountpointWithoutEditingExistingManifests() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let existing = Data("# unrelated root entry\npackages\tSystem/Volumes/Data/packages\n".utf8)
        try existing.write(to: fixture.root.appendingPathComponent("synthetic.conf"))
        try GuestSyntheticMountpoint.provision(in: fixture.root, ownerUID: geteuid())
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("synthetic.conf")), existing)
        let generated = fixture.root.appendingPathComponent("synthetic.d/io.darkbloom.sandbox")
        XCTAssertEqual(try String(contentsOf: generated, encoding: .utf8), "workspace\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("workspace").path))
        var before = stat(), after = stat()
        XCTAssertEqual(lstat(generated.path, &before), 0)
        try GuestSyntheticMountpoint.provision(in: fixture.root, ownerUID: geteuid())
        XCTAssertEqual(lstat(generated.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
    }

    func testExistingWorkspaceSymlinkAndDuplicateDefinitionsFailClosed() throws {
        for text in ["workspace\tprivate/var/workspace\n", "workspace\nworkspace\n"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let original = Data(text.utf8)
            try original.write(to: fixture.root.appendingPathComponent("synthetic.conf"))
            XCTAssertThrowsError(try GuestSyntheticMountpoint.provision(in: fixture.root, ownerUID: geteuid()))
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("synthetic.conf")), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("synthetic.d/io.darkbloom.sandbox").path))
        }
    }

    func testSymlinkedConfigurationDirectoryCannotReceiveWrites() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("synthetic.d"),
                                                   withDestinationURL: outside)
        XCTAssertThrowsError(try GuestSyntheticMountpoint.provision(in: fixture.root, ownerUID: geteuid()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    private struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-mountpoint-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
