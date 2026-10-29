import Darwin
import Foundation
import DarkbloomClusterProtocol

/// The cluster runtime facts of one signed build (`darkbloom_cluster_runtime_v1`):
/// the digests of the cluster helpers it ships and, for each model, the
/// digests of the capability its own worker describes. A dev release registers
/// them as `cluster_runtime`; the coordinator derives its cluster approvals
/// from them, and a member checks a fetched approval against its own installed
/// files with the same computation. Every digest is computed by the code the
/// member's checks use (`DistributedInstalledFiles.digest`, the worker's
/// `--describe-runtime`, `DistributedInstalledNativeStart.resourcePolicySHA256`).
/// The facts approve nothing by themselves.
public struct ClusterRuntimeApprovalFacts: Equatable, Sendable {
    public static let schema = "darkbloom_cluster_runtime_v1"
    public static let maximumModels = 64
    public static let maximumModelBytes = 128
    /// The canonical form is far smaller; anything larger is refused unread.
    public static let maximumEncodedBytes = 64 * 1024
    /// The longest cluster approval ID the coordinator derives from the facts
    /// (`release/<version>/<model>/s<1|2>`) and registers.
    public static let maximumApprovalIDBytes = 128

    /// One model: what a member's saved setup pins for it.
    public struct Model: Codable, Equatable, Sendable {
        /// The catalog model ID the installed manifest names (`model_id`).
        public let model: String
        /// The capability's `artifactSHA256`, the catalog aggregate.
        public let artifactSHA256: String
        /// SHA-256 of the exact `--describe-runtime` output.
        public let capabilitySHA256: String
        /// The capability's `profileFingerprint`.
        public let profileSHA256: String
        /// `DistributedInstalledNativeStart.resourcePolicySHA256` of the capability.
        public let resourcePolicySHA256: String

        public init(model: String, artifactSHA256: String, capabilitySHA256: String,
                    profileSHA256: String, resourcePolicySHA256: String) {
            self.model = model; self.artifactSHA256 = artifactSHA256; self.capabilitySHA256 = capabilitySHA256
            self.profileSHA256 = profileSHA256; self.resourcePolicySHA256 = resourcePolicySHA256
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case model
            case artifactSHA256 = "artifact_sha256"
            case capabilitySHA256 = "capability_sha256"
            case profileSHA256 = "profile_sha256"
            case resourcePolicySHA256 = "resource_policy_sha256"
        }
        static let fields = Set(CodingKeys.allCases.map(\.rawValue))
    }

    /// SHA-256 of the signed `Contents/Helpers/darkbloom-cluster-worker`.
    public let nativeRuntimeSHA256: String
    /// SHA-256 of `Contents/Helpers/mlx.metallib`.
    public let metallibSHA256: String
    /// SHA-256 of `Contents/Helpers/pagedattention.metal`.
    public let resourceLibrarySHA256: String
    /// SHA-256 of the signed `Contents/Helpers/darkbloom-cluster-plan`.
    public let placementPolicySHA256: String
    /// Sorted by `model` in byte order, unique.
    public let models: [Model]

    public init(nativeRuntimeSHA256: String, metallibSHA256: String, resourceLibrarySHA256: String,
                placementPolicySHA256: String, models: [Model]) throws {
        self.nativeRuntimeSHA256 = nativeRuntimeSHA256; self.metallibSHA256 = metallibSHA256
        self.resourceLibrarySHA256 = resourceLibrarySHA256; self.placementPolicySHA256 = placementPolicySHA256
        self.models = models
        try validate()
    }

    /// The four cluster helper files of one installation.
    public struct Installation: Equatable, Sendable {
        public static let placementToolName = "darkbloom-cluster-plan"
        public static let metallibName = "mlx.metallib"
        public static let resourceLibraryName = "pagedattention.metal"
        public let worker: URL
        public let placementTool: URL
        public let metallib: URL
        public let resourceLibrary: URL

        public init(worker: URL, placementTool: URL, metallib: URL, resourceLibrary: URL) {
            self.worker = worker; self.placementTool = placementTool
            self.metallib = metallib; self.resourceLibrary = resourceLibrary
        }

        /// The helpers of an app bundle, in its `Contents/Helpers`.
        public init(app: URL) {
            let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
            self.init(worker: helpers.appendingPathComponent(ClusterBundledHelpers.workerName),
                      placementTool: helpers.appendingPathComponent(Self.placementToolName),
                      metallib: helpers.appendingPathComponent(Self.metallibName),
                      resourceLibrary: helpers.appendingPathComponent(Self.resourceLibraryName))
        }
    }

    /// One model's metadata files: never its weights.
    public struct ModelFiles: Equatable, Sendable {
        public let configuration: URL
        public let manifest: URL

        public init(configuration: URL, manifest: URL) { self.configuration = configuration; self.manifest = manifest }

        /// `config.json` and `manifest.json` of a model folder.
        public init(directory: URL) {
            self.init(configuration: directory.appendingPathComponent("config.json"),
                      manifest: directory.appendingPathComponent("manifest.json"))
        }
    }

    /// A model a release must describe: a registered model with a cluster
    /// stage adapter and a passing pair qualification record on this artifact.
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

    /// One model as this build's worker describes it.
    public struct Described: Equatable, Sendable {
        public let entry: Model
        public let runtimeModelID: String
    }

    /// The models this build qualifies on a cluster, from its own bundled
    /// qualification records (`ClusterPairServingGrants.records`): the one
    /// source of the release's model list.
    public static var releaseModels: [ReleaseModel] { qualifiedModels(records: ClusterPairServingGrants.records) }

    static func qualifiedModels(records: [ClusterPairQualificationRecord]) -> [ReleaseModel] {
        Set(records.filter {
            $0.isConsistent && $0.outcome == .passed && ClusterPairServingGrants.hasStageAdapter(runtimeModelID: $0.runtimeModelID)
        }.map { ReleaseModel(runtimeModelID: $0.runtimeModelID, artifactSHA256: $0.artifactSHA256) })
            .sorted { ($0.runtimeModelID, $0.artifactSHA256) < ($1.runtimeModelID, $1.artifactSHA256) }
    }

    /// The facts of `installation` for exactly `models`.
    public static func compute(installation: Installation, models: [ModelFiles]) throws -> Self {
        let installed = try HashedInstallation(installation)
        return try installed.facts(models.map { try installed.describe($0).entry })
    }

    /// The qualified models a release may leave out, by runtime model ID with
    /// their catalog model ID, when the build's own worker refuses every
    /// candidate of the model. Until the GLM manifest repin PR lands, then
    /// remove. Fixed in code: no argument or input file adds to it.
    static let softReleaseModels = ["registered_glm53_flash": "glm-5.3-flash"]

    /// A model of `softReleaseModels` that a release left out, and why.
    public struct Omission: Equatable, Sendable {
        /// The catalog model ID.
        public let model: String
        public let runtimeModelID: String
        public let reason: String
    }

    /// The facts a release registers: for every model in `models`, the first
    /// candidate folder with its artifact that the worker describes as that
    /// model. Fails naming every model that has none, and when a model in
    /// `required` (catalog IDs) is not among the result.
    ///
    /// Only a caller that gives `omitted` lets a model of `softReleaseModels`
    /// whose candidates the worker all refused (`DistributedCapabilityProbe.commandFailed`)
    /// be left out: `omitted` receives it once the facts are complete, and a
    /// required model left out so does not fail. Any other failure of that
    /// model (no candidate, a candidate of another model, a file or integrity
    /// refusal) still fails.
    public static func release(installation: Installation, candidates: [ModelFiles], required: [String],
                               models: [ReleaseModel] = ClusterRuntimeApprovalFacts.releaseModels,
                               omitted: ((Omission) -> Void)? = nil) throws -> Self {
        let installed = try HashedInstallation(installation)
        let parsed = try candidates.map { ($0, try catalogArtifact($0)) }
        var entries: [Model] = [], failures: [String] = [], omissions: [Omission] = []
        for listed in models {
            var refusals: [String] = [], workerRefusedAll = true, chosen: Model?
            for (files, artifact) in parsed where artifact.aggregateSHA256 == listed.artifactSHA256 {
                do {
                    let described = try installed.describe(files)
                    if described.runtimeModelID == listed.runtimeModelID { chosen = described.entry; break }
                    refusals.append("\(files.manifest.path) is \(described.runtimeModelID)")
                    workerRefusedAll = false
                } catch {
                    refusals.append("\(files.manifest.path): \(error)")
                    if (error as? ClusterConfigurationError) != DistributedCapabilityProbe.commandFailed { workerRefusedAll = false }
                }
            }
            if let chosen { entries.append(chosen); continue }
            let reason = refusals.isEmpty ? "no candidate folder has this artifact" : refusals.joined(separator: "; ")
            if omitted != nil, !refusals.isEmpty, workerRefusedAll, let model = softReleaseModels[listed.runtimeModelID] {
                omissions.append(Omission(model: model, runtimeModelID: listed.runtimeModelID, reason: reason))
                continue
            }
            failures.append("\(listed.runtimeModelID) (\(listed.artifactSHA256)): " + reason)
        }
        guard failures.isEmpty else {
            throw ClusterConfigurationError.invalid("Qualified cluster models the release cannot describe: " + failures.joined(separator: " | "))
        }
        let names = Set(entries.map(\.model) + omissions.map(\.model))
        let missing = required.filter { !names.contains($0) }
        guard missing.isEmpty else {
            throw ClusterConfigurationError.invalid("The release's cluster models lack required models: " + missing.joined(separator: ", "))
        }
        let facts = try installed.facts(entries)
        omissions.forEach { omitted?($0) }
        return facts
    }

    /// One model's entry, described by `worker` pinned to `workerSHA256`.
    public static func describe(_ files: ModelFiles, worker: URL, workerSHA256: String, deadline: UInt64) throws -> Described {
        let configuration = try canonical(files.configuration), manifest = try canonical(files.manifest)
        let artifact = try catalogArtifact(ModelFiles(configuration: configuration, manifest: manifest))
        guard modelIDIsValid(artifact.modelID) else {
            throw ClusterConfigurationError.invalid("The manifest's model ID is not 1 to \(maximumModelBytes) printable ASCII bytes")
        }
        let bytes = try DistributedCapabilityProbe.run(executable: try canonical(worker), arguments: ["--describe-runtime",
            "--config", configuration.path, "--manifest", manifest.path, "--expected-executable-sha256", workerSHA256],
            deadline: deadline)
        let capability = try ClusterCapabilityRecord.decode(bytes, writtenBy: "the cluster worker \(worker.path)")
        guard capability.runtimeBinarySHA256 == workerSHA256, capability.artifactSHA256 == artifact.aggregateSHA256,
              !capability.hasPrivateImages else {
            throw ClusterConfigurationError.invalid("The worker described another build, artifact or profile than \(manifest.path) names")
        }
        return Described(entry: Model(model: artifact.modelID, artifactSHA256: capability.artifactSHA256,
            capabilitySHA256: ClusterConfigurationCodec.sha256(bytes), profileSHA256: capability.profileFingerprint,
            resourcePolicySHA256: NativePairMemberInstallation.hex(DistributedInstalledNativeStart.resourcePolicySHA256(capability))),
            runtimeModelID: capability.runtimeModelID)
    }

    // MARK: - Canonical form

    private struct Document: Codable {
        let schema: String
        let nativeRuntimeSHA256: String
        let metallibSHA256: String
        let resourceLibrarySHA256: String
        let placementPolicySHA256: String
        let models: [Model]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case schema, models
            case nativeRuntimeSHA256 = "native_runtime_sha256"
            case metallibSHA256 = "metallib_sha256"
            case resourceLibrarySHA256 = "resource_library_sha256"
            case placementPolicySHA256 = "placement_policy_sha256"
        }
        static let fields = Set(CodingKeys.allCases.map(\.rawValue))
    }

    /// The canonical bytes: JSON with sorted keys, no whitespace, no escaped
    /// slashes and no trailing newline.
    public func canonicalBytes() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Document(schema: Self.schema, nativeRuntimeSHA256: nativeRuntimeSHA256,
            metallibSHA256: metallibSHA256, resourceLibrarySHA256: resourceLibrarySHA256,
            placementPolicySHA256: placementPolicySHA256, models: models))
    }

    /// Strict: an unknown, missing or repeated field, another schema, a value outside
    /// the rules or a model whose derived approval ID for `releaseVersion`
    /// exceeds `maximumApprovalIDBytes` is refused.
    public init(canonical data: Data, releaseVersion: String = ProviderCore.version) throws {
        guard data.count <= Self.maximumEncodedBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Document.fields, object["schema"] as? String == Self.schema,
              let models = object["models"] as? [[String: Any]],
              models.allSatisfy({ Set($0.keys) == Model.fields }) else {
            throw ClusterConfigurationError.invalid("Cluster runtime facts have unknown or missing fields or another schema")
        }
        guard !Self.repeatsAKey(data) else {
            throw ClusterConfigurationError.invalid("Cluster runtime facts repeat a field")
        }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw ClusterConfigurationError.invalid("Cluster runtime facts have a field of the wrong type") }
        try self.init(nativeRuntimeSHA256: document.nativeRuntimeSHA256, metallibSHA256: document.metallibSHA256,
                      resourceLibrarySHA256: document.resourceLibrarySHA256,
                      placementPolicySHA256: document.placementPolicySHA256, models: document.models)
        guard models.allSatisfy({ "release/\(releaseVersion)/\($0.model)/s2".utf8.count <= Self.maximumApprovalIDBytes }) else {
            throw ClusterConfigurationError.invalid(
                "A cluster approval ID derived from these facts exceeds \(Self.maximumApprovalIDBytes) bytes")
        }
    }

    /// Every digest 64 lowercase hex and nonzero; 1 to 64 models with valid,
    /// strictly ascending (byte order, so unique) model IDs.
    func validate() throws {
        let digests = [nativeRuntimeSHA256, metallibSHA256, resourceLibrarySHA256, placementPolicySHA256]
            + models.flatMap { [$0.artifactSHA256, $0.capabilitySHA256, $0.profileSHA256, $0.resourcePolicySHA256] }
        guard digests.allSatisfy({ ClusterConfigurationSyntax.hash($0) && $0 != String(repeating: "0", count: 64) }) else {
            throw ClusterConfigurationError.invalid("Cluster runtime facts digests must be 64 lowercase hex characters, not zero")
        }
        guard (1...Self.maximumModels).contains(models.count), models.allSatisfy({ Self.modelIDIsValid($0.model) }) else {
            throw ClusterConfigurationError.invalid("Cluster runtime facts need 1 to \(Self.maximumModels) models with printable ASCII IDs")
        }
        guard zip(models, models.dropFirst()).allSatisfy({ Self.inByteOrder($0, $1) }) else {
            throw ClusterConfigurationError.invalid("Cluster runtime facts models must be sorted by model ID and unique")
        }
    }

    // MARK: - Command-line forms

    /// `ID=DIRECTORY` or `ID=CONFIG,MANIFEST`: a model given by hand. The ID
    /// is checked against the manifest when the model is described.
    public static func modelArgument(_ text: String) throws -> (model: String, files: ModelFiles) {
        let malformed = ClusterConfigurationError.invalid("Expected --model ID=DIRECTORY or ID=CONFIG,MANIFEST")
        let parts = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw malformed }
        let paths = parts[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        switch paths.count {
        case 1: return (parts[0], ModelFiles(directory: URL(fileURLWithPath: paths[0], isDirectory: true)))
        case 2 where !paths[0].isEmpty && !paths[1].isEmpty:
            return (parts[0], ModelFiles(configuration: URL(fileURLWithPath: paths[0]), manifest: URL(fileURLWithPath: paths[1])))
        default: throw malformed
        }
    }

    /// The candidate folders of a release: every subfolder of `directory`, in
    /// name order, each with its `config.json` and `manifest.json`.
    public static func candidates(in directory: URL) throws -> [ModelFiles] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch { throw ClusterConfigurationError.invalid("Cannot list the candidate folder \(directory.path)") }
        return names.filter { !$0.hasPrefix(".") }.sorted().map {
            ModelFiles(directory: directory.appendingPathComponent($0, isDirectory: true))
        }
    }

    // MARK: - Helpers

    /// True when an object in `data` (already parsed as JSON) names one key
    /// twice. Keys compare after unescaping, as a JSON reader sees them.
    private static func repeatsAKey(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var open: [(isObject: Bool, keys: Set<String>)] = [], expectingKey = false, index = 0
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "{"): open.append((true, [])); expectingKey = true
            case UInt8(ascii: "["): open.append((false, [])); expectingKey = false
            case UInt8(ascii: "}"), UInt8(ascii: "]"): _ = open.popLast(); expectingKey = false
            case UInt8(ascii: ","): expectingKey = open.last?.isObject == true
            case UInt8(ascii: "\""):
                let start = index
                index += 1
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                    index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
                }
                guard expectingKey, !open.isEmpty else { break }
                expectingKey = false
                guard index < bytes.count,
                      let key = try? JSONSerialization.jsonObject(with: Data(bytes[start...index]), options: .fragmentsAllowed) as? String,
                      open[open.count - 1].keys.insert(key).inserted else { return true }
            default: break
            }
            index += 1
        }
        return false
    }

    /// An installation's four helpers, each resolved to its real path and
    /// then hashed under the installed-file rules, and the worker that
    /// describes models pinned to the digest just computed.
    private struct HashedInstallation {
        let worker: URL
        let nativeRuntimeSHA256, metallibSHA256, resourceLibrarySHA256, placementPolicySHA256: String

        init(_ installation: Installation) throws {
            let until = ClusterRuntimeApprovalFacts.deadline(seconds: 120)
            let files = try [(installation.worker, true), (installation.metallib, false),
                             (installation.resourceLibrary, false), (installation.placementTool, true)]
                .map { (try ClusterRuntimeApprovalFacts.canonical($0.0), $0.1) }
            let digests = try files.map {
                try DistributedInstalledFiles.digest($0.0, maximumBytes: 256 * 1024 * 1024, executable: $0.1, deadline: until).sha256
            }
            worker = files[0].0
            nativeRuntimeSHA256 = digests[0]; metallibSHA256 = digests[1]
            resourceLibrarySHA256 = digests[2]; placementPolicySHA256 = digests[3]
        }

        func describe(_ files: ModelFiles) throws -> Described {
            try ClusterRuntimeApprovalFacts.describe(files, worker: worker, workerSHA256: nativeRuntimeSHA256,
                                                     deadline: ClusterRuntimeApprovalFacts.deadline(seconds: 30))
        }

        /// The facts of this installation for `models`, in byte order.
        func facts(_ models: [Model]) throws -> ClusterRuntimeApprovalFacts {
            try .init(nativeRuntimeSHA256: nativeRuntimeSHA256, metallibSHA256: metallibSHA256,
                      resourceLibrarySHA256: resourceLibrarySHA256, placementPolicySHA256: placementPolicySHA256,
                      models: models.sorted(by: ClusterRuntimeApprovalFacts.inByteOrder))
        }
    }

    /// The order of `models`: model IDs compared byte by byte.
    private static func inByteOrder(_ first: Model, _ second: Model) -> Bool {
        first.model.utf8.lexicographicallyPrecedes(second.model.utf8)
    }

    /// The catalog identity a model folder's manifest names, bounded and
    /// checked (`ClusterCatalogArtifact.parse`: the aggregate is bound to the
    /// files' digests).
    private static func catalogArtifact(_ files: ModelFiles) throws -> ClusterCatalogArtifact {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: files.manifest)
            defer { try? handle.close() }
            data = try handle.read(upToCount: ClusterCatalogArtifact.maximumManifestBytes + 1) ?? Data()
        } catch { throw ClusterConfigurationError.invalid("Cannot read the manifest \(files.manifest.path)") }
        guard data.count <= ClusterCatalogArtifact.maximumManifestBytes else {
            throw ClusterConfigurationError.invalid("The manifest \(files.manifest.path) exceeds its bound")
        }
        do { return try ClusterCatalogArtifact.parse(manifest: data) }
        catch { throw ClusterConfigurationError.invalid("The manifest \(files.manifest.path) is not a catalog manifest: \(error)") }
    }

    static func modelIDIsValid(_ model: String) -> Bool {
        (1...maximumModelBytes).contains(model.utf8.count) && model.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }

    /// The real path (no link in any component), as the installed-file checks require.
    private static func canonical(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw ClusterConfigurationError.invalid("\(url.path) does not exist")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private static func deadline(seconds: UInt64) -> UInt64 { DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000 }
}
