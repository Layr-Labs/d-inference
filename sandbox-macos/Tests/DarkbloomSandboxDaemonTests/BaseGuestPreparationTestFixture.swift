import CryptoKit
import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import DarkbloomSandboxDaemon

struct BaseGuestPreparationTestFixture: Sendable {
    let root: URL
    let releaseDirectory: URL
    let storage: URL
    let installationID = UUID()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("db-bootstrap-test-\(UUID())")
        releaseDirectory = root.appendingPathComponent("release")
        storage = root.appendingPathComponent("vms")
        for path in [root, releaseDirectory, releaseDirectory.appendingPathComponent("guest"), storage, storage.appendingPathComponent("base")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var hashes: [String: String] = [:]
        for name in BaseGuestRelease.files {
            let data = Data(name.utf8)
            try data.write(to: releaseDirectory.appendingPathComponent("guest/" + name))
            hashes["guest/" + name] = BaseGuestRelease.digest(data)
        }
        let manifest: [String: Any] = ["schema_version": 1, "signing_mode": "developer_id", "files": hashes]
        try JSONSerialization.data(withJSONObject: manifest).write(to: releaseDirectory.appendingPathComponent("release-manifest.json"))
        try writeOwnership(id: installationID)
    }
    func release() throws -> BaseGuestRelease {
        try BaseGuestRelease(directory: releaseDirectory, verifySignature: { _, _ in })
    }
    func writeOwnership(id: UUID, sourceKind: String = "restore_image") throws {
        var owner: [String: Any] = ["schemaVersion": 2, "installationID": id.uuidString,
                                   "ownerKind": "base_template", "name": "base", "cpuCount": 4,
                                   "memoryBytes": 8 * 1_073_741_824, "diskBytes": 100 * 1_073_741_824,
                                   "sourceKind": sourceKind, "sourceReference": "/image.ipsw",
                                   "unattendedPreset": "tahoe"]
        if sourceKind == "apple_restore" { owner.removeValue(forKey: "unattendedPreset") }
        let path = storage.appendingPathComponent("base/.darkbloom-ownership.json")
        try JSONSerialization.data(withJSONObject: owner).write(to: path)
        _ = chmod(path.path, 0o600)
    }
    func accountlessTemplate(release: BaseGuestRelease, cleanupComplete: Bool = true) throws -> SandboxGuestTemplateReceipt {
        let source = try BaseGuestTemplateStore(directory: storage.appendingPathComponent("base")).source(name: "base")
        let payload = SandboxGuestPayloadIdentity(releaseManifestSHA256: release.manifestSHA256,
            guestSHA256: release.hashes["darkbloom-sandbox-guest"]!,
            bootstrapSHA256: release.hashes["darkbloom-sandbox-bootstrap.sh"]!,
            launchdSHA256: release.hashes["io.darkbloom.sandbox.guest.plist"]!,
            installerSHA256: release.hashes["install-sandbox-guest.sh"]!)
        let installation = SandboxAccountlessInstallationReceipt(source: source, rootJobID: UUID(), phase: .installationComplete,
            payload: payload, guestOperatingSystemVersion: "26.0", guestArchitecture: "arm64",
            virtualizedRootObserved: true, signedInstallerVerified: true, installerExitCode: 0,
            installedPayloadVerified: true, bootstrapAccountAbsent: true, tenantIdentityVerified: true)
        let cloneID = UUID()
        let qualification = SandboxGuestNativeQualification(qualificationID: UUID(), source: source, payload: payload,
            cloneName: "qualification", cloneInstallationID: cloneID,
            checks: .init(authenticatedGuest: true, tenantIdentity: true, commandExecution: true,
                workspaceRoundTrip: true, protectedPathDenied: true, controlDiskDenied: true, restart: true),
            cleanup: .init(cloneInstallationID: cloneID, materialsInstanceID: cloneID, cloneRemoved: cleanupComplete,
                materialsRemoved: cleanupComplete, capacityReleased: cleanupComplete,
                sourceStoppedReverified: true, sourceUnchangedReverified: true))
        return .init(accountless: .init(installation: installation, qualification: qualification))
    }
    func receipt(release: BaseGuestRelease) -> BaseGuestInstallationReceipt {
        BaseGuestInstallationReceipt(schemaVersion: 1,
            guestSHA256: release.hashes["darkbloom-sandbox-guest"]!,
            bootstrapSHA256: release.hashes["darkbloom-sandbox-bootstrap.sh"]!,
            launchdSHA256: release.hashes["io.darkbloom.sandbox.guest.plist"]!,
            installerSHA256: release.hashes["install-sandbox-guest.sh"]!,
            guestOperatingSystemVersion: "26.0", guestArchitecture: "arm64", bootstrapRetired: true)
    }
    func specification() throws -> SandboxVirtualMachineSpecification {
        try SandboxVirtualMachineSpecification(name: "base", resources: SandboxResourceSpecification(
            cpuCount: 4, memoryBytes: 8 * 1_073_741_824, workspaceBytes: 25 * 1_073_741_824, commandTimeoutSeconds: 900),
            imageSource: .restoreImage(url: URL(fileURLWithPath: "/image.ipsw"), unattendedPreset: "tahoe"),
            diskBytes: 100 * 1_073_741_824)
    }
}
