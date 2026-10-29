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

    /// Every model the product store has an active, receipted revision of. A dev or staging install records its
    /// downloads under its own ref and also reads production's, as the single-Mac scanner does.
    static func installed(cache: URL = ModelScanner.cacheDirectory(),
                          refNames: [String] = ModelScanner.revisionRefNames()) -> [Installed] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).sorted().filter { $0.hasPrefix("models--") }
        return names.prefix(256).compactMap { name in
            let model = cache.appendingPathComponent(name)
            guard let revision = ClusterModelStore.activeRevision(model: model, refNames: refNames) else { return nil }
            let directory = model.appendingPathComponent("snapshots").appendingPathComponent(revision)
            guard let receipt = ClusterModelStore.readSmall(directory.appendingPathComponent(".darkbloom-manifest.json")),
                  let artifact = try? ClusterCatalogArtifact.parse(manifest: receipt) else { return nil }
            return .init(artifact: artifact, directory: directory)
        }
    }

    /// The catalog's exact manifest bytes for a model (the cluster worker pins the registered manifest's own bytes; the
    /// product store keeps a re-encoded receipt), checked to name the same artifact; nil when the catalog does not answer.
    /// `accepts`: whether this Mac's cluster worker takes a manifest (its runtime description, no model load). The
    /// catalog publishes two encodings of one manifest: the CDN's `manifest.json`, the same bytes for every
    /// environment, and the coordinator's re-encoding, whose `created_at` is each environment's own registration time.
    /// The worker pins the CDN's file for every registered model (2026-10-28), so the CDN is asked first. The first
    /// one the worker takes is used; without `accepts` (or when it takes neither), the first that answers.
    static func catalogManifest(providerConfiguration: URL, artifact: ClusterCatalogArtifact, seconds: Double = 5,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                accepts: ((Data) -> Bool)? = nil) -> Data? {
        var urls = [URL]()
        if let prefix = artifact.r2Prefix {
            let cdn = ModelDownloader.resolveCDNURL(environment: environment)
            if let url = URL(string: "\(cdn)/\(ModelDownloader.escapeR2Path(prefix))/manifest.json") { urls.append(url) }
        }
        if let config = try? ConfigManager.loadOrDefaults(from: providerConfiguration), let escaped = ModelCatalogClient.escapeModelIDForPath(artifact.modelID),
           let url = URL(string: "\(coordinatorHTTPBase(config.coordinator.url))/v1/models/catalog/manifest/\(escaped)") { urls.append(url) }
        var candidates = [Data]()
        for url in urls {
            guard let data = fetchManifest(url, artifact: artifact, seconds: seconds), !candidates.contains(data) else { continue }
            if accepts == nil || accepts?(data) == true { return data }
            candidates.append(data)
        }
        return candidates.first
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
              let parsed = try? ClusterCatalogArtifact.parse(manifest: data), parsed.sameArtifact(artifact) else { return nil }
        return data
    }

    /// Clones a product-store model into the cluster's store under its folder name; nil when it is there already.
    /// `providerConfiguration` names the catalog whose exact manifest bytes are written beside the files.
    static func cloneIntoClusterStore(_ installed: Installed, store: URL, providerConfiguration: URL? = nil,
                                      accepts: ((_ manifest: Data, _ folder: URL) -> Bool)? = nil) throws -> String? {
        var artifact = installed.artifact
        if case .complete(let folder) = ClusterModelStore.holding(store: store, artifact: artifact) {
            if let providerConfiguration {
                let directory = store.appendingPathComponent(folder)
                repairManifest(directory, artifact: artifact, providerConfiguration: providerConfiguration,
                               accepts: accepts.map { check in { check($0, directory) } })
            }
            return nil
        }
        guard !FileManager.default.fileExists(atPath: store.appendingPathComponent(artifact.folderName).path) else { return nil }
        if let providerConfiguration, let exact = catalogManifest(providerConfiguration: providerConfiguration, artifact: artifact,
                accepts: accepts.map { check in { check($0, installed.directory) } }) {
            artifact.manifest = exact
        }
        // Own staging per call, exclusive rename: concurrent clones (onboarding and service) never mix files.
        return try ClusterModelStore.cloneFolder(artifact: artifact, from: installed.directory, into: store)
    }

    private static let repairLock = NSLock()
    nonisolated(unsafe) private static var repairChecked = Set<String>()

    /// A model cloned in while the catalog did not answer kept the product store's re-encoded receipt as its
    /// manifest; the worker pins the catalog's exact bytes, so the cluster said "not supported" for a verified model
    /// forever (Qwen 3.5 9B, 2026-10-15: the two differed only in `created_at`). When the folder's manifest names
    /// `artifact` (model, version, aggregate and files) but is not bytes the worker takes, the catalog's bytes replace
    /// it, once they name exactly that artifact too (`fetchManifest`) and the worker takes them. Only `manifest.json`
    /// is replaced (atomically); the weight files are never opened. Otherwise the folder is left as it is.
    static func repairManifest(_ folder: URL, artifact: ClusterCatalogArtifact, providerConfiguration: URL,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               accepts: ((Data) -> Bool)? = nil) {
        let manifest = folder.appendingPathComponent("manifest.json")
        // Asked once per folder per process: the catalog is read only for a model it has not been checked against;
        // a manifest this Mac's worker already takes is left as it is.
        // Only with the worker's own answer: without it the catalog's two encodings could replace one the worker takes.
        guard let accepts, repairLock.withLock({ repairChecked.insert(folder.path).inserted }),
              let current = ClusterModelStore.readSmall(manifest), !accepts(current),
              let parsed = try? ClusterCatalogArtifact.parse(manifest: current), parsed.sameArtifact(artifact),
              let exact = catalogManifest(providerConfiguration: providerConfiguration, artifact: artifact,
                                          environment: environment, accepts: accepts),
              exact != current, accepts(exact) else { return }
        var information = stat()
        guard lstat(folder.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR, information.st_uid == geteuid() else { return }
        try? exact.write(to: manifest, options: [.atomic])
        _ = chmod(manifest.path, 0o600)
    }

    /// Brings the cluster's store up to date before its models are listed or planned: every product-store model a pair
    /// may serve is cloned in, then every servable folder's manifest is repaired (`repairStoreManifests`). Runs where
    /// each Mac lists its models (its setup report, which also answers the other Mac) and before the leader plans, so
    /// an update needs no hand step.
    static func updateClusterStore(_ store: URL, providerConfiguration: URL,
                                   accepts: @escaping (_ manifest: Data, _ folder: URL) -> Bool) {
        let servable = ClusterModelCopyTrust.servableArtifacts
        for model in installed() where servable.contains(model.artifact.aggregateSHA256) {
            _ = try? cloneIntoClusterStore(model, store: store, providerConfiguration: providerConfiguration, accepts: accepts)
        }
        repairStoreManifests(store: store, servable: servable, providerConfiguration: providerConfiguration, accepts: accepts)
    }

    /// The same repair for every folder of the cluster's store whose artifact a pair may serve (`servable`), each
    /// against its own manifest. A folder copied over the cable has no product-store receipt here, so clone-in never
    /// repairs it: after the pin change of 2026-10-28 (every registered model pins the CDN's `manifest.json`) this
    /// Mac's worker refuses a copied folder that kept the production coordinator's bytes, and without this repair only
    /// removing the folder by hand would bring the model back.
    static func repairStoreManifests(store: URL, servable: Set<String>, providerConfiguration: URL,
                                     environment: [String: String] = ProcessInfo.processInfo.environment,
                                     accepts: @escaping (_ manifest: Data, _ folder: URL) -> Bool) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []).sorted()
        for name in names.prefix(256) where !name.hasPrefix(".") {
            let folder = store.appendingPathComponent(name)
            guard let data = ClusterModelStore.readSmall(folder.appendingPathComponent("manifest.json")),
                  let held = try? ClusterCatalogArtifact.parse(manifest: data), servable.contains(held.aggregateSHA256) else { continue }
            repairManifest(folder, artifact: held, providerConfiguration: providerConfiguration, environment: environment,
                           accepts: { accepts($0, folder) })
        }
    }
}

/// The trust check for a copied model with this build's records (`ClusterModelCopyTrust.refusal(_:pinnedArtifacts:protected:)`):
/// accepted from another Mac only when this build's qualification records pin its exact artifact digest; a build the
/// catalog marks with required runtime capabilities (the protected builds) keeps its own refusal words.
extension ClusterModelCopyTrust {
    /// Every artifact digest this build's bundled qualification records name.
    static let pinnedArtifacts: Set<String> = Set(ClusterPairServingGrants.records.map(\.artifactSHA256))

    /// The artifacts a pair may serve with this build: every artifact this build's records pin (the copy trust above)
    /// whose model a cluster stage adapter runs. Records never refuse the owner's serving (2026-10-14 08:45), so a model
    /// with no public grant (Gemma 4 8-bit) is offered too; whether the Macs can hold it is the planner's.
    static let servableArtifacts: Set<String> = Set(ClusterPairServingGrants.records
        .filter { ClusterPairServingGrants.hasStageAdapter(runtimeModelID: $0.runtimeModelID) }.map(\.artifactSHA256))

    static func refusal(_ artifact: ClusterCatalogArtifact) -> String? {
        refusal(artifact, pinnedArtifacts: pinnedArtifacts,
                protected: !ModelRuntimeRequirements.requiredCapabilities(for: artifact.modelID).isEmpty)
    }
}
