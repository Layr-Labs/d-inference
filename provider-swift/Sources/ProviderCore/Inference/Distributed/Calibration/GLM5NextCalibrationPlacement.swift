import DarkbloomClusterPlacement
import DarkbloomClusterProcess
@_spi(OwnerService) import DarkbloomClusterRemote
import Foundation

/// Installed CLI orchestration only. Snapshots suggest a cut; neither decoded
/// observations nor a plan helper can construct Completed or a native grant.
public enum GLM5NextCalibrationPlacement {
    typealias P = ClusterGLMCalibrationPlacement
    struct Selection {
        let decision: P.Decision
        let localInputSHA256: String
        let validUntil: Int64
        fileprivate init(decision: P.Decision, localInputSHA256: String, validUntil: Int64) {
            self.decision = decision; self.localInputSHA256 = localInputSHA256; self.validUntil = validUntil
        }
        func requireCurrent(input: Data) throws {
            guard Int64(Date().timeIntervalSince1970) < validUntil,
                  try P.bindings(input).local == localInputSHA256 else {
                throw GLM5NextCalibrationDocument.invalid("Automatic placement expired or its local selection changed")
            }
        }
    }
    static func select(input: URL, snapshots: [URL]) throws -> Selection {
        guard snapshots.count == 2 else { throw GLM5NextCalibrationDocument.invalid("Pass exactly two --placement snapshots") }
        let data = try ClusterConfigurationFiles.read(input, maximum: 256 << 10, privateMode: true)
        let binding = try P.bindings(data)
        let values = try snapshots.map { try P.decode(ClusterConfigurationFiles.read($0, maximum: P.maximumBytes, privateMode: true)) }
        let decision = try P.select(values, now: Int64(Date().timeIntervalSince1970))
        guard let own = values.first(where: { $0.inputSHA256 == binding.local }), own.commonSHA256 == binding.common else {
            throw GLM5NextCalibrationDocument.invalid("Neither GLM snapshot belongs to this exact local template")
        }
        // Decode only AFTER the automatically chosen cut was inserted. Templates
        // may omit cut entirely; no caller-chosen seed is required.
        let selected = try JSONDecoder().decode(GLM5NextCalibrationInstalledQuote.Input.self,
            from: P.selecting(cut: decision.cut, in: data))
        guard own.rank == selected.request.selection.rank else {
            throw GLM5NextCalibrationDocument.invalid("Automatic placement rank mismatch")
        }
        return Selection(decision: decision, localInputSHA256: binding.local,
            validUntil: values.map { min($0.expiresUnixSeconds, $0.sampledUnixSeconds + P.maximumAgeSeconds) }.min()!)
    }

    /// Metadata-only child of the installed, explicitly hash-pinned plan helper.
    /// No SSH, peer launch, model loading or model-free GPU index benchmark.
    public static func candidates(input: URL, measurements: [URL], plannerSHA256: String,
                                  installedExecutable: URL) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds + 120_000_000_000
        let data = try ClusterConfigurationFiles.read(input, maximum: 256 << 10, privateMode: true)
        _ = try P.bindings(data)
        // Decode the unchanged finite template with a structural placeholder only
        // to locate/hash installed files. The scanner ignores cut and scans all.
        let template = try JSONDecoder().decode(GLM5NextCalibrationInstalledQuote.Input.self,
            from: P.selecting(cut: 1, in: data))
        guard installedExecutable.lastPathComponent == BuildEnvironment.current.cliName,
              installedExecutable.deletingLastPathComponent().lastPathComponent == "MacOS",
              installedExecutable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
              installedExecutable.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent == BuildEnvironment.current.appBundleName,
              measurements.count <= 128 else { throw GLM5NextCalibrationDocument.invalid("Expected installed candidate scanner") }
        let helper = installedExecutable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/darkbloom-cluster-plan")
        let files = try [
            DistributedInstalledFiles.verify(input, expectedSHA256: ClusterConfigurationCodec.sha256(data),
                maximumBytes: 256 << 10, deadline: deadline),
            DistributedInstalledFiles.verify(installedExecutable, expectedSHA256: template.request.appSHA256,
                maximumBytes: 256 << 20, executable: true, deadline: deadline),
            DistributedInstalledFiles.verify(helper, expectedSHA256: plannerSHA256,
                maximumBytes: 256 << 20, executable: true, deadline: deadline),
            DistributedInstalledFiles.verify(helper.deletingLastPathComponent().appendingPathComponent("mlx.metallib"),
                expectedSHA256: template.request.selection.environment.metallibSHA256,
                maximumBytes: 256 << 20, deadline: deadline)
        ]
        let pair = try GLM5NextCalibrationInstalledPair.load(clusterID: template.clusterID, peerPin: template.peerPin)
        let localPin = ClusterMemberPin.of(uncompressedKey: pair.localIdentity)
        let pins = [localPin, ClusterMemberPin.of(uncompressedKey: pair.peerIdentity)].sorted()
        guard pins.firstIndex(of: localPin) == template.request.selection.rank else {
            throw GLM5NextCalibrationDocument.invalid("Candidate rank differs from installed pair")
        }
        try pair.requireUnchanged()
        let paths = try ClusterUserPaths()
        try ClusterConfigurationFiles.ensureDirectory(paths.deviceDirectory, create: true, privateMode: true)
        let lease = try ClusterDeviceLease(directoryURL: paths.deviceDirectory)
        // DistributedCapabilityProbe reaps its actual child before returning OR
        // throwing. Holding this lease through that call cannot orphan a scan.
        defer { withExtendedLifetime(lease) {} }
        for file in files { try file.requireUnchanged() }
        try lease.record(clusterID: pair.clusterID, peerID: ClusterSetupMemberFacts.memberID(pin: localPin),
            rank: template.request.selection.rank, membershipEpoch: template.request.selection.epoch,
            leaseID: template.request.authorization.requestID, ownerIncarnation: UUID(), nativeLaunchID: UUID())
        let output: Data
        do {
            output = try DistributedCapabilityProbe.run(executable: helper,
                arguments: ["glm-calibration-candidates", "--input", input.path]
                    + measurements.flatMap { ["--speed", $0.path] },
                deadline: deadline, maximumOutputBytes: P.maximumBytes)
        } catch {
            // This probe's defer waits for actual exit before throwing.
            try lease.resolve()
            throw error
        }
        try lease.resolve()
        try pair.requireUnchanged()
        for file in files { try file.requireUnchanged() }
        let snapshot = try P.decode(output)
        try snapshot.validate(now: Int64(Date().timeIntervalSince1970))
        guard snapshot.inputSHA256 == (try P.bindings(data).local) else {
            throw GLM5NextCalibrationDocument.invalid("Candidate scan changed its input binding")
        }
        return try P.encode(snapshot)
    }
}
