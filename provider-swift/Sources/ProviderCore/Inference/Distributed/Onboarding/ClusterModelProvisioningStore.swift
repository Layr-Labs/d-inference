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
        let folder = artifact.folderName
        let destination = store.appendingPathComponent(folder)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }
        if let providerConfiguration, let exact = catalogManifest(providerConfiguration: providerConfiguration, artifact: artifact) {
            artifact.manifest = exact
        }
        let staging = store.appendingPathComponent(".darkbloom-clone-" + String(artifact.aggregateSHA256.prefix(32)))
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in artifact.files {
                let target = staging.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                var info = stat()
                let source = installed.directory.appendingPathComponent(file.path)
                guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == file.sizeBytes else {
                    throw ClusterSetupFailure("the product store's \(file.path) is missing or not its manifest size")
                }
                guard clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
                    throw ClusterSetupFailure("\(file.path) could not be cloned into the cluster's model store (errno \(errno)); the cluster store must be on the same disk as the product's models")
                }
            }
            try artifact.manifest.write(to: staging.appendingPathComponent("manifest.json"))
            guard rename(staging.path, destination.path) == 0 else { throw ClusterSetupFailure("the cloned folder could not be put in place") }
            return folder
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}

/// The protected-build trust check for a copied model: a build the catalog marks with required runtime capabilities
/// (the Qwen3.8 27B builds) is accepted from another Mac only when this build's own qualification records pin its
/// exact artifact digest; every other model is accepted on its manifest (each file then verified by digest).
enum ClusterModelCopyTrust {
    static func refusal(_ artifact: ClusterCatalogArtifact) -> String? {
        guard !ModelRuntimeRequirements.requiredCapabilities(for: artifact.modelID).isEmpty else { return nil }
        if ClusterPairQualificationRecordsBundled.jsonLines.contains("\"artifactSHA256\":\"\(artifact.aggregateSHA256)\"") { return nil }
        return "\(artifact.modelID) is a protected build, and this build's qualification records do not pin the offered digest \(artifact.aggregateSHA256.prefix(12))…; it was not accepted"
    }
}
