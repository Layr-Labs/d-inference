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
        guard case .manifest(let data) = catalogAnswer(providerConfiguration: providerConfiguration, artifact: artifact,
                                                       seconds: seconds, environment: environment, accepts: accepts) else { return nil }
        return data
    }

    /// What the catalog answered for an artifact.
    enum CatalogAnswer: Equatable {
        /// Bytes that name exactly the artifact (`catalogManifest`'s choice among them).
        case manifest(Data)
        /// No source gave such bytes, and at least one answered with a manifest of other content.
        case otherContent
        /// No source answered with a manifest.
        case unavailable
    }

    /// `catalogManifest` with the reason when it has no bytes. With a `deadline`, no request waits past it, and a
    /// source not asked before it counts as no answer.
    static func catalogAnswer(providerConfiguration: URL, artifact: ClusterCatalogArtifact, seconds: Double = 5,
                              environment: [String: String] = ProcessInfo.processInfo.environment, deadline: Date? = nil,
                              accepts: ((Data) -> Bool)? = nil) -> CatalogAnswer {
        var urls = [URL]()
        if let prefix = artifact.r2Prefix {
            let cdn = ModelDownloader.resolveCDNURL(environment: environment)
            if let url = URL(string: "\(cdn)/\(ModelDownloader.escapeR2Path(prefix))/manifest.json") { urls.append(url) }
        }
        if let config = try? ConfigManager.loadOrDefaults(from: providerConfiguration), let escaped = ModelCatalogClient.escapeModelIDForPath(artifact.modelID),
           let url = URL(string: "\(coordinatorHTTPBase(config.coordinator.url))/v1/models/catalog/manifest/\(escaped)") { urls.append(url) }
        var candidates = [Data]()
        var otherContent = false
        for url in urls {
            switch fetchManifest(url, artifact: artifact, seconds: seconds, deadline: deadline) {
            case .manifest(let data):
                guard !candidates.contains(data) else { continue }
                if accepts == nil || accepts?(data) == true { return .manifest(data) }
                candidates.append(data)
            case .otherContent: otherContent = true
            case .unavailable: continue
            }
        }
        if let first = candidates.first { return .manifest(first) }
        return otherContent ? .otherContent : .unavailable
    }

    private static func fetchManifest(_ url: URL, artifact: ClusterCatalogArtifact, seconds: Double, deadline: Date?) -> CatalogAnswer {
        var limit = seconds + 1
        if let deadline {
            limit = min(limit, deadline.timeIntervalSinceNow)
            guard limit > 0 else { return .unavailable }
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = min(seconds, limit)
        let box = ClusterOnboardingMailbox<Data>()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200, data.count <= ClusterCatalogArtifact.maximumManifestBytes { box.post(data) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + limit) == .success, let data = box.take().first else { return .unavailable }
        guard let parsed = try? ClusterCatalogArtifact.parse(manifest: data), parsed.sameArtifact(artifact) else { return .otherContent }
        return .manifest(data)
    }

    /// Clones a product-store model into the cluster's store under its folder name; nil when it is there already.
    /// `providerConfiguration` names the catalog whose exact manifest bytes are written beside the files.
    /// `repairDeadline` bounds the repair of a folder that is there already (`repairManifest`).
    static func cloneIntoClusterStore(_ installed: Installed, store: URL, providerConfiguration: URL? = nil,
                                      repairDeadline: Date? = nil,
                                      accepts: ((_ manifest: Data, _ folder: URL) -> Bool)? = nil) throws -> String? {
        var artifact = installed.artifact
        if case .complete(let folder) = ClusterModelStore.holding(store: store, artifact: artifact) {
            if let providerConfiguration {
                let directory = store.appendingPathComponent(folder)
                repairManifest(directory, artifact: artifact, providerConfiguration: providerConfiguration,
                               deadline: repairDeadline, accepts: accepts.map { check in { check($0, directory) } })
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
    /// Folders with a definite outcome: the worker takes the manifest, it was repaired, or the folder or the catalog
    /// holds other content. They are not asked again in this process.
    nonisolated(unsafe) private static var repairSettled = Set<String>()
    /// Folders whose last attempt failed (no answer from the catalog, the worker refused the fetched bytes, or the
    /// write failed), with the time of the next attempt.
    nonisolated(unsafe) private static var repairRetryAt = [String: Date]()
    /// Folders under repair now: two callers (setup report and plan) never ask the catalog for one folder at once.
    nonisolated(unsafe) private static var repairRunning = Set<String>()

    /// `notAttempted`: the deadline came before the catalog answered; the next pass asks at once.
    private enum RepairOutcome { case settled, retry, notAttempted }

    /// A model cloned in while the catalog did not answer kept the product store's re-encoded receipt as its
    /// manifest; the worker pins the catalog's exact bytes, so the cluster said "not supported" for a verified model
    /// forever (Qwen 3.5 9B, 2026-10-15: the two differed only in `created_at`). When the folder's manifest names
    /// `artifact` (model, version, aggregate and files) but is not bytes the worker takes, the catalog's bytes replace
    /// it, once they name exactly that artifact too (`fetchManifest`) and the worker takes them. Only `manifest.json`
    /// is replaced (atomically); the weight files are never opened. Otherwise the folder is left as it is.
    /// A folder with a definite outcome is not asked again in this process. After a failed attempt (the catalog did
    /// not answer, the worker refused the fetched bytes or the write failed) the next one waits
    /// `ClusterOnboardingUpdate.checkEverySeconds` from `now`, so a fetch that failed once after an update is retried.
    /// After `deadline` the folder is not asked (the next pass asks), and no catalog request waits past it.
    static func repairManifest(_ folder: URL, artifact: ClusterCatalogArtifact, providerConfiguration: URL,
                               environment: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date(),
                               deadline: Date? = nil, accepts: ((Data) -> Bool)? = nil) {
        // Only with the worker's own answer: without it the catalog's two encodings could replace one the worker takes.
        guard let accepts, deadline.map({ Date() < $0 }) ?? true else { return }
        let key = folder.path
        let due: Bool = repairLock.withLock { () -> Bool in
            guard !repairSettled.contains(key), !repairRunning.contains(key), repairRetryAt[key].map({ now >= $0 }) ?? true else { return false }
            repairRunning.insert(key)
            return true
        }
        guard due else { return }
        let outcome = attemptRepair(folder, artifact: artifact, providerConfiguration: providerConfiguration,
                                    environment: environment, deadline: deadline, accepts: accepts)
        repairLock.withLock { () -> Void in
            repairRunning.remove(key)
            switch outcome {
            case .settled: repairSettled.insert(key); repairRetryAt[key] = nil
            case .retry: repairRetryAt[key] = now.addingTimeInterval(ClusterOnboardingUpdate.checkEverySeconds)
            case .notAttempted: break
            }
        }
    }

    private static func attemptRepair(_ folder: URL, artifact: ClusterCatalogArtifact, providerConfiguration: URL,
                                      environment: [String: String], deadline: Date?,
                                      accepts: @escaping (Data) -> Bool) -> RepairOutcome {
        let manifest = folder.appendingPathComponent("manifest.json")
        // A manifest this Mac's worker already takes is left as it is.
        guard let current = ClusterModelStore.readSmall(manifest), !accepts(current),
              let parsed = try? ClusterCatalogArtifact.parse(manifest: current), parsed.sameArtifact(artifact) else { return .settled }
        let exact: Data
        switch catalogAnswer(providerConfiguration: providerConfiguration, artifact: artifact, environment: environment,
                             deadline: deadline, accepts: accepts) {
        case .manifest(let data): exact = data
        case .otherContent: return .settled
        case .unavailable: return deadline.map({ Date() >= $0 }) == true ? .notAttempted : .retry
        }
        guard exact != current else { return .settled }
        guard accepts(exact) else { return .retry }
        var information = stat()
        guard lstat(folder.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR, information.st_uid == geteuid() else { return .settled }
        guard (try? exact.write(to: manifest, options: [.atomic])) != nil else { return .retry }
        _ = chmod(manifest.path, 0o600)
        return .settled
    }

    /// Brings the cluster's store up to date before its models are listed or planned: every product-store model a pair
    /// may serve is cloned in, then every servable folder's manifest is repaired (`repairStoreManifests`). Runs where
    /// each Mac lists its models (its setup report, which also answers the other Mac) and before the leader plans, so
    /// an update needs no hand step. `repairDeadline` bounds the repairs, not the clones: folders left over are
    /// repaired on the next pass.
    static func updateClusterStore(_ store: URL, providerConfiguration: URL, repairDeadline: Date? = nil,
                                   accepts: @escaping (_ manifest: Data, _ folder: URL) -> Bool) {
        let servable = ClusterModelCopyTrust.servableArtifacts
        for model in installed() where servable.contains(model.artifact.aggregateSHA256) {
            _ = try? cloneIntoClusterStore(model, store: store, providerConfiguration: providerConfiguration,
                                           repairDeadline: repairDeadline, accepts: accepts)
        }
        repairStoreManifests(store: store, servable: servable, providerConfiguration: providerConfiguration,
                             deadline: repairDeadline, accepts: accepts)
    }

    /// The same repair for every folder of the cluster's store whose artifact a pair may serve (`servable`), each
    /// against its own manifest. A folder copied over the cable has no product-store receipt here, so clone-in never
    /// repairs it: after the pin change of 2026-10-28 (every registered model pins the CDN's `manifest.json`) this
    /// Mac's worker refuses a copied folder that kept the production coordinator's bytes, and without this repair only
    /// removing the folder by hand would bring the model back.
    static func repairStoreManifests(store: URL, servable: Set<String>, providerConfiguration: URL,
                                     environment: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date(),
                                     deadline: Date? = nil, accepts: @escaping (_ manifest: Data, _ folder: URL) -> Bool) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []).sorted()
        for name in names.prefix(256) where !name.hasPrefix(".") {
            if let deadline, Date() >= deadline { return }
            let folder = store.appendingPathComponent(name)
            guard let data = ClusterModelStore.readSmall(folder.appendingPathComponent("manifest.json")),
                  let held = try? ClusterCatalogArtifact.parse(manifest: data), servable.contains(held.aggregateSHA256) else { continue }
            repairManifest(folder, artifact: held, providerConfiguration: providerConfiguration, environment: environment,
                           now: now, deadline: deadline, accepts: { accepts($0, folder) })
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
