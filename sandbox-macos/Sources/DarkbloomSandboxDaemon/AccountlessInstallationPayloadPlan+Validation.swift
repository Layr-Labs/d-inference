import Foundation

extension AccountlessInstallationPayloadPlan {
    var stageRelativePath: String {
        "Library/Application Support/DarkbloomSandboxBootstrap/" + binding.bootstrapAttemptID.uuidString.lowercased()
    }

    var jobRelativePath: String {
        "Library/LaunchDaemons/io.darkbloom.sandbox.install." + binding.bootstrapAttemptID.uuidString.lowercased() + ".plist"
    }

    var expectedFilePaths: Set<String> {
        let stage = stageRelativePath
        return Set(BaseGuestRelease.files.map { stage + "/release/guest/" + $0 }
            + [stage + "/release/release-manifest.json", stage + "/installation-binding.json",
               stage + "/receipt-writer.zsh", stage + "/installation-checks.zsh",
               stage + "/first-boot.zsh", jobRelativePath])
    }

    func validate(candidate: AccountlessBaseCandidateRecord) throws {
        guard schemaVersion == 1, binding.matches(candidate), BaseGuestRelease.isDigest(bindingSHA256),
              guestStagePath == "/" + stageRelativePath, guestLaunchDaemonPath == "/" + jobRelativePath,
              guestReceiptPath == "/" + stageRelativePath + "/result/receipt.json", maximumBootSeconds == 300,
              Set(files.keys) == expectedFilePaths, files.values.allSatisfy(BaseGuestRelease.isDigest),
              files[stageRelativePath + "/installation-binding.json"] == bindingSHA256,
              files[stageRelativePath + "/release/release-manifest.json"] == binding.payload.releaseManifestSHA256,
              files[stageRelativePath + "/release/guest/darkbloom-sandbox-guest"] == binding.payload.guestSHA256,
              files[stageRelativePath + "/release/guest/darkbloom-sandbox-bootstrap.sh"] == binding.payload.bootstrapSHA256,
              files[stageRelativePath + "/release/guest/io.darkbloom.sandbox.guest.plist"] == binding.payload.launchdSHA256,
              files[stageRelativePath + "/release/guest/install-sandbox-guest.sh"] == binding.payload.installerSHA256
        else { throw AccountlessInstallationError.invalidBinding }
    }

    func fileMode(_ relative: String) throws -> UInt16 {
        guard expectedFilePaths.contains(relative) else { throw AccountlessInstallationError.invalidBinding }
        return relative == stageRelativePath + "/first-boot.zsh"
            || relative == stageRelativePath + "/release/guest/darkbloom-sandbox-guest" ? 0o500 : 0o400
    }
}
