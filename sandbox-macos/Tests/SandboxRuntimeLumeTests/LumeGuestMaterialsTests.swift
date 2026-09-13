import CryptoKit
import Darwin
import Foundation
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeGuestMaterialsTests: XCTestCase {
    func testLoadsScopedCredentialAndMutableWorkspaceOnRestart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.load()
        XCTAssertEqual(first.instanceID, fixture.instanceID)
        XCTAssertEqual(first.credential, fixture.credential)
        let writer = try FileHandle(forWritingTo: fixture.workspace)
        try writer.write(contentsOf: Data("tenant output".utf8))
        try writer.close()
        let restarted = try fixture.load()
        XCTAssertEqual(restarted.workspaceBytes, 25 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(restarted.controlDisk, fixture.control)
    }

    func testRejectsDifferentInstallationIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.configuration.load(
            in: fixture.root, instanceID: UUID(), workspaceBytes: Fixture.workspaceBytes
        ))
    }

    func testRejectsChangedControlBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.control.path)
        let writer = try FileHandle(forWritingTo: fixture.control)
        try writer.write(contentsOf: Data([1]))
        try writer.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.control.path)
        XCTAssertThrowsError(try fixture.load())
    }

    func testRejectsWorkspaceResizeAndSecretPermissionSharing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = try FileHandle(forWritingTo: fixture.workspace)
        try writer.truncate(atOffset: Fixture.workspaceBytes - 512)
        try writer.close()
        XCTAssertThrowsError(try fixture.load())
        let secret = fixture.materials.appendingPathComponent("broker.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path)
        XCTAssertThrowsError(try fixture.load())
    }

    func testRejectsSymlinkedCredentialAndOutOfScopePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secret = fixture.materials.appendingPathComponent("broker.json")
        let moved = fixture.materials.appendingPathComponent("original-broker.json")
        try FileManager.default.moveItem(at: secret, to: moved)
        try FileManager.default.createSymbolicLink(at: secret, withDestinationURL: moved)
        XCTAssertThrowsError(try fixture.load())
        try FileManager.default.removeItem(at: secret)
        try FileManager.default.moveItem(at: moved, to: secret)
        let manifest = fixture.materials.appendingPathComponent("material-manifest.json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        record["workspacePath"] = fixture.root.appendingPathComponent("other/workspace.cdr").path
        try JSONSerialization.data(withJSONObject: record).write(to: manifest)
        XCTAssertThrowsError(try fixture.load())
    }

    func testSignedReleaseRejectsChangedOrAdditionalPythonImports() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        try fixture.configuration.validateRelease()
        let unexpected = fixture.tools.appendingPathComponent("json.py")
        try Data("malicious shadow".utf8).write(to: unexpected)
        XCTAssertThrowsError(try fixture.configuration.validateRelease())
        try FileManager.default.removeItem(at: unexpected)
        try Data("changed".utf8).write(to: fixture.tools.appendingPathComponent("sandbox_release_support.py"))
        XCTAssertThrowsError(try fixture.configuration.validateRelease())
    }

    func testUnsignedAndBrokerOwnedProductionReleaseAreRejected() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        let production = try LumeGuestMaterialConfiguration(releaseDirectory: fixture.root)
        XCTAssertThrowsError(try production.validateRelease())
        let manifest = fixture.root.appendingPathComponent("release-manifest.json")
        try FileManager.default.removeItem(at: manifest)
        try Data("{}".utf8).write(to: manifest)
        XCTAssertThrowsError(try fixture.configuration.validateRelease())
    }

    private struct Fixture {
        static let workspaceBytes: UInt64 = 25 * 1_024 * 1_024 * 1_024
        static let controlBytes: UInt64 = 128 * 1_024 * 1_024
        static let controlDigest: String = {
            var hasher = SHA256()
            let zeros = Data(count: 1_024 * 1_024)
            for _ in 0..<128 { hasher.update(data: zeros) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }()
        let root: URL
        let materials: URL
        let control: URL
        let workspace: URL
        let instanceID = UUID()
        let credential = Data(repeating: 91, count: 32)
        let configuration: LumeGuestMaterialConfiguration

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("guest-material-tests-\(UUID().uuidString)")
            materials = root.appendingPathComponent(".darkbloom-guest")
            control = materials.appendingPathComponent("control.cdr")
            workspace = materials.appendingPathComponent("workspace.cdr")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            configuration = try LumeGuestMaterialConfiguration(releaseDirectory: root, developmentAdHoc: true)
            for (path, bytes, mode) in [(control, Self.controlBytes, 0o400), (workspace, Self.workspaceBytes, 0o600)] {
                FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let file = try FileHandle(forWritingTo: path)
                try file.truncate(atOffset: bytes)
                try file.close()
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path.path)
            }
            let manifest: [String: Any] = [
                "schema_version": 1, "instanceID": instanceID.uuidString,
                "controlPath": control.path, "controlBytes": Self.controlBytes,
                "workspacePath": workspace.path, "workspaceDiskBytes": Self.workspaceBytes,
                "images": [
                    ["role": "control", "path": control.path, "bytes": Self.controlBytes,
                     "sha256": Self.controlDigest, "read_only": true],
                    ["role": "workspace", "path": workspace.path, "bytes": Self.workspaceBytes,
                     "sha256": String(repeating: "0", count: 64), "read_only": false],
                ],
            ]
            try Self.write(manifest, to: materials.appendingPathComponent("material-manifest.json"))
            try Self.write(["version": 1, "instanceID": instanceID.uuidString,
                            "credential": credential.base64EncodedString()],
                           to: materials.appendingPathComponent("broker.json"))
        }

        func load() throws -> LumeGuestMaterials {
            try configuration.load(in: root, instanceID: instanceID, workspaceBytes: Self.workspaceBytes)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        private static func write(_ value: [String: Any], to path: URL) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }

    private struct ReleaseFixture {
        let root: URL
        let tools: URL
        let configuration: LumeGuestMaterialConfiguration

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("guest-release-tests-\(UUID().uuidString)")
            tools = root.appendingPathComponent("tools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            configuration = try LumeGuestMaterialConfiguration(releaseDirectory: root, developmentAdHoc: true)
            var files: [String: String] = [:]
            for name in ["prepare-sandbox-instance.py", "materialize-sandbox-instance.py", "sandbox_release_support.py"] {
                let data = Data("fixture".utf8)
                try data.write(to: tools.appendingPathComponent(name))
                files["tools/" + name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let manifest = root.appendingPathComponent("release-manifest.json")
            try JSONSerialization.data(withJSONObject: ["schema_version": 1, "files": files]).write(to: manifest)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--force", "--sign", "-", "--identifier", "io.darkbloom.sandbox.release-manifest", manifest.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
