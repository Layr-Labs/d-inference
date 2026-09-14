import Foundation
import SandboxRuntime

/// Prepares a reviewable overlay only. No host-root IO, image attach, installer
/// execution or VM lifecycle is reachable from this materializer.
struct AccountlessInstallationPayload: Sendable {
    typealias ReleaseLoader = @Sendable (URL) throws -> BaseGuestRelease
    let loadRelease: ReleaseLoader

    init(loadRelease: @escaping ReleaseLoader = { try BaseGuestRelease(directory: $0) }) {
        self.loadRelease = loadRelease
    }

    func prepare(candidate: AccountlessBaseCandidateRecord, release: BaseGuestRelease,
                 destination: URL) async throws -> AccountlessInstallationPayloadPlan {
        let binding = try AccountlessInstallationBinding(candidate: candidate, release: release)
        try requireMatching(try loadRelease(release.directory), release)
        guard destination.path != release.directory.path,
              !destination.path.hasPrefix(release.directory.path + "/") else {
            throw AccountlessInstallationError.unsafeDestination
        }
        let output = try AccountlessInstallationPayloadFiles(destination: destination)
        let attempt = binding.bootstrapAttemptID.uuidString.lowercased()
        let guestStage = "Library/Application Support/DarkbloomSandboxBootstrap/" + attempt
        let guestJob = "Library/LaunchDaemons/io.darkbloom.sandbox.install." + attempt + ".plist"
        let stage = try output.createDirectory("data-overlay/" + guestStage)
        let stagedRelease = try output.createDirectory("data-overlay/" + guestStage + "/release")
        _ = try output.createDirectory("data-overlay/" + guestStage + "/release/guest")
        try await output.copyRelease(release, to: stagedRelease)
        try requireMatching(try loadRelease(stagedRelease), release)
        try requireMatching(try loadRelease(release.directory), release)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bindingData = try encoder.encode(binding)
        let bindingHash = BaseGuestRelease.digest(bindingData)
        try output.write(bindingData, to: stage.appendingPathComponent("installation-binding.json"), mode: 0o400)
        try output.write(Data(AccountlessInstallationReceiptWriter.shellFunction.utf8),
            to: stage.appendingPathComponent("receipt-writer.zsh"), mode: 0o400)
        try output.write(Data(AccountlessInstallationGuestChecks.shell.utf8),
            to: stage.appendingPathComponent("installation-checks.zsh"), mode: 0o400)
        try output.write(Data(AccountlessInstallationGuestScript.shell.utf8),
            to: stage.appendingPathComponent("first-boot.zsh"), mode: 0o500)
        let jobDirectory = try output.createDirectory("data-overlay/Library/LaunchDaemons")
        let job: [String: Any] = ["Label": "io.darkbloom.sandbox.install." + attempt,
            "ProgramArguments": ["/bin/zsh", "-f", "/" + guestStage + "/first-boot.zsh", attempt, bindingHash],
            "UserName": "root", "GroupName": "wheel", "RunAtLoad": true, "KeepAlive": false,
            "ProcessType": "Background", "Umask": 63]
        try output.write(PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
            to: jobDirectory.appendingPathComponent(URL(fileURLWithPath: guestJob).lastPathComponent), mode: 0o400)
        try Task.checkCancellation()
        try requireMatching(try loadRelease(release.directory), release)
        try requireMatching(try loadRelease(stagedRelease), release)
        let plan = AccountlessInstallationPayloadPlan(schemaVersion: 1, binding: binding, bindingSHA256: bindingHash,
            guestStagePath: "/" + guestStage, guestLaunchDaemonPath: "/" + guestJob,
            guestReceiptPath: "/" + guestStage + "/result/receipt.json", maximumBootSeconds: 300,
            files: try output.inventory())
        try output.write(encoder.encode(plan), to: destination.appendingPathComponent("plan.json"), mode: 0o400)
        try output.synchronize()
        return plan
    }

    private func requireMatching(_ current: BaseGuestRelease, _ expected: BaseGuestRelease) throws {
        guard current.manifestSHA256 == expected.manifestSHA256, current.hashes == expected.hashes else {
            throw AccountlessInstallationError.releaseChanged
        }
    }
}
