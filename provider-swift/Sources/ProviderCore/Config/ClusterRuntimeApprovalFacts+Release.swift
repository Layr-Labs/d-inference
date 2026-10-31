import Foundation
import DarkbloomClusterProtocol

/// The facts a signed release registers (`cluster_runtime`), computed by the
/// release's own CLI and worker from its final signed app: the models this
/// build qualifies on a cluster, described from the metadata of the target
/// environment's catalog (`scripts/provider-cluster-runtime-facts.sh`), with
/// the parity qualifications of the models this build declares public.
extension ClusterRuntimeApprovalFacts {
    /// A model a release describes: a registered model with a cluster stage
    /// adapter and a passing pair qualification record on this artifact.
    public struct ReleaseModel: Codable, Hashable, Sendable {
        public let runtimeModelID: String
        public let artifactSHA256: String

        public init(runtimeModelID: String, artifactSHA256: String) {
            self.runtimeModelID = runtimeModelID; self.artifactSHA256 = artifactSHA256
        }

        enum CodingKeys: String, CodingKey {
            case runtimeModelID = "runtime_model_id"
            case artifactSHA256 = "artifact_sha256"
        }
    }

    /// The models this build qualifies on a cluster, from its own bundled
    /// qualification records (`ClusterPairServingGrants.records`): the one
    /// source of a release's model list.
    public static var releaseModels: [ReleaseModel] { qualifiedModels(records: ClusterPairServingGrants.records) }

    static func qualifiedModels(records: [ClusterPairQualificationRecord]) -> [ReleaseModel] {
        Set(records.filter {
            $0.isConsistent && $0.outcome == .passed && ClusterPairServingGrants.hasStageAdapter(runtimeModelID: $0.runtimeModelID)
        }.map { ReleaseModel(runtimeModelID: $0.runtimeModelID, artifactSHA256: $0.artifactSHA256) })
            .sorted { ($0.runtimeModelID, $0.artifactSHA256) < ($1.runtimeModelID, $1.artifactSHA256) }
    }

    /// The facts a release registers. For every model in `models` and every
    /// catalog model ID among the candidates of its artifact (a member may have
    /// installed the artifact under any of them), the first candidate the
    /// worker describes as that model. Candidates of an artifact not in
    /// `models` are never described, and a listed model with no candidate is
    /// left out: the environment's catalog does not have it, and the fetch
    /// step names it. Each candidate's catalog entry gives a declared model's
    /// request envelope its media. Fails naming every catalog model ID that has
    /// no candidate the worker describes as the listed model, and when no
    /// model is left.
    public static func release(installation: Installation, candidates: [ModelFiles],
                               models: [ReleaseModel] = ClusterRuntimeApprovalFacts.releaseModels,
                               publicModels: [ClusterPublicModel] = ClusterPublicModels.declared) throws -> Self {
        let installed = try HashedInstallation(installation)
        let parsed = try candidates.map { ($0, try catalogArtifact($0)) }
        var entries: [Model] = [], failures: [String] = []
        for listed in models {
            let ofArtifact = parsed.filter { $0.1.aggregateSHA256 == listed.artifactSHA256 }
            var catalogIDs: [String] = []
            for (_, artifact) in ofArtifact where !catalogIDs.contains(artifact.modelID) { catalogIDs.append(artifact.modelID) }
            for catalogID in catalogIDs {
                var refusals: [String] = [], chosen: Model?
                for (files, artifact) in ofArtifact where artifact.modelID == catalogID {
                    do {
                        let described = try installed.describe(files, publicModels: publicModels)
                        if described.runtimeModelID == listed.runtimeModelID { chosen = described.entry; break }
                        refusals.append("\(files.manifest.path) is \(described.runtimeModelID)")
                    } catch {
                        refusals.append("\(files.manifest.path): \(error)")
                    }
                }
                if let chosen { entries.append(chosen) }
                else { failures.append("\(catalogID) (\(listed.runtimeModelID), \(listed.artifactSHA256)): " + refusals.joined(separator: "; ")) }
            }
        }
        guard failures.isEmpty else {
            throw ClusterConfigurationError.invalid("Qualified cluster models the release cannot describe: " + failures.joined(separator: " | "))
        }
        guard !entries.isEmpty else {
            throw ClusterConfigurationError.invalid("No candidate folder holds a model this build qualifies on a cluster")
        }
        return try installed.facts(entries)
    }

    /// The candidate folders of a release: every subfolder of `directory`, in
    /// name order, each with its `config.json`, `manifest.json` and the
    /// catalog entry it came from (`catalog.json`).
    public static func candidates(in directory: URL) throws -> [ModelFiles] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch { throw ClusterConfigurationError.invalid("Cannot list the candidate folder \(directory.path)") }
        return names.filter { !$0.hasPrefix(".") }.sorted().map {
            let folder = directory.appendingPathComponent($0, isDirectory: true)
            return ModelFiles(configuration: folder.appendingPathComponent("config.json"),
                              manifest: folder.appendingPathComponent("manifest.json"),
                              catalog: folder.appendingPathComponent("catalog.json"))
        }
    }
}
