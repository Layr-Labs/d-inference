import CryptoKit
import Darwin
import Foundation
import SandboxCore
@testable import SandboxRuntimeLume
import XCTest

final class LumeGuestTemplateTests: XCTestCase {
    func testHostOnlySignedManifestUpgradeReusesGuestWithoutChangingProvenance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.requireReady()
        let originalReceipt = try Data(contentsOf: fixture.receipt)
        let originalManifest = try Data(contentsOf: fixture.manifest)
        try fixture.writeManifest(hostVersion: "new-host-and-lume")
        XCTAssertNotEqual(try Data(contentsOf: fixture.manifest), originalManifest)
        try fixture.requireReady()
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), originalReceipt)
    }

    func testEachChangedGuestArtifactInSignedManifestRequiresNewQualification() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in Fixture.guestNames {
            try fixture.writeManifest(changedGuest: name)
            XCTAssertThrowsError(try fixture.requireReady(), name)
        }
        try fixture.writeManifest()
        XCTAssertNoThrow(try fixture.requireReady())
    }

    func testReplacedUnsignedAndSymlinkedManifestCannotQualifyTemplate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeManifest(hostVersion: "unsigned", sign: false)
        XCTAssertThrowsError(try fixture.requireReady())
        try fixture.writeManifest()
        let moved = fixture.release.appendingPathComponent("original-manifest.json")
        try FileManager.default.moveItem(at: fixture.manifest, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.manifest, withDestinationURL: moved)
        XCTAssertThrowsError(try fixture.requireReady())
    }

    func testGuestIdentityStoppedProofAndRetirementRemainRequiredAcrossHostUpgrade() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.receipt)
        try fixture.writeManifest(hostVersion: "host-only-upgrade")
        for (key, value) in [("installationID", UUID().uuidString as Any), ("name", "other-base"),
                             ("stoppedVerified", false), ("bootstrapRetired", false),
                             ("guestArchitecture", "x86_64"), ("schemaVersion", 2),
                             ("releaseManifestSHA256", "unqualified")] {
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            record[key] = value
            try JSONSerialization.data(withJSONObject: record).write(to: fixture.receipt)
            XCTAssertThrowsError(try fixture.requireReady(), key)
        }
        try original.write(to: fixture.receipt)
        XCTAssertNoThrow(try fixture.requireReady())
    }

    private struct Fixture {
        static let guestNames = ["darkbloom-sandbox-guest", "darkbloom-sandbox-bootstrap.sh",
                                 "io.darkbloom.sandbox.guest.plist", "install-sandbox-guest.sh"]
        let root: URL
        let release: URL
        let storage: URL
        let manifest: URL
        let receipt: URL
        let instanceID = UUID()
        let configuration: LumeGuestMaterialConfiguration
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("template-upgrade-\(UUID())")
            release = root.appendingPathComponent("release")
            storage = root.appendingPathComponent("storage")
            manifest = release.appendingPathComponent("release-manifest.json")
            receipt = storage.appendingPathComponent("base/" + SandboxGuestTemplateReceipt.fileName)
            for path in [root, release, release.appendingPathComponent("tools"),
                         storage, storage.appendingPathComponent("base")] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            configuration = try LumeGuestMaterialConfiguration(releaseDirectory: release, developmentAdHoc: true)
            for name in ["prepare-sandbox-instance.py", "materialize-sandbox-instance.py", "sandbox_release_support.py"] {
                try Data(name.utf8).write(to: release.appendingPathComponent("tools/" + name))
            }
            try writeManifest()
            let value = SandboxGuestTemplateReceipt(schemaVersion: 1, name: "base", installationID: instanceID,
                releaseManifestSHA256: Self.digest(try Data(contentsOf: manifest)),
                guestSHA256: Self.digest(Data(Self.guestNames[0].utf8)),
                bootstrapSHA256: Self.digest(Data(Self.guestNames[1].utf8)),
                launchdSHA256: Self.digest(Data(Self.guestNames[2].utf8)),
                installerSHA256: Self.digest(Data(Self.guestNames[3].utf8)),
                guestOperatingSystemVersion: "26.0", guestArchitecture: "arm64",
                bootstrapRetired: true, stoppedVerified: true)
            try JSONEncoder().encode(value).write(to: receipt)
            guard chmod(receipt.path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        func requireReady() throws {
            try LumeGuestTemplate.requireReady(name: "base", installationID: instanceID,
                storage: storage, release: configuration)
        }
        func writeManifest(hostVersion: String = "original", changedGuest: String? = nil, sign: Bool = true) throws {
            var files: [String: String] = [:]
            for name in ["prepare-sandbox-instance.py", "materialize-sandbox-instance.py", "sandbox_release_support.py"] {
                files["tools/" + name] = Self.digest(Data(name.utf8))
            }
            for name in Self.guestNames {
                files["guest/" + name] = Self.digest(Data((name == changedGuest ? "changed" : name).utf8))
            }
            files["DarkbloomSandbox.app/Contents/MacOS/darkbloom-sandboxd"] = Self.digest(Data(hostVersion.utf8))
            let value: [String: Any] = ["schema_version": 1, "version": hostVersion, "files": files]
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: manifest, options: .atomic)
            if sign {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                process.arguments = ["--force", "--sign", "-", "--identifier", "io.darkbloom.sandbox.release-manifest", manifest.path]
                process.standardOutput = Pipe(); process.standardError = Pipe()
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        private static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
