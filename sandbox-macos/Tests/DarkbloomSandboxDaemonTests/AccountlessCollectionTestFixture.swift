import Darwin
import Foundation
import SandboxCore
import SandboxRuntimeLume
@testable import DarkbloomSandboxDaemon

struct AccountlessCollectionTestFixture {
    let overlay: AccountlessOfflineOverlayTestFixture
    let boot: AccountlessBootJournal.Record
    let directory: URL
    let resultData: Data
    let volumeUUID = UUID()
    var data: URL { overlay.data }

    init() async throws {
        let overlay = try await AccountlessOfflineOverlayTestFixture()
        self.overlay = overlay
        try overlay.stage()
        let candidate = overlay.installation.candidate
        let cleanupObject: [String: Any] = ["schemaVersion": 1, "imageFenceSHA256": String(repeating: "a", count: 64),
            "disk": try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate.disk))]
        let cleanup = try JSONDecoder().decode(LumeImageMaintenanceCleanup.self, from: JSONSerialization.data(withJSONObject: cleanupObject))
        do { try overlay.journal().recordDetached(cleanup) }
        let snapshot: AccountlessStagingSnapshot
        do { snapshot = try AccountlessStagingTransition(directory: overlay.journalDirectory).snapshot() }
        let permit = try AccountlessBootPermit(schemaVersion: 1, hostID: UUID(),
            hostUser: .init(recordName: "operator", uid: 501, primaryGID: 20, generatedUID: UUID().uuidString, homeDirectory: "/Users/operator"),
            hostIdentityFile: "/Library/Darkbloom/host.json", storage: "/Volumes/Sandbox/vms", runtime: "/Library/Darkbloom/lume",
            runtimeSHA256: String(repeating: "b", count: 64), reservationData: AccountlessJournalJSON.encode(candidate),
            stagedDisk: cleanup.disk, stagingSnapshotSHA256: BaseGuestRelease.digest(AccountlessJournalJSON.encode(snapshot)), maximumBootSeconds: 300)
        boot = try .init(schemaVersion: 1, permit: permit, permitSHA256: BaseGuestRelease.digest(permit.encoded()), staging: snapshot)
        directory = overlay.journalDirectory.deletingLastPathComponent().appendingPathComponent("collection")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let installation = SandboxAccountlessInstallationReceipt(source: candidate.source, rootJobID: candidate.bootstrapAttemptID,
            phase: .installationComplete, payload: candidate.payload, guestOperatingSystemVersion: "26.0.1", guestArchitecture: "arm64",
            virtualizedRootObserved: true, signedInstallerVerified: true, installerExitCode: 0, installedPayloadVerified: true,
            bootstrapAccountAbsent: true, tenantIdentityVerified: true)
        resultData = try AccountlessJournalJSON.encode(AccountlessInstallationResult(schemaVersion: 1, binding: overlay.plan.binding,
            stage: .complete, error: .none, shellExitCode: 0, guestOperatingSystemVersion: "26.0.1", guestArchitecture: "arm64",
            virtualizedRootObserved: true, installation: installation))
        for (name, target, mode) in [("darkbloom-sandbox-guest", "usr/local/libexec/darkbloom-sandbox-guest", 0o755),
                                     ("darkbloom-sandbox-bootstrap.sh", "usr/local/libexec/darkbloom-sandbox-bootstrap.sh", 0o755),
                                     ("io.darkbloom.sandbox.guest.plist", "Library/LaunchDaemons/io.darkbloom.sandbox.guest.plist", 0o644)] {
            let source = overlay.installation.release.directory.appendingPathComponent("guest/" + name)
            try Self.write(Data(contentsOf: source), to: overlay.data.appendingPathComponent(target), mode: mode)
        }
        try Self.write(Data("workspace\n".utf8), to: overlay.data.appendingPathComponent("private/etc/synthetic.d/io.darkbloom.sandbox"), mode: 0o644)
        for (name, data) in [("receipt.json", resultData), ("installer.log", Data()), ("helper.log", Data("identity verified\n".utf8))] {
            try Self.write(data, to: overlay.stageDirectory.appendingPathComponent("result/" + name), mode: 0o600, directoryMode: 0o700)
        }
        let journal = try AccountlessCollectionJournal(directory: directory, boot: boot)
        try journal.begin(initialDisk: cleanup.disk)
        _ = try journal.mountAttempts()
    }

    func journal() throws -> AccountlessCollectionJournal { try .init(directory: directory, boot: boot) }
    func collector(_ journal: AccountlessCollectionJournal, didRemove: @escaping (String) throws -> Void = { _ in }) -> AccountlessOfflineCollector {
        .init(journal: journal, verifier: .init(verifySignature: { _, _ in }), didRemove: didRemove)
    }
    func remove() { overlay.remove() }

    static func write(_ data: Data, to path: URL, mode: Int, directoryMode: Int = 0o755) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryMode])
        try data.write(to: path)
        guard chmod(path.path, mode_t(mode)) == 0 else { throw POSIXError(.EIO) }
    }
}
