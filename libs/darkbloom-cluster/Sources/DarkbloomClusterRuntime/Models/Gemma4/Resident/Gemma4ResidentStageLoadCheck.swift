import DarkbloomClusterProtocol
import Foundation

/// Loads one rank's verified stage of a registered Gemma artifact on this Mac
/// and releases it again, without creating a collective. The measurement and
/// its receipt are the registered Qwen check's; only admission and the loader
/// are this family's.
public enum Gemma4ResidentStageLoadCheck {
    /// Whether an artifact directory's `config.json` is a registered Gemma model's.
    public static func isRegistered(configuration: Data) -> Bool {
        Gemma4RegisteredSpecification.isRegistered(configuration: configuration)
    }

    /// The admission this rank's worker would pass on this Mac, with a synthetic
    /// device matrix and no transport environment. The artifact's own
    /// configuration and manifest select the registered row.
    static func admit(modelDirectory: URL, rank: Int, stageCut: Int,
                      deadlineUptimeNanoseconds: UInt64) throws -> Gemma4ResidentAdmission {
        let transport = try QwenResidentStageLoadCheck.syntheticTransport(rank: rank)
        let configBytes = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
                                                    maximumBytes: 1_048_576)
        let manifestBytes = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"),
                                                      maximumBytes: 4_194_304)
        let specification = try Gemma4RegisteredSpecification.registered(configuration: configBytes,
                                                                         manifest: manifestBytes)
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: specification.model.rawValue,
            artifactSHA256: specification.artifactSHA256, configurationSHA256: specification.configurationSHA256,
            peers: (0...1).map {
                ClusterWorkerPeer(id: "stage-load-check-\($0)", buildSHA256: String(repeating: "0", count: 64))
            })
        return try Gemma4ResidentAdmission(configuration: .init(identity: identity, modelDirectory: modelDirectory,
                rank: rank, stageCut: stageCut, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds),
            configBytes: configBytes, manifestBytes: manifestBytes, environment: transport.environment,
            now: DispatchTime.now().uptimeNanoseconds, read: transport.read)
    }

    public static func run(modelDirectory: URL, rank: Int, stageCut: Int, deadlineUptimeNanoseconds: UInt64,
                           holdSeconds: Int = 0) throws -> QwenResidentStageLoadCheck.Receipt {
        let admission = try admit(modelDirectory: modelDirectory, rank: rank, stageCut: stageCut,
                                  deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
        return try QwenResidentStageLoadCheck.measure(rank: rank, stageCut: stageCut,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds, holdSeconds: holdSeconds) { check, constructed in
            try loadGemma4ResidentStage(admission, check: check, constructed: constructed).loaded
        }
    }
}
