import CryptoKit
import Darwin
import Foundation
import SandboxCore
@testable import SandboxRuntimeLume

struct LumeGuestTemplateTestFixture {
    static let guestNames = ["darkbloom-sandbox-guest", "darkbloom-sandbox-bootstrap.sh",
                             "io.darkbloom.sandbox.guest.plist", "install-sandbox-guest.sh"]
    let root: URL
    let release: URL
    let storage: URL
    let manifest: URL
    let receipt: URL
    let instanceID = UUID()
    let configuration: LumeGuestMaterialConfiguration
    init(accountless: Bool = false, signManifest: Bool = true) throws {
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
        try writeManifest(sign: signManifest)
        var ownership: [String: Any] = ["schemaVersion": 2, "installationID": instanceID.uuidString,
            "name": "base", "ownerKind": "base_template", "cpuCount": 4,
            "memoryBytes": 8 * 1_073_741_824, "diskBytes": 100 * 1_073_741_824,
            "sourceKind": "restore_image", "sourceReference": "/image.ipsw", "unattendedPreset": "tahoe"]
        if accountless {
            ownership["sourceKind"] = "apple_restore"
            ownership.removeValue(forKey: "unattendedPreset")
        }
        let ownershipURL = storage.appendingPathComponent("base/.darkbloom-ownership.json")
        try JSONSerialization.data(withJSONObject: ownership).write(to: ownershipURL)
        guard chmod(ownershipURL.path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
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
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
