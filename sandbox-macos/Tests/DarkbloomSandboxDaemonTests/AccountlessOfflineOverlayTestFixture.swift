import Darwin
import Foundation
import SandboxRuntime
import Security
@testable import DarkbloomSandboxDaemon

struct AccountlessOfflineOverlayTestFixture: Sendable {
    let installation: AccountlessInstallationTestFixture
    let plan: AccountlessInstallationPayloadPlan
    let data: URL
    let journalDirectory: URL
    let verifySignatures: Bool

    init(verifySignatures: Bool = false) async throws {
        let installation = try AccountlessInstallationTestFixture()
        self.installation = installation; self.verifySignatures = verifySignatures
        if verifySignatures {
            for (relative, identifier) in [("release-manifest.json", "io.darkbloom.sandbox.release-manifest"),
                                           ("guest/darkbloom-sandbox-guest", "io.darkbloom.sandbox.guest")] {
                let result = try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: ["--force", "--sign", "-", "--identifier", identifier,
                                installation.release.directory.appendingPathComponent(relative).path], timeoutSeconds: 10)
                guard result.exitCode == 0 else { throw BaseGuestPreparationError.invalidRelease }
            }
        }
        plan = try await AccountlessInstallationPayload(loadRelease: Self.loader(verifySignatures)).prepare(
            candidate: installation.candidate, release: installation.release, destination: installation.destination)
        let root = installation.base.root.resolvingSymlinksInPath()
        data = root.appendingPathComponent("Data")
        journalDirectory = root.appendingPathComponent("root-journal")
        for path in [data, data.appendingPathComponent("Library"), data.appendingPathComponent("Library/Application Support"),
                     data.appendingPathComponent("Library/LaunchDaemons"), journalDirectory] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try Data("unrelated guest file".utf8).write(to: data.appendingPathComponent("Library/preserve.txt"))
    }

    var job: URL { data.appendingPathComponent(plan.jobRelativePath) }
    var staged: URL { journalDirectory.appendingPathComponent("staged.json") }
    var stageDirectory: URL { data.appendingPathComponent(plan.stageRelativePath) }
    var overlay: AccountlessOfflineOverlay { .init(loadRelease: Self.loader(verifySignatures)) }
    func journal() throws -> AccountlessInstallationStagingJournal {
        try .init(directory: journalDirectory, candidate: installation.candidate, plan: plan)
    }
    func stage(_ overlay: AccountlessOfflineOverlay? = nil) throws {
        try (overlay ?? self.overlay).stage(dataDirectory: data, payloadDirectory: installation.destination, journal: journal())
    }
    func remove() { installation.remove() }

    static func loader(_ verify: Bool) -> AccountlessInstallationPayload.ReleaseLoader {
        { directory in
            try BaseGuestRelease(directory: directory, verifySignature: { path, identifier in
                guard verify else { return }
                // Only fixture signatures relax the production Developer ID requirement.
                var code: SecStaticCode?, requirement: SecRequirement?
                guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
                      SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement) == errSecSuccess,
                      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
                    throw BaseGuestPreparationError.invalidRelease
                }
            })
        }
    }
}
