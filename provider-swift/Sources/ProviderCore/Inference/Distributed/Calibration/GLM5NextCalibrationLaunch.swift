import CryptoKit
import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterRemote

/// Launch specification only. The installed private command must retain the
/// bootstrap, supervise report/exit (NOT READY), and observe both actual exits
/// before replacement/refund. No public capability or serving lease is produced.
enum GLM5NextCalibrationLaunch {
    static let appIdentityVariable = "DARKBLOOM_GLM_CALIBRATION_APP_SHA256"
    static let peerIdentityVariable = "DARKBLOOM_GLM_CALIBRATION_PEER_SHA256"
    static func peerFingerprint(_ key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func requireEnvironment(_ environment: [String: String],
                                   expected: GLM5NextCalibrationDocument.Environment,
                                   appSHA256: String, rank: Int) throws {
        let ordinary: Set<String> = ["PATH", "LANG", "LC_ALL", "JACCL_RANK", "JACCL_IBV_DEVICES", "JACCL_COORDINATOR"]
        guard environment.keys.allSatisfy({ ordinary.contains($0) || $0.hasPrefix("MLX_") || $0.hasPrefix("DARKBLOOM_") }),
              environment[appIdentityVariable] == appSHA256,
              environment["JACCL_RANK"] == String(rank),
              environment["JACCL_IBV_DEVICES"]?.hasPrefix("/") == true,
              environment["JACCL_COORDINATOR"]?.isEmpty == false,
              environment.filter({ $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_") })
                .mapValues(digest) == expected.variableSHA256 else {
            throw GLM5NextCalibrationDocument.invalid("Launch environment changed")
        }
    }

    static func verifyDocument(_ url: URL, authorized: GLM5NextCalibrationAuthorizer.Authorized,
                               deadline: UInt64) throws -> DistributedInstalledFiles.Identity {
        try DistributedInstalledFiles.verify(url, expectedSHA256: SHA256.hash(data: authorized.document)
            .map { String(format: "%02x", $0) }.joined(), maximumBytes: 256 << 10,
            executable: false, deadline: deadline)
    }

    static func prepare(authorized: GLM5NextCalibrationAuthorizer.Authorized,
                        binding: ClusterOwnerBinding, document: URL,
                        installedApp: URL, appSHA256: String, worker: URL, metallib: URL,
                        modelDirectory: URL, environment: [String: String],
                        attachment: ClusterOwnerBootstrapAttachment,
                        leaseDeadline: UInt64, experimentDeadline: UInt64,
                        nowUptime: UInt64, nowUnix: Int64,
                        requireCurrentSelection: () throws -> Void) throws -> ClusterWorkerLaunch {
        let p = authorized.body.selection
        try GLM5NextCalibrationDocument.validate(authorized.body, identity: binding.identity,
            rank: binding.rank, now: nowUnix, expectedVocabularySize: authorized.expectedVocabularySize)
        // Foundation may standardize an existing /private/var path back to
        // the /var symlink. Validate spelling here; the file verifier below
        // walks every directory with O_NOFOLLOW and hashes the actual file.
        for url in [document, installedApp, worker, metallib, modelDirectory] {
            guard url.isFileURL else { throw GLM5NextCalibrationDocument.invalid("Expected local launch paths") }
            try ClusterConfigurationFiles.requireAbsolute(url.path)
        }
        guard binding.identity == authorized.identity,
              binding.profile == authorized.body.binding.profile.workerProfile,
              binding.executionPlanSHA256 == authorized.body.binding.executionPlanSHA256,
              leaseDeadline > nowUptime, leaseDeadline - nowUptime <= ClusterWorkerLease.maximumNanoseconds,
              experimentDeadline > nowUptime,
              experimentDeadline - nowUptime <= ClusterWorkerLimits.deadlineNanoseconds,
              experimentDeadline - nowUptime <= UInt64(p.expiresUnixSeconds - nowUnix) * 1_000_000_000,
              attachment.calibrationExperimentDeadline == experimentDeadline,
              attachment.deadlineUptimeNanoseconds > nowUptime,
              attachment.deadlineUptimeNanoseconds <= experimentDeadline,
              attachment.deadlineUptimeNanoseconds - nowUptime <= ClusterOwnerBootstrapAttachment.maximumBootstrapNanoseconds,
              metallib == worker.deletingLastPathComponent().appendingPathComponent("mlx.metallib"),
              environment["JACCL_RANK"] == String(p.rank),
              environment["JACCL_IBV_DEVICES"]?.hasPrefix("/") == true,
              environment["JACCL_COORDINATOR"]?.isEmpty == false else {
            throw GLM5NextCalibrationDocument.invalid("Launch differs from bounded installed selection")
        }
        try requireEnvironment(environment, expected: p.environment, appSHA256: appSHA256, rank: p.rank)
        // The installed owner supplies/rechecks pairing, model custody, device,
        // bootstrap routing and authorized budget. No caller-controlled catalog entry.
        try requireCurrentSelection()
        let files = try [
            DistributedInstalledFiles.verify(installedApp, expectedSHA256: appSHA256,
                maximumBytes: 256 << 20, executable: true, deadline: leaseDeadline),
            DistributedInstalledFiles.verify(worker, expectedSHA256: p.environment.binarySHA256,
                maximumBytes: 256 << 20, executable: true, deadline: leaseDeadline),
            DistributedInstalledFiles.verify(metallib, expectedSHA256: p.environment.metallibSHA256,
                maximumBytes: 256 << 20, executable: false, deadline: leaseDeadline),
            verifyDocument(document, authorized: authorized, deadline: leaseDeadline)
        ]
        for file in files { try file.requireUnchanged() }
        let id = binding.identity
        let arguments = ["--glm-calibrate", "--glm-qualification", document.path,
            "--qualification-switches", "yes", "--keep-warm", "off", "--data-plane", "encrypted_v1",
            "--model-dir", modelDirectory.path, "--rank", String(p.rank), "--stage-cut", String(p.cut),
            "--membership-epoch", p.epoch.uuidString.lowercased(), "--model-id", id.modelID,
            "--artifact-sha256", id.artifactSHA256, "--configuration-sha256", id.configurationSHA256,
            "--peer0-id", id.peers[0].id, "--peer0-build-sha256", id.peers[0].buildSHA256,
            "--peer1-id", id.peers[1].id, "--peer1-build-sha256", id.peers[1].buildSHA256,
            "--deadline-uptime-nanoseconds", String(leaseDeadline),
            "--startup-deadline-uptime-nanoseconds", String(experimentDeadline)] + attachment.workerArguments
        return .init(executable: worker, arguments: arguments, environment: environment,
            initialInput: authorized.credentialInput)
    }
}
