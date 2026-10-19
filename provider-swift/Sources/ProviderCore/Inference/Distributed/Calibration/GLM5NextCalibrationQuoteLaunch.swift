import CryptoKit
import Foundation
import DarkbloomClusterProcess

/// A prepared quote is not a launch permit that survives changes. Its caller
/// holds installed selection/custody and rechecks it immediately before spawn.
enum GLM5NextCalibrationQuoteLaunch {
    struct Prepared {
        let launch: ClusterWorkerLaunch
        private let files: [DistributedInstalledFiles.Identity]
        private let deadline: UInt64
        private let requireCurrentSelection: () throws -> Void

        fileprivate init(launch: ClusterWorkerLaunch, files: [DistributedInstalledFiles.Identity],
                         deadline: UInt64, requireCurrentSelection: @escaping () throws -> Void) {
            self.launch = launch; self.files = files; self.deadline = deadline
            self.requireCurrentSelection = requireCurrentSelection
        }
        func requireUnchanged() throws {
            try DistributedInstalledFiles.check(deadline)
            try requireCurrentSelection()
            for file in files { try file.requireUnchanged() }
            try DistributedInstalledFiles.check(deadline)
        }
    }

    static func prepare(authorized: GLM5NextCalibrationQuoteAuthorizer.Authorized,
                        document: URL, installedApp: URL, worker: URL, metallib: URL,
                        modelDirectory: URL, environment: [String: String],
                        deadline: UInt64, nowUptime: UInt64, nowUnix: Int64,
                        requireCurrentSelection: @escaping () throws -> Void) throws -> Prepared {
        let request = authorized.request, p = request.selection
        try GLM5NextCalibrationQuoteDocument.validate(request, identity: authorized.identity,
            rank: p.rank, now: nowUnix, appSHA256: request.appSHA256,
            peerIdentitySHA256: request.peerIdentitySHA256)
        guard deadline > nowUptime, deadline - nowUptime <= 300_000_000_000,
              deadline - nowUptime <= UInt64(p.expiresUnixSeconds - nowUnix) * 1_000_000_000,
              metallib == worker.deletingLastPathComponent().appendingPathComponent("mlx.metallib") else {
            throw GLM5NextCalibrationDocument.invalid("Quotation paths or deadline differ")
        }
        for url in [document, installedApp, worker, metallib, modelDirectory] {
            guard url.isFileURL else { throw GLM5NextCalibrationDocument.invalid("Expected local quotation paths") }
            try ClusterConfigurationFiles.requireAbsolute(url.path)
        }
        try GLM5NextCalibrationLaunch.requireEnvironment(environment, expected: p.environment,
            appSHA256: request.appSHA256, rank: p.rank)
        try requireCurrentSelection()
        let documentSHA256 = SHA256.hash(data: authorized.document).map { String(format: "%02x", $0) }.joined()
        let files = try [
            DistributedInstalledFiles.verify(installedApp, expectedSHA256: request.appSHA256,
                maximumBytes: 256 << 20, executable: true, deadline: deadline),
            DistributedInstalledFiles.verify(worker, expectedSHA256: p.environment.binarySHA256,
                maximumBytes: 256 << 20, executable: true, deadline: deadline),
            DistributedInstalledFiles.verify(metallib, expectedSHA256: p.environment.metallibSHA256,
                maximumBytes: 256 << 20, deadline: deadline),
            DistributedInstalledFiles.verify(document, expectedSHA256: documentSHA256,
                maximumBytes: 256 << 10, deadline: deadline)
        ]
        let launch = ClusterWorkerLaunch(executable: worker,
            arguments: ["--glm-calibration-quote", "--request", document.path,
                "--model-dir", modelDirectory.path, "--membership-epoch", p.epoch.uuidString.lowercased(),
                "--rank", String(p.rank), "--deadline-uptime-nanoseconds", String(deadline)],
            environment: environment, initialInput: authorized.credentialInput)
        let prepared = Prepared(launch: launch, files: files, deadline: deadline,
            requireCurrentSelection: requireCurrentSelection)
        try prepared.requireUnchanged()
        return prepared
    }
}
