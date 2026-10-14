import Foundation
import Darwin

// The cluster's model store beside the product's model cache, the product's single-Mac store seen from the cluster,
// and the protected-build trust check for a copied model (needs the whole provider; the copy itself does not).

/// Where the cluster's model folders live when no folder was given (`darkbloom cluster` needs no `--model-dir`):
/// beside the product's own model cache, so a model single-Mac Darkbloom downloaded is cloned in on the same volume
/// with no new blocks, and a copy lands on the disk the person chose for models.
public enum ClusterModelStoreLocation {
    public static func defaultDirectory() -> URL {
        ModelScanner.cacheDirectory().deletingLastPathComponent().appendingPathComponent("darkbloom-cluster-models", isDirectory: true)
    }
}

/// The product's single-Mac model store (the models `darkbloom` downloaded, discovered as single-Mac Darkbloom
/// discovers them) seen from the cluster: each active revision's verified receipt is the catalog manifest, and its
/// files are cloned into the cluster's store (APFS clones: no new blocks, each file single-linked) so the cluster
/// worker loads it from a flat folder with its manifest.
enum ClusterProductModelStore {
    struct Installed: Sendable { var artifact: ClusterCatalogArtifact; var directory: URL }

    /// Every model the product store has an active, receipted revision of.
    static func installed(cache: URL = ModelScanner.cacheDirectory()) -> [Installed] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).sorted().filter { $0.hasPrefix("models--") }
        return names.prefix(256).compactMap { name in
            let model = cache.appendingPathComponent(name)
            guard let ref = ClusterModelStore.readSmall(model.appendingPathComponent("refs/main")),
                  let revision = String(data: ref, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !revision.isEmpty, !revision.contains("/") else { return nil }
            let directory = model.appendingPathComponent("snapshots").appendingPathComponent(revision)
            guard let receipt = ClusterModelStore.readSmall(directory.appendingPathComponent(".darkbloom-manifest.json")),
                  let artifact = try? ClusterCatalogArtifact.parse(manifest: receipt) else { return nil }
            return .init(artifact: artifact, directory: directory)
        }
    }

    /// The catalog's exact manifest bytes for a model (the cluster worker pins the registered manifest's own bytes; the
    /// product store keeps a re-encoded receipt), checked to name the same artifact; nil when the catalog does not answer.
    static func catalogManifest(providerConfiguration: URL, artifact: ClusterCatalogArtifact, seconds: Double = 5) -> Data? {
        // The published manifest.json on the model CDN is the registered file itself (the coordinator's manifest
        // endpoint serves the same content re-encoded); the coordinator is asked only when the CDN does not answer.
        var urls = [URL]()
        if let prefix = artifact.r2Prefix {
            let cdn = (ProcessInfo.processInfo.environment["DARKBLOOM_R2_CDN_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? ModelDownloader.defaultR2CDNURL)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let url = URL(string: "\(cdn)/\(ModelDownloader.escapeR2Path(prefix))/manifest.json") { urls.append(url) }
        }
        if let config = try? ConfigManager.load(from: providerConfiguration), let escaped = ModelCatalogClient.escapeModelIDForPath(artifact.modelID),
           let url = URL(string: "\(coordinatorHTTPBase(config.coordinator.url))/v1/models/catalog/manifest/\(escaped)") { urls.append(url) }
        for url in urls { if let data = fetchManifest(url, artifact: artifact, seconds: seconds) { return data } }
        return nil
    }

    private static func fetchManifest(_ url: URL, artifact: ClusterCatalogArtifact, seconds: Double) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = seconds
        let box = ClusterOnboardingMailbox<Data>()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200, data.count <= ClusterCatalogArtifact.maximumManifestBytes { box.post(data) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + seconds + 1) == .success, let data = box.take().first,
              let parsed = try? ClusterCatalogArtifact.parse(manifest: data), parsed.aggregateSHA256 == artifact.aggregateSHA256,
              parsed.files == artifact.files else { return nil }
        return data
    }

    /// Clones a product-store model into the cluster's store under its folder name; nil when it is there already.
    /// `providerConfiguration` names the catalog whose exact manifest bytes are written beside the files.
    static func cloneIntoClusterStore(_ installed: Installed, store: URL, providerConfiguration: URL? = nil) throws -> String? {
        var artifact = installed.artifact
        if case .complete = ClusterModelStore.holding(store: store, artifact: artifact) { return nil }
        guard !FileManager.default.fileExists(atPath: store.appendingPathComponent(artifact.folderName).path) else { return nil }
        if let providerConfiguration, let exact = catalogManifest(providerConfiguration: providerConfiguration, artifact: artifact) {
            artifact.manifest = exact
        }
        // Own staging per call, exclusive rename: concurrent clones (onboarding and service) never mix files.
        return try ClusterModelStore.cloneFolder(artifact: artifact, from: installed.directory, into: store)
    }
}

/// The trust check for a copied model with this build's records (`ClusterModelCopyTrust.refusal(_:pinnedArtifacts:protected:)`):
/// accepted from another Mac only when this build's qualification records pin its exact artifact digest; a build the
/// catalog marks with required runtime capabilities (the protected builds) keeps its own refusal words.
extension ClusterModelCopyTrust {
    /// Every artifact digest this build's bundled qualification records name.
    static let pinnedArtifacts: Set<String> = Set(ClusterPairServingGrants.records.map(\.artifactSHA256))

    /// The artifacts a pair may serve with this build (a granted model's records, for a model the installed path has
    /// time budgets for): what the onboarding offers to copy from another Mac or to download, so nobody waits for bytes
    /// these Macs could not serve together.
    static let servableArtifacts: Set<String> = {
        let rows = Set(DistributedInstalledPairServingTable.rows.map(\.runtimeModelID))
        let granted = Set(ClusterPairServingGrants.granted.map(\.runtimeModelID)).intersection(rows)
        return Set(ClusterPairServingGrants.records.filter { granted.contains($0.runtimeModelID) }.map(\.artifactSHA256))
    }()

    static func refusal(_ artifact: ClusterCatalogArtifact) -> String? {
        refusal(artifact, pinnedArtifacts: pinnedArtifacts,
                protected: !ModelRuntimeRequirements.requiredCapabilities(for: artifact.modelID).isEmpty)
    }
}
