import Darwin
import Foundation
import DarkbloomClusterProtocol

/// The cluster runtime facts of one app (`darkbloom_cluster_runtime_v2`): the
/// digests of the cluster helpers it ships and, for each model, the digests of
/// the capability its own worker describes, its pair-serving grant and the
/// parity qualifications of a model the owner declared public
/// (`ClusterPublicModels`). A signed release registers them as `cluster_runtime`
/// (the release lane computes them from its final signed app, `release`); a
/// coordinator derives that build's cluster approvals, their grants and their
/// parity qualifications from them. The guided setup takes
/// the served approval whose digests equal this Mac's facts
/// (`ClusterApprovalLifetime.select`), and each member checks it against its
/// own installed files with the same computation. Every digest is computed by
/// the code the member's checks use (`DistributedInstalledFiles.digest`, the
/// worker's `--describe-runtime`, `DistributedInstalledNativeStart.resourcePolicySHA256`).
/// The facts approve nothing by themselves.
public struct ClusterRuntimeApprovalFacts: Equatable, Sendable {
    public static let schema = "darkbloom_cluster_runtime_v2"
    public static let maximumModels = 64
    public static let maximumModelBytes = 128
    /// The canonical form is far smaller; anything larger is refused unread.
    public static let maximumEncodedBytes = 64 * 1024
    /// The longest ID a coordinator derives from the facts of a release and
    /// registers (`derivedIDs`).
    public static let maximumDerivedIDBytes = 128
    /// The members a derived approval admits, so the ranks of a qualification.
    static let derivedApprovalMembers = 2

    /// One model: what a member's saved setup pins for it, its grant and its
    /// public qualifications.
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
        /// The families a coordinator lets a pair of this build serve the
        /// model in: the declared families of a declared model, else the grant
        /// of this build's records for the artifact; nil, written as `null`,
        /// when they grant none.
        public let pairServingGrant: PairServingGrant?
        /// One per declared family and schedule of a declared model
        /// (`parityQualifications`); empty for every other model.
        public let parityQualifications: [ParityQualification]

        public init(model: String, artifactSHA256: String, capabilitySHA256: String, profileSHA256: String,
                    resourcePolicySHA256: String, pairServingGrant: PairServingGrant? = nil,
                    parityQualifications: [ParityQualification] = []) {
            self.model = model; self.artifactSHA256 = artifactSHA256; self.capabilitySHA256 = capabilitySHA256
            self.profileSHA256 = profileSHA256; self.resourcePolicySHA256 = resourcePolicySHA256
            self.pairServingGrant = pairServingGrant; self.parityQualifications = parityQualifications
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case model
            case artifactSHA256 = "artifact_sha256"
            case capabilitySHA256 = "capability_sha256"
            case profileSHA256 = "profile_sha256"
            case resourcePolicySHA256 = "resource_policy_sha256"
            case pairServingGrant = "pair_serving_grant"
            case parityQualifications = "parity_qualifications"
        }
        static let fields = Set(CodingKeys.allCases.map(\.rawValue))

        /// Every member is written: a model without a grant has `"pair_serving_grant":null`.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(artifactSHA256, forKey: .artifactSHA256)
            try container.encode(capabilitySHA256, forKey: .capabilitySHA256)
            try container.encode(profileSHA256, forKey: .profileSHA256)
            try container.encode(resourcePolicySHA256, forKey: .resourcePolicySHA256)
            if let pairServingGrant { try container.encode(pairServingGrant, forKey: .pairServingGrant) }
            else { try container.encodeNil(forKey: .pairServingGrant) }
            try container.encode(parityQualifications, forKey: .parityQualifications)
        }
    }

    /// A model's pair-serving grant as a release names it: the mode families
    /// sorted by byte and the SHA-256 of the evidence they rest on. Without a
    /// grant a coordinator holds each member to the model's single-Mac
    /// requirements, which a member, reporting only hardware capabilities,
    /// does not meet for GLM-5.3-Flash or Qwen3.8-27B.
    public struct PairServingGrant: Codable, Equatable, Sendable {
        public let evidenceSHA256: String
        /// `ClusterPairServingModeFamily` raw values, sorted by byte, unique.
        public let modeFamilies: [String]

        /// As written; `validate` holds the families to the rules.
        public init(evidenceSHA256: String, modeFamilies: [String]) {
            self.evidenceSHA256 = evidenceSHA256; self.modeFamilies = modeFamilies
        }

        /// `families`, sorted by byte and unique.
        public init(evidenceSHA256: String, families: [ClusterPairServingModeFamily]) {
            self.init(evidenceSHA256: evidenceSHA256,
                      modeFamilies: Set(families.map(\.rawValue)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        }

        /// The grant `grant` gives: its families and the digest of the records
        /// it rests on (`ClusterPairServingGrant.evidenceSHA256`).
        public init(_ grant: ClusterPairServingGrant) throws {
            self.init(evidenceSHA256: try grant.evidenceSHA256(), families: grant.families)
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case evidenceSHA256 = "evidence_sha256"
            case modeFamilies = "mode_families"
        }
        static let fields = Set(CodingKeys.allCases.map(\.rawValue))
    }

    /// The statement that one placement of a declared model serves public
    /// traffic (contract D): a coordinator makes it the parity qualification
    /// of the model's derived approval of `schedule`. Its equal shares are
    /// written as `"tensor_parallel_shares":null`.
    public struct ParityQualification: Codable, Equatable, Sendable {
        public let schedule: UInt8
        /// Each rank's numerics class, in rank order.
        public let numericsClasses: [String]
        public let cuts: [Int]
        public let mode: ClusterGenerationMode
        public let promotable: Bool
        public let diverged: Bool
        public let evidenceSHA256: String
        public let qualifiedAt: String
        public let requestEnvelope: ClusterRequestEnvelope

        public init(schedule: UInt8, numericsClasses: [String], cuts: [Int], mode: ClusterGenerationMode, promotable: Bool,
                    diverged: Bool, evidenceSHA256: String, qualifiedAt: String, requestEnvelope: ClusterRequestEnvelope) {
            self.schedule = schedule; self.numericsClasses = numericsClasses; self.cuts = cuts; self.mode = mode
            self.promotable = promotable; self.diverged = diverged; self.evidenceSHA256 = evidenceSHA256
            self.qualifiedAt = qualifiedAt; self.requestEnvelope = requestEnvelope
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case schedule, cuts, mode, promotable, diverged
            case numericsClasses = "numerics_classes"
            case tensorParallelShares = "tensor_parallel_shares"
            case evidenceSHA256 = "evidence_sha256"
            case qualifiedAt = "qualified_at"
            case requestEnvelope = "request_envelope"
        }
        static let fields = Set(CodingKeys.allCases.map(\.rawValue))

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Equal shares only: anything but null is refused.
            guard try container.decodeNil(forKey: .tensorParallelShares) else {
                throw DecodingError.dataCorruptedError(forKey: .tensorParallelShares, in: container,
                                                       debugDescription: "tensor_parallel_shares must be null (equal shares)")
            }
            self.init(schedule: try container.decode(UInt8.self, forKey: .schedule),
                      numericsClasses: try container.decode([String].self, forKey: .numericsClasses),
                      cuts: try container.decode([Int].self, forKey: .cuts),
                      mode: try container.decode(ClusterGenerationMode.self, forKey: .mode),
                      promotable: try container.decode(Bool.self, forKey: .promotable),
                      diverged: try container.decode(Bool.self, forKey: .diverged),
                      evidenceSHA256: try container.decode(String.self, forKey: .evidenceSHA256),
                      qualifiedAt: try container.decode(String.self, forKey: .qualifiedAt),
                      requestEnvelope: try container.decode(ClusterRequestEnvelope.self, forKey: .requestEnvelope))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schedule, forKey: .schedule)
            try container.encode(numericsClasses, forKey: .numericsClasses)
            try container.encode(cuts, forKey: .cuts)
            try container.encode(mode, forKey: .mode)
            try container.encodeNil(forKey: .tensorParallelShares)
            try container.encode(promotable, forKey: .promotable)
            try container.encode(diverged, forKey: .diverged)
            try container.encode(evidenceSHA256, forKey: .evidenceSHA256)
            try container.encode(qualifiedAt, forKey: .qualifiedAt)
            try container.encode(requestEnvelope, forKey: .requestEnvelope)
        }
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
        /// The model's catalog entry as the release lane fetched it
        /// (`catalog.json`: its `id` and `input_modalities`). Nil for a model
        /// given by hand or installed, whose declared request envelope then
        /// admits text only.
        public let catalog: URL?

        public init(configuration: URL, manifest: URL, catalog: URL? = nil) {
            self.configuration = configuration; self.manifest = manifest; self.catalog = catalog
        }

        /// `config.json` and `manifest.json` of a model folder.
        public init(directory: URL) {
            self.init(configuration: directory.appendingPathComponent("config.json"),
                      manifest: directory.appendingPathComponent("manifest.json"))
        }
    }

    /// One model as this build's worker describes it.
    struct Described: Equatable, Sendable {
        let entry: Model
        let runtimeModelID: String
    }

    /// The facts of `installation` for exactly `models`: a model `publicModels`
    /// declare (this build's declaration by default) has the declared grant and
    /// parity qualifications, any other the grant of `decisions` (this build's
    /// bundled records by default).
    public static func compute(installation: Installation, models: [ModelFiles],
                               publicModels: [ClusterPublicModel] = ClusterPublicModels.declared,
                               decisions: ClusterPairServingDecisions = ClusterPairServingGrants.decisions) throws -> Self {
        let installed = try HashedInstallation(installation)
        return try installed.facts(models.map { try installed.describe($0, publicModels: publicModels, decisions: decisions).entry })
    }

    /// One model's entry, described by `worker` pinned to `workerSHA256`.
    static func describe(_ files: ModelFiles, worker: URL, workerSHA256: String, metallibSHA256: String, deadline: UInt64,
                         publicModels: [ClusterPublicModel], decisions: ClusterPairServingDecisions) throws -> Described {
        let configuration = try canonical(files.configuration), manifest = try canonical(files.manifest)
        let artifact = try catalogArtifact(ModelFiles(configuration: configuration, manifest: manifest))
        guard modelIDIsValid(artifact.modelID) else {
            throw ClusterConfigurationError.invalid("The manifest's model ID is not 1 to \(maximumModelBytes) printable ASCII bytes")
        }
        let inputModalities = try files.catalog.map { try catalogInputModalities($0, model: artifact.modelID) } ?? []
        let bytes = try DistributedCapabilityProbe.run(executable: try canonical(worker), arguments: ["--describe-runtime",
            "--config", configuration.path, "--manifest", manifest.path, "--expected-executable-sha256", workerSHA256],
            deadline: deadline)
        let capability = try ClusterCapabilityRecord.decode(bytes, writtenBy: "the cluster worker \(worker.path)")
        guard capability.runtimeBinarySHA256 == workerSHA256, capability.artifactSHA256 == artifact.aggregateSHA256,
              !capability.hasPrivateImages else {
            throw ClusterConfigurationError.invalid("The worker described another build, artifact or profile than \(manifest.path) names")
        }
        let declared = declaration(model: artifact.modelID, runtimeModelID: capability.runtimeModelID,
                                   artifactSHA256: capability.artifactSHA256, publicModels: publicModels)
        let grant: PairServingGrant?
        if let declared {
            grant = PairServingGrant(evidenceSHA256: ClusterPublicModels.evidenceSHA256, families: declared.families)
        } else {
            // The public grant a member of this build reports for the installed artifact (`ClusterPairOwnerServing.publicGrant`).
            grant = try (try? ClusterPairServingGrants.grant(runtimeModelID: capability.runtimeModelID, publicModelID: artifact.modelID,
                artifactSHA256: capability.artifactSHA256, decisions: decisions)).map(PairServingGrant.init)
        }
        return Described(entry: Model(model: artifact.modelID, artifactSHA256: capability.artifactSHA256,
            capabilitySHA256: ClusterConfigurationCodec.sha256(bytes), profileSHA256: capability.profileFingerprint,
            resourcePolicySHA256: NativePairMemberPolicy.hex(DistributedInstalledNativeStart.resourcePolicySHA256(capability)),
            pairServingGrant: grant,
            parityQualifications: declared.map { parityQualifications($0, metallibSHA256: metallibSHA256, inputModalities: inputModalities,
                layers: layerCount(configuration),
                servesMedia: { ClusterModelFeaturePolicy.mediaContract(capability: capability, mode: $0) != nil }) } ?? []),
            runtimeModelID: capability.runtimeModelID)
    }

    /// The declaration of a described model: `publicModels`' entry for its
    /// runtime model, catalog ID and artifact; nil for any other model.
    static func declaration(model: String, runtimeModelID: String, artifactSHA256: String,
                            publicModels: [ClusterPublicModel]) -> ClusterPublicModel? {
        publicModels.first {
            $0.runtimeModelID == runtimeModelID && $0.catalogModelID == model && $0.artifactSHA256 == artifactSHA256
        }
    }

    /// The parity qualifications of a declared model: one per declared family
    /// (byte order: `pipeline`, then `tensor_parallel`) and schedule
    /// (ascending), so each approval's first is the pipeline and its second
    /// tensor parallel. Each is placed as `ClusterPublicModels.placement` says
    /// (a pipeline needs the model's `layers`: without them its records are
    /// left out), its ranks in this build's numerics class, its envelope
    /// admitting media only when its mode `servesMedia` for this model
    /// (`ClusterModelFeaturePolicy.mediaContract`).
    static func parityQualifications(_ declared: ClusterPublicModel, metallibSHA256: String, inputModalities: [String],
                                     layers: Int?, servesMedia: (ClusterGenerationMode) -> Bool) -> [ParityQualification] {
        let classes = numericsClasses(declared.ranks, metallibSHA256: metallibSHA256)
        return declared.families.sorted { $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) }.flatMap { family in
            guard let placement = ClusterPublicModels.placement(of: family, layers: layers, ranks: declared.ranks.count) else {
                return [ParityQualification]()
            }
            let envelope = ClusterPublicModels.requestEnvelope(inputModalities: inputModalities, servesMedia: servesMedia(placement.mode))
            return declared.schedules.sorted().map { schedule in
                ParityQualification(schedule: schedule, numericsClasses: classes, cuts: placement.cuts, mode: placement.mode,
                    promotable: true, diverged: false, evidenceSHA256: ClusterPublicModels.evidenceSHA256,
                    qualifiedAt: ClusterPublicModels.qualifiedAt, requestEnvelope: envelope)
            }
        }
    }

    /// The families a declared model of these facts carries no parity
    /// qualification for (a pipeline whose config gives no layer count); none
    /// for an undeclared model. A declared model is found by its catalog ID and
    /// artifact, which the facts name.
    static func familiesWithoutQualification(_ model: Model, publicModels: [ClusterPublicModel]) -> [ClusterPairServingModeFamily] {
        guard let declared = publicModels.first(where: { $0.catalogModelID == model.model && $0.artifactSHA256 == model.artifactSHA256 })
        else { return [] }
        let qualified = Set(model.parityQualifications.map(\.mode.servingFamily))
        return declared.families.filter { !qualified.contains($0) }
    }

    /// One line for each declared family a model of these facts carries no
    /// parity qualification for: the command prints them, so a release that
    /// leaves one out says so.
    public func unqualifiedDeclaredFamilies(publicModels: [ClusterPublicModel] = ClusterPublicModels.declared) -> [String] {
        models.flatMap { model in
            Self.familiesWithoutQualification(model, publicModels: publicModels).map {
                "\(model.model) carries no parity qualification for its declared \($0.rawValue) family "
                    + "(a pipeline needs num_hidden_layers in config.json)"
            }
        }
    }

    /// Each rank's numerics class on a build whose Metal library is
    /// `metallibSHA256`: what the members register (`ClusterMemberDeviceProfile.numericsClass`).
    static func numericsClasses(_ ranks: ClusterPublicModel.Ranks, metallibSHA256: String) -> [String] {
        let os = OperatingSystemVersion(majorVersion: ranks.macOSMajor, minorVersion: ranks.macOSMinor, patchVersion: 0)
        return Array(repeating: ClusterMemberDeviceProfile.numericsClass(architecture: ranks.gpuArchitecture,
            metallibSHA256: metallibSHA256, os: os), count: ranks.count)
    }

    /// The model's layer count from its config.json: `num_hidden_layers`, at
    /// the top level or in `text_config` (where a model with images keeps its
    /// language model's); nil when neither names a positive count.
    static func layerCount(_ configuration: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: configuration) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ClusterConfigurationFiles.maximumModelConfigurationBytes + 1),
              data.count <= ClusterConfigurationFiles.maximumModelConfigurationBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for source in [object, object["text_config"] as? [String: Any]] {
            if let number = source?["num_hidden_layers"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               let layers = Int(exactly: number.doubleValue), layers > 0 {
                return layers
            }
        }
        return nil
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

    /// Strict: an unknown, missing or repeated field (a model's
    /// `pair_serving_grant` is written, `null` or the grant), another schema, a
    /// value outside the rules or a model whose derived IDs for
    /// `releaseVersion` exceed `maximumDerivedIDBytes` is refused.
    public init(canonical data: Data, releaseVersion: String = ProviderCore.version) throws {
        func object(_ value: Any?, fields: Set<String>) -> [String: Any]? {
            (value as? [String: Any]).flatMap { Set($0.keys) == fields ? $0 : nil }
        }
        guard data.count <= Self.maximumEncodedBytes,
              let top = object(try? JSONSerialization.jsonObject(with: data), fields: Document.fields),
              top["schema"] as? String == Self.schema,
              let entries = top["models"] as? [Any],
              entries.allSatisfy({ entry in
                  guard let model = object(entry, fields: Model.fields),
                        model["pair_serving_grant"] is NSNull || object(model["pair_serving_grant"], fields: PairServingGrant.fields) != nil,
                        let qualifications = model["parity_qualifications"] as? [Any] else { return false }
                  return qualifications.allSatisfy { value in
                      guard let qualification = object(value, fields: ParityQualification.fields) else { return false }
                      return qualification["tensor_parallel_shares"] is NSNull
                          && object(qualification["request_envelope"], fields: ClusterRequestEnvelope.fields) != nil
                  }
              }) else {
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
        guard models.allSatisfy({ Self.derivedIDs($0, releaseVersion: releaseVersion)
            .allSatisfy { $0.utf8.count <= Self.maximumDerivedIDBytes } }) else {
            throw ClusterConfigurationError.invalid("An ID a coordinator derives from these facts exceeds \(Self.maximumDerivedIDBytes) bytes")
        }
    }

    /// The IDs a coordinator derives for `model` from the facts of release
    /// `releaseVersion`: its approvals `release/<version>/<model>/s<1|2>`,
    /// for a model with a grant each approval's `<approval>/grant`, and for
    /// each parity qualification `<its schedule's approval>/q<n>`, n counting
    /// that schedule's qualifications from 1 in block order.
    static func derivedIDs(_ model: Model, releaseVersion: String) -> [String] {
        func approval(_ schedule: UInt8) -> String { "release/\(releaseVersion)/\(model.model)/s\(schedule)" }
        let approvals = [approval(1), approval(2)]
        var counts: [UInt8: Int] = [:]
        return approvals + (model.pairServingGrant == nil ? [] : approvals.map { $0 + "/grant" })
            + model.parityQualifications.map { qualification in
                counts[qualification.schedule, default: 0] += 1
                return approval(qualification.schedule) + "/q\(counts[qualification.schedule]!)"
            }
    }

    /// Every digest 64 lowercase hex and nonzero; 1 to 64 models with valid,
    /// strictly ascending (byte order, so unique) model IDs; each grant with 1
    /// to 4 known mode families in byte order; every parity qualification as
    /// a coordinator validates one.
    func validate() throws {
        let digests = [nativeRuntimeSHA256, metallibSHA256, resourceLibrarySHA256, placementPolicySHA256]
            + models.flatMap { [$0.artifactSHA256, $0.capabilitySHA256, $0.profileSHA256, $0.resourcePolicySHA256] }
            + models.compactMap(\.pairServingGrant?.evidenceSHA256)
            + models.flatMap { $0.parityQualifications.map(\.evidenceSHA256) }
        guard digests.allSatisfy({ ClusterConfigurationSyntax.hash($0) && $0 != String(repeating: "0", count: 64) }) else {
            throw ClusterConfigurationError.invalid("Cluster runtime facts digests must be 64 lowercase hex characters, not zero")
        }
        guard (1...Self.maximumModels).contains(models.count), models.allSatisfy({ Self.modelIDIsValid($0.model) }) else {
            throw ClusterConfigurationError.invalid("Cluster runtime facts need 1 to \(Self.maximumModels) models with printable ASCII IDs")
        }
        guard zip(models, models.dropFirst()).allSatisfy({ Self.inByteOrder($0, $1) }) else {
            throw ClusterConfigurationError.invalid("Cluster runtime facts models must be sorted by model ID and unique")
        }
        let known = Set(ClusterPairServingModeFamily.allCases.map(\.rawValue))
        guard models.compactMap(\.pairServingGrant).allSatisfy({ grant in
            !grant.modeFamilies.isEmpty && grant.modeFamilies.allSatisfy(known.contains)
                && zip(grant.modeFamilies, grant.modeFamilies.dropFirst()).allSatisfy { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }) else {
            throw ClusterConfigurationError.invalid("A pair-serving grant names 1 to \(known.count) known mode families, sorted by byte and unique")
        }
        for model in models {
            try Self.validate(model.parityQualifications, of: model.model)
        }
    }

    /// A model's parity qualifications as a coordinator validates them for its
    /// derived approvals (two members each): schedule 1 or 2, one numerics
    /// class per member, the cuts the mode has, never diverged and promotable,
    /// an RFC 3339 `qualified_at`, an envelope of 1 to `ClusterPublicModels.maximumTokens`
    /// tokens with video only with vision, and no placement twice.
    static func validate(_ qualifications: [ParityQualification], of model: String) throws {
        let refuse = { (rule: String) in ClusterConfigurationError.invalid("A parity qualification of \(model) \(rule)") }
        guard qualifications.count <= 2 * ClusterPairServingModeFamily.allCases.count else { throw refuse("is one too many") }
        for (index, q) in qualifications.enumerated() {
            guard [1, 2].contains(q.schedule) else { throw refuse("names schedule \(q.schedule), not 1 or 2") }
            guard q.numericsClasses.count == derivedApprovalMembers, q.numericsClasses.allSatisfy({
                (1...64).contains($0.utf8.count) && $0.utf8.allSatisfy { (0x21...0x7E).contains($0) }
            }) else { throw refuse("needs one numerics class of 1 to 64 printable ASCII bytes per member") }
            guard q.cuts.count == q.mode.layerCutCount(ranks: q.numericsClasses.count), q.cuts.allSatisfy({ $0 > 0 }),
                  zip(q.cuts, q.cuts.dropFirst()).allSatisfy({ $0 < $1 }) else {
                throw refuse("needs the cuts its mode has, positive and ascending")
            }
            guard !(q.diverged && q.promotable) else { throw refuse("is diverged and promotable") }
            guard ClusterPairApproval.unixNanoseconds(rfc3339: q.qualifiedAt) != nil else {
                throw refuse("has a qualified_at that is not an RFC 3339 instant")
            }
            let envelope = q.requestEnvelope, bounds = 1...ClusterPublicModels.maximumTokens
            guard bounds.contains(envelope.maxPromptTokens), bounds.contains(envelope.maxOutputTokens),
                  !envelope.video || envelope.vision else {
                throw refuse("needs token bounds of 1 to \(ClusterPublicModels.maximumTokens) and vision for video")
            }
            guard !qualifications[..<index].contains(where: {
                $0.schedule == q.schedule && $0.mode == q.mode && $0.numericsClasses == q.numericsClasses && $0.cuts == q.cuts
            }) else { throw refuse("repeats a placement") }
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

    // MARK: - Helpers

    /// The `input_modalities` of the catalog entry fetched with a model
    /// (`{"id":…,"input_modalities":[…]}`, the entry of `model`).
    static func catalogInputModalities(_ url: URL, model: String) throws -> [String] {
        let refused = ClusterConfigurationError.invalid("The catalog entry \(url.path) is not the entry of \(model) with its input modalities")
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: try canonical(url))
            defer { try? handle.close() }
            data = try handle.read(upToCount: 4097) ?? Data()
        } catch { throw refused }
        guard data.count <= 4096, let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(entry.keys) == ["id", "input_modalities"], entry["id"] as? String == model,
              let modalities = entry["input_modalities"] as? [String], modalities.count <= 16,
              modalities.allSatisfy({ (1...32).contains($0.utf8.count) && $0.utf8.allSatisfy { (0x21...0x7E).contains($0) } })
        else { throw refused }
        return modalities
    }

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
    struct HashedInstallation {
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

        func describe(_ files: ModelFiles, publicModels: [ClusterPublicModel], decisions: ClusterPairServingDecisions) throws -> Described {
            try ClusterRuntimeApprovalFacts.describe(files, worker: worker, workerSHA256: nativeRuntimeSHA256,
                metallibSHA256: metallibSHA256, deadline: ClusterRuntimeApprovalFacts.deadline(seconds: 30),
                publicModels: publicModels, decisions: decisions)
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
    static func catalogArtifact(_ files: ModelFiles) throws -> ClusterCatalogArtifact {
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
