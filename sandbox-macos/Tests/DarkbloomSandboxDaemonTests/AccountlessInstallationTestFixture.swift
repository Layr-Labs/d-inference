import Foundation
import SandboxCore
import SandboxRuntime
@testable import DarkbloomSandboxDaemon

struct AccountlessInstallationTestFixture: Sendable {
    let base: BaseGuestPreparationTestFixture
    let candidate: AccountlessBaseCandidateRecord
    let release: BaseGuestRelease
    var destination: URL { base.root.resolvingSymlinksInPath().appendingPathComponent("accountless-payload") }

    init() throws {
        base = try BaseGuestPreparationTestFixture()
        try base.writeOwnership(id: base.installationID, sourceKind: "apple_restore")
        release = try base.release()
        let source = try BaseGuestTemplateStore(directory: base.storage.appendingPathComponent("base")).source(name: "base")
        candidate = .init(schemaVersion: 1, phase: .awaitingRootInstallation,
            candidateID: UUID(), bootstrapAttemptID: UUID(), source: source,
            payload: .init(releaseManifestSHA256: release.manifestSHA256,
                guestSHA256: release.hashes["darkbloom-sandbox-guest"]!,
                bootstrapSHA256: release.hashes["darkbloom-sandbox-bootstrap.sh"]!,
                launchdSHA256: release.hashes["io.darkbloom.sandbox.guest.plist"]!,
                installerSHA256: release.hashes["install-sandbox-guest.sh"]!),
            resources: try .macOSSmall(), disk: .init(device: 1, inode: 2,
                size: 100 * SandboxResourcePolicy.gibibyte, modifiedSeconds: 1, modifiedNanoseconds: 0,
                changedSeconds: 1, changedNanoseconds: 0), installed: false, qualified: false)
    }

    var producer: AccountlessInstallationPayload {
        .init(loadRelease: { try BaseGuestRelease(directory: $0, verifySignature: { _, _ in }) })
    }
    func remove() { try? FileManager.default.removeItem(at: base.root) }
}
