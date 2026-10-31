import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
@testable import ProviderCore

/// The cluster runtime facts a release registers and the guided setup matches. The capability bytes are
/// the runtime catalog's real description of the pinned Qwen3.5-9B and MiMo
/// metadata fixtures; a shell child stands in for the worker process at the
/// process seam and prints them. No model, GPU or network.
@Suite("Cluster runtime approval facts")
struct ClusterRuntimeApprovalFactsTests {
    static let qwenArtifact = "127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b"
    /// The release version the decoder rows name (`init(canonical:releaseVersion:)`).
    static let releaseVersion = "1.2.3"

    @Test func everyDigestIsTheOneTheMembersChecksCompare() throws {
        let f = try Fixture()
        let model = try f.model("qwen")
        let facts = try ClusterRuntimeApprovalFacts.compute(installation: f.installation, models: [.init(directory: model)])
        // The member's verifyInstalledFiles: native executable, metallib and
        // resource library each verified against the approval's digest.
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        _ = try DistributedInstalledFiles.verify(f.installation.worker, expectedSHA256: facts.nativeRuntimeSHA256,
            maximumBytes: 256 << 20, executable: true, deadline: deadline)
        _ = try DistributedInstalledFiles.verify(f.installation.metallib, expectedSHA256: facts.metallibSHA256,
            maximumBytes: 256 << 20, deadline: deadline)
        _ = try DistributedInstalledFiles.verify(f.installation.resourceLibrary, expectedSHA256: facts.resourceLibrarySHA256,
            maximumBytes: 256 << 20, deadline: deadline)
        #expect(facts.placementPolicySHA256 == f.digest(f.installation.placementTool))
        // Four different files: a digest taken from the wrong one fails above.
        #expect(Set([facts.nativeRuntimeSHA256, facts.metallibSHA256, facts.resourceLibrarySHA256,
                     facts.placementPolicySHA256]).count == 4)

        // The setup's pins the attachment's validate compares, and the
        // capability digest the installed probe compares.
        let bytes = try Data(contentsOf: model.appendingPathComponent("capability.out"))
        let capability = try ClusterRuntimeCapabilityCodec.decode(bytes)
        let entry = try #require(facts.models.first)
        #expect(facts.models.count == 1)
        #expect(entry.model == "Qwen3.5-9B")
        #expect(entry.artifactSHA256 == Self.qwenArtifact && entry.artifactSHA256 == capability.artifactSHA256)
        #expect(entry.capabilitySHA256 == ClusterConfigurationCodec.sha256(bytes))
        #expect(entry.profileSHA256 == capability.profileFingerprint)
        #expect(capability.runtimeBinarySHA256 == facts.nativeRuntimeSHA256)
        // The native start's resource policy over this capability.
        let fields = ["darkbloom/installed-resource-policy/v1", capability.arithmeticPolicyID,
                      capability.arithmeticPolicySHA256, capability.stateSemantics, capability.schedulingPolicy]
        #expect(entry.resourcePolicySHA256 == ClusterConfigurationCodec.sha256(Data(fields.joined(separator: "\u{1F}").utf8)))
        #expect(entry.resourcePolicySHA256 == NativePairMemberPolicy.hex(DistributedInstalledNativeStart.resourcePolicySHA256(capability)))

        // The worker ran its metadata command with the hash just computed.
        let configuration = try f.real(model.appendingPathComponent("config.json"))
        let manifest = try f.real(model.appendingPathComponent("manifest.json"))
        #expect(try f.calls() == ["--describe-runtime --config \(configuration) --manifest \(manifest) --expected-executable-sha256 \(facts.nativeRuntimeSHA256)"])
    }

    @Test func canonicalBytesRoundTripAndAreSortedWithoutWhitespace() throws {
        let facts = try Self.facts()
        let bytes = try facts.canonicalBytes()
        func h(_ seed: Character) -> String { String(repeating: seed, count: 64) }
        func model(_ name: String, _ seed: Character, _ grant: String) -> String {
            #"{"artifact_sha256":"\#(h(seed))","capability_sha256":"\#(h("c"))","model":"\#(name)","pair_serving_grant":\#(grant),"#
                + #""profile_sha256":"\#(h("d"))","resource_policy_sha256":"\#(h("e"))"}"#
        }
        let grant = #"{"evidence_sha256":"\#(h("f"))","mode_families":["pipeline","tensor_parallel"]}"#
        // Keys in byte order at every level, a model without a grant written as null, no whitespace,
        // no escaped slash and no trailing newline.
        let golden = #"{"metallib_sha256":"\#(h("2"))","models":["#
            + [model("EigenLabs/Qwen3.8-27B-4bit-mtp", "5", grant), model("Qwen3.5-9B", "6", "null"),
               model("glm-5.3-flash", "7", "null")].joined(separator: ",")
            + #"],"native_runtime_sha256":"\#(h("1"))","placement_policy_sha256":"\#(h("4"))","#
            + #""resource_library_sha256":"\#(h("3"))","schema":"darkbloom_cluster_runtime_v2"}"#
        #expect(String(decoding: bytes, as: UTF8.self) == golden)
        let decoded = try ClusterRuntimeApprovalFacts(canonical: bytes, releaseVersion: Self.releaseVersion)
        #expect(decoded == facts)
        #expect(try decoded.canonicalBytes() == bytes)
    }

    @Test func decoderRefusesUnknownMissingOrMistypedFields() throws {
        let object = try JSONSerialization.jsonObject(with: Self.facts().canonicalBytes()) as! [String: Any]
        var rows: [String: Any] = [:]
        func edited(_ change: (inout [String: Any]) -> Void) -> [String: Any] { var copy = object; change(&copy); return copy }
        func editedModel(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            edited { block in var models = block["models"] as! [[String: Any]]; change(&models[0]); block["models"] = models }
        }
        func editedGrant(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            editedModel { model in var grant = model["pair_serving_grant"] as! [String: Any]; change(&grant); model["pair_serving_grant"] = grant }
        }
        rows["unknown field"] = edited { $0["extra"] = 1 }
        rows["missing field"] = edited { $0.removeValue(forKey: "placement_policy_sha256") }
        rows["schema v1"] = edited { $0["schema"] = "darkbloom_cluster_runtime_v1" }
        rows["unknown model field"] = editedModel { $0["extra"] = 1 }
        rows["missing model field"] = editedModel { $0.removeValue(forKey: "profile_sha256") }
        rows["absent grant, not null"] = editedModel { $0.removeValue(forKey: "pair_serving_grant") }
        rows["grant a string"] = editedModel { $0["pair_serving_grant"] = "pipeline" }
        rows["grant a list"] = editedModel { $0["pair_serving_grant"] = ["pipeline"] }
        rows["unknown grant field"] = editedGrant { $0["extra"] = 1 }
        rows["missing grant field"] = editedGrant { $0.removeValue(forKey: "mode_families") }
        rows["families not a list"] = editedGrant { $0["mode_families"] = "pipeline" }
        rows["evidence mistyped"] = editedGrant { $0["evidence_sha256"] = 7 }
        rows["mistyped digest"] = edited { $0["metallib_sha256"] = 7 }
        rows["models not a list"] = edited { $0["models"] = [:] as [String: Any] }
        for (label, value) in rows {
            let data = try JSONSerialization.data(withJSONObject: value)
            #expect(throws: ClusterConfigurationError.self, "\(label)") { try ClusterRuntimeApprovalFacts(canonical: data, releaseVersion: Self.releaseVersion) }
        }
        // A repeated key, also one spelled with an escape, at the top, in a model or in a grant.
        let text = String(decoding: try Self.facts().canonicalBytes(), as: UTF8.self)
        for (label, repeated) in [
            ("top", text.replacingOccurrences(of: #"{"metallib_sha256":"#,
                                              with: #"{"schema":"darkbloom_cluster_runtime_v2","metallib_sha256":"#)),
            ("escaped", text.replacingOccurrences(of: #"{"metallib_sha256":"#,
                                                  with: #"{"sch\u0065ma":"darkbloom_cluster_runtime_v2","metallib_sha256":"#)),
            ("model", text.replacingOccurrences(of: #"[{"artifact_sha256":"#, with: #"[{"model":"Z","artifact_sha256":"#)),
            ("grant", text.replacingOccurrences(of: #"{"evidence_sha256":"#, with: #"{"mode_families":["pipeline"],"evidence_sha256":"#)),
        ] {
            #expect(repeated != text, "\(label)")
            #expect(throws: ClusterConfigurationError.self, "\(label)") { try ClusterRuntimeApprovalFacts(canonical: Data(repeated.utf8), releaseVersion: Self.releaseVersion) }
        }
        for data in [Data("{".utf8), Data("[]".utf8), Data(repeating: 32, count: ClusterRuntimeApprovalFacts.maximumEncodedBytes + 1)] {
            #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: data, releaseVersion: Self.releaseVersion) }
        }
    }

    @Test func decoderRefusesFactsWhoseDerivedIDsExceedTheirBound() throws {
        // release/1.2.3/<model>/s2: 17 bytes plus the model ID; a granted model's grant adds "/grant".
        func block(_ model: String, granted: Bool) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: Self.facts().canonicalBytes()) as! [String: Any]
            var models = object["models"] as! [[String: Any]]
            models = [models[0]]; models[0]["model"] = model
            if !granted { models[0]["pair_serving_grant"] = NSNull() }
            object["models"] = models
            return try JSONSerialization.data(withJSONObject: object)
        }
        func m(_ count: Int) -> String { String(repeating: "m", count: count) }
        #expect("release/1.2.3/\(m(111))/s2".utf8.count == ClusterRuntimeApprovalFacts.maximumDerivedIDBytes)
        #expect(try ClusterRuntimeApprovalFacts(canonical: block(m(111), granted: false), releaseVersion: "1.2.3").models.map(\.model) == [m(111)])
        #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: block(m(112), granted: false), releaseVersion: "1.2.3") }
        _ = try ClusterRuntimeApprovalFacts(canonical: block(m(105), granted: true), releaseVersion: "1.2.3")
        #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: block(m(106), granted: true), releaseVersion: "1.2.3") }
        // The bound follows the version the caller names: a dev release version
        // (30 bytes of ID before the model) leaves 98 bytes, or 92 with a grant.
        let dev = "1.2.3-dev.branch.7"
        _ = try ClusterRuntimeApprovalFacts(canonical: block(m(98), granted: false), releaseVersion: dev)
        #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: block(m(99), granted: false), releaseVersion: dev) }
        _ = try ClusterRuntimeApprovalFacts(canonical: block(m(92), granted: true), releaseVersion: dev)
        #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: block(m(93), granted: true), releaseVersion: dev) }
    }

    @Test func rulesRefuseDigestsCountsOrderAndModelIDs() throws {
        let facts = try Self.facts(), good = facts.models
        func make(models: [ClusterRuntimeApprovalFacts.Model] = good, native: String? = nil) throws -> ClusterRuntimeApprovalFacts {
            try .init(nativeRuntimeSHA256: native ?? facts.nativeRuntimeSHA256, metallibSHA256: facts.metallibSHA256,
                      resourceLibrarySHA256: facts.resourceLibrarySHA256, placementPolicySHA256: facts.placementPolicySHA256,
                      models: models)
        }
        func named(_ name: String, _ base: ClusterRuntimeApprovalFacts.Model = good[0],
                   grant: ClusterRuntimeApprovalFacts.PairServingGrant? = nil) -> ClusterRuntimeApprovalFacts.Model {
            .init(model: name, artifactSHA256: base.artifactSHA256, capabilitySHA256: base.capabilitySHA256,
                  profileSHA256: base.profileSHA256, resourcePolicySHA256: base.resourcePolicySHA256, pairServingGrant: grant)
        }
        func granted(_ families: [String], evidence: String = String(repeating: "f", count: 64)) -> ClusterRuntimeApprovalFacts.Model {
            named("a", grant: .init(evidenceSHA256: evidence, modeFamilies: families))
        }
        let zero = String(repeating: "0", count: 64)
        let rows: [(String, () throws -> ClusterRuntimeApprovalFacts)] = [
            ("zero digest", { try make(native: zero) }),
            ("uppercase digest", { try make(native: String(repeating: "A", count: 64)) }),
            ("short digest", { try make(native: String(repeating: "a", count: 63)) }),
            ("zero model digest", { try make(models: [.init(model: "a", artifactSHA256: zero, capabilitySHA256: good[0].capabilitySHA256,
                profileSHA256: good[0].profileSHA256, resourcePolicySHA256: good[0].resourcePolicySHA256)]) }),
            ("no models", { try make(models: []) }),
            ("too many models", { try make(models: (0..<65).map { named(String(format: "m%02d", $0)) }) }),
            ("unsorted", { try make(models: Array(good.reversed())) }),
            ("repeated", { try make(models: [good[0], good[0]]) }),
            ("empty ID", { try make(models: [named("")]) }),
            ("long ID", { try make(models: [named(String(repeating: "a", count: 129))]) }),
            ("non-ASCII ID", { try make(models: [named("Qwen\u{e9}")]) }),
            ("control byte ID", { try make(models: [named("a\n")]) }),
            ("no mode family", { try make(models: [granted([])]) }),
            ("unknown mode family", { try make(models: [granted(["pipeline_mtp"])]) }),
            ("mode families unsorted", { try make(models: [granted(["tensor_parallel", "pipeline"])]) }),
            ("mode family repeated", { try make(models: [granted(["pipeline", "pipeline"])]) }),
            ("zero evidence", { try make(models: [granted(["pipeline"], evidence: zero)]) }),
            ("uppercase evidence", { try make(models: [granted(["pipeline"], evidence: String(repeating: "F", count: 64))]) }),
        ]
        for (label, row) in rows {
            #expect(throws: ClusterConfigurationError.self, "\(label)") { _ = try row() }
        }
        // The bounds themselves are accepted, in byte order (uppercase first).
        _ = try make(models: (0..<64).map { named(String(format: "m%02d", $0)) })
        _ = try make(models: [named(" " + String(repeating: "~", count: 127))])
        _ = try make(models: [named("Z"), named("a")])
        // Every family, in byte order ("pipeline" before its own prefix extension).
        _ = try make(models: [granted(["hand_off", "pipeline", "pipeline_speculative", "tensor_parallel"])])
    }

    @Test func describingRefusesMissingUnsafeOrForeignInputs() throws {
        let f = try Fixture()
        let model = try f.model("qwen")
        let files = ClusterRuntimeApprovalFacts.ModelFiles(directory: model)
        func compute(_ installation: ClusterRuntimeApprovalFacts.Installation? = nil,
                     _ models: [ClusterRuntimeApprovalFacts.ModelFiles]? = nil) throws {
            _ = try ClusterRuntimeApprovalFacts.compute(installation: installation ?? f.installation, models: models ?? [files])
        }
        let missing = f.root.appendingPathComponent("missing")
        for installation in [
            ClusterRuntimeApprovalFacts.Installation(worker: missing, placementTool: f.installation.placementTool,
                metallib: f.installation.metallib, resourceLibrary: f.installation.resourceLibrary),
            ClusterRuntimeApprovalFacts.Installation(worker: f.installation.worker, placementTool: missing,
                metallib: f.installation.metallib, resourceLibrary: f.installation.resourceLibrary),
            ClusterRuntimeApprovalFacts.Installation(worker: f.installation.worker, placementTool: f.installation.placementTool,
                metallib: missing, resourceLibrary: f.installation.resourceLibrary),
            ClusterRuntimeApprovalFacts.Installation(worker: f.installation.worker, placementTool: f.installation.placementTool,
                metallib: f.installation.metallib, resourceLibrary: missing),
        ] {
            #expect(throws: ClusterConfigurationError.self) { try compute(installation) }
        }
        #expect(throws: ClusterConfigurationError.self) { try compute(nil, [.init(configuration: files.configuration, manifest: missing)]) }
        #expect(throws: ClusterConfigurationError.self) { try compute(nil, [.init(configuration: missing, manifest: files.manifest)]) }

        // A file the member would refuse (writable by others) is refused here too.
        try f.chmod(f.installation.metallib, 0o666)
        #expect(throws: ClusterConfigurationError.self) { try compute() }
        try f.chmod(f.installation.metallib, 0o644)
        try f.chmod(f.installation.worker, 0o644)
        #expect(throws: ClusterConfigurationError.self) { try compute() }
        try f.chmod(f.installation.worker, 0o755)

        // The worker refuses the files (non-zero exit) or prints no capability.
        try Data().write(to: model.appendingPathComponent("refuse"))
        #expect(throws: ClusterConfigurationError.self) { try compute() }
        try FileManager.default.removeItem(at: model.appendingPathComponent("refuse"))
        let good = try Data(contentsOf: model.appendingPathComponent("capability.out"))
        try Data("not a capability".utf8).write(to: model.appendingPathComponent("capability.out"))
        #expect(throws: ClusterConfigurationError.self) { try compute() }
        try good.write(to: model.appendingPathComponent("capability.out"))
        _ = try ClusterRuntimeApprovalFacts.compute(installation: f.installation, models: [files])
    }

    @Test func describingRefusesAnotherBuildArtifactProfileOrManifest() throws {
        let f = try Fixture()
        let rows: [(String, () throws -> URL)] = [
            ("another worker build", { try f.model("build", workerSHA256: String(repeating: "e", count: 64)) }),
            ("another artifact", { try f.model("artifact", capabilityFixture: "registered-qwen38-27b") }),
            ("private images", { try f.model("images", fixture: "registered-mimo-v26-flash-mopd", imageCandidate: true) }),
            ("manifest not a catalog manifest", { try f.model("garbage", manifest: Data("{}".utf8)) }),
            ("manifest over its bound", { try f.model("large", manifest: Data(repeating: 32, count: (1 << 20) + 1)) }),
            ("model ID too long", { try f.model("long", modelID: String(repeating: "q", count: 129)) }),
        ]
        for (label, row) in rows {
            let model = try row()
            #expect(throws: ClusterConfigurationError.self, "\(label)") {
                _ = try ClusterRuntimeApprovalFacts.compute(installation: f.installation, models: [.init(directory: model)])
            }
        }
    }

    @Test func commandLineFormsParseOrRefuse() throws {
        let directory = try ClusterRuntimeApprovalFacts.modelArgument("Qwen3.5-9B=/models/qwen")
        #expect(directory.model == "Qwen3.5-9B")
        #expect(directory.files == .init(directory: URL(fileURLWithPath: "/models/qwen", isDirectory: true)))
        let pair = try ClusterRuntimeApprovalFacts.modelArgument("glm-5.3-flash=/m/config.json,/m/manifest.json")
        #expect(pair.files == .init(configuration: URL(fileURLWithPath: "/m/config.json"), manifest: URL(fileURLWithPath: "/m/manifest.json")))
        for text in ["no-equals", "=/m", "id=", "id=/a,", "id=,/b", "id=/a,/b,/c"] {
            #expect(throws: ClusterConfigurationError.self, "\(text)") { _ = try ClusterRuntimeApprovalFacts.modelArgument(text) }
        }

        let f = try Fixture()
        let folder = f.root.appendingPathComponent("listing", isDirectory: true)
        for name in ["b", "a", ".hidden"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(try ClusterRuntimeApprovalFacts.candidates(in: folder).map { $0.manifest.deletingLastPathComponent().lastPathComponent } == ["a", "b"])
        #expect(throws: ClusterConfigurationError.self) { _ = try ClusterRuntimeApprovalFacts.candidates(in: f.root.appendingPathComponent("none")) }
    }

    @Test func grantIsThePublicGrantOfTheDescribedArtifactWithTheDigestOfItsRecords() throws {
        let f = try Fixture()
        let model = try f.model("qwen")
        let qwen = ClusterPairServingGrants.records.filter { $0.runtimeModelID == "registered_qwen35_9b" && $0.outcome == .passed }
        let pipeline = try #require(qwen.first { $0.mode == .pipeline })
        let tensor = try #require(qwen.first { $0.mode == .tensorParallel })
        // Another artifact of the same model, and a divergence of exactly the pipeline record's shape.
        let otherArtifact = try Self.record(pipeline) { $0["artifactSHA256"] = String(repeating: "e", count: 64) }
        let diverged = try Self.record(pipeline) { object in
            var comparisons = object["comparisons"] as! [[String: Any]]
            comparisons[0]["verdict"] = "diverged"; comparisons[0].removeValue(forKey: "gapInULPs")
            object["comparisons"] = comparisons; object["passed"] = false
        }
        func grant(_ records: [ClusterPairQualificationRecord]) throws -> ClusterRuntimeApprovalFacts.PairServingGrant? {
            try #require(ClusterRuntimeApprovalFacts.compute(installation: f.installation, models: [.init(directory: model)],
                decisions: ClusterPairServingDecisions(records: records)).models.first).pairServingGrant
        }
        // The passing records of the described artifact, in the order given, canonical, joined by "\n".
        let pipelineLine = try pipeline.encodedLine(), tensorLine = try tensor.encodedLine()
        #expect(try grant([tensor, otherArtifact, pipeline])
                == .init(evidenceSHA256: Self.sha256(tensorLine + "\n" + pipelineLine), modeFamilies: ["pipeline", "tensor_parallel"]))
        #expect(try grant([pipeline]) == .init(evidenceSHA256: Self.sha256(pipelineLine), modeFamilies: ["pipeline"]))
        // No record of this artifact, or a pass that a divergence of the same shape contradicts: no grant.
        #expect(try grant([]) == nil)
        #expect(try grant([otherArtifact]) == nil)
        #expect(try grant([pipeline, diverged]) == nil)
        #expect(try grant([pipeline, diverged, tensor]) == .init(evidenceSHA256: Self.sha256(tensorLine), modeFamilies: ["tensor_parallel"]))
        // By default the build's own bundled records: the grant a member of this build reports.
        let bundled = try #require(ClusterRuntimeApprovalFacts.compute(installation: f.installation, models: [.init(directory: model)]).models.first)
        let own = try ClusterRuntimeApprovalFacts.PairServingGrant(ClusterPairServingGrants.grant(runtimeModelID: "registered_qwen35_9b",
            publicModelID: "Qwen3.5-9B", artifactSHA256: Self.qwenArtifact))
        #expect(bundled.pairServingGrant == own)
        #expect(own.modeFamilies == ["hand_off", "pipeline", "pipeline_speculative", "tensor_parallel"])
    }

    @Test func bundledRecordLinesAreTheirCanonicalEncoding() throws {
        // So an evidence digest can be recomputed from the bundle's own lines.
        let lines = ClusterPairQualificationRecordsBundled.jsonLines.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let records = try ClusterPairQualificationRecord.decodeLines(ClusterPairQualificationRecordsBundled.jsonLines)
        #expect(!records.isEmpty && records.count == lines.count)
        for (line, record) in zip(lines, records) { #expect(try record.encodedLine() == line) }
    }

    @Test func releaseChoosesTheCandidateTheWorkerDescribesAsEachListedModel() throws {
        let f = try Fixture()
        let candidates = f.root.appendingPathComponent("candidates", isDirectory: true)
        _ = try f.model("0-refused", parent: candidates, refused: true)
        _ = try f.model("1-accepted", parent: candidates)
        _ = try f.model("2-later", parent: candidates)
        let listed = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact)
        let facts = try ClusterRuntimeApprovalFacts.release(installation: f.installation,
            candidates: try ClusterRuntimeApprovalFacts.candidates(in: candidates), models: [listed])
        #expect(facts.models.map(\.model) == ["Qwen3.5-9B"])
        #expect(facts.models.first?.pairServingGrant != nil)
        // The refused candidate was tried, the accepted one chosen, the rest not run.
        #expect(try f.calls().count == 2)
        #expect(try f.calls().last?.contains("1-accepted") == true)
    }

    @Test func releaseDescribesEveryCatalogIDOfAListedArtifactAndNothingElse() throws {
        let f = try Fixture()
        let candidates = f.root.appendingPathComponent("candidates", isDirectory: true)
        _ = try f.model("0-qwen", parent: candidates)
        _ = try f.model("1-copy", parent: candidates, modelID: "Qwen3.5-9B-copy")
        _ = try f.model("2-unlisted", parent: candidates, fixture: "registered-qwen38-27b")
        let qwen = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact)
        // Listed, but the environment's catalog does not have it: no candidate, left out.
        let absent = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_glm53_flash",
                                                              artifactSHA256: ClusterGLMImageCandidate.artifactSHA256)
        let facts = try ClusterRuntimeApprovalFacts.release(installation: f.installation,
            candidates: try ClusterRuntimeApprovalFacts.candidates(in: candidates), models: [qwen, absent])
        #expect(facts.models.map(\.model) == ["Qwen3.5-9B", "Qwen3.5-9B-copy"])
        // A candidate of an artifact the build does not list is never described.
        #expect(try f.calls().count == 2)
        #expect(try !f.calls().contains { $0.contains("2-unlisted") })
    }

    @Test func releaseNamesEveryCatalogModelItCannotDescribeAndRefusesAnEmptyResult() throws {
        let f = try Fixture()
        let candidates = f.root.appendingPathComponent("candidates", isDirectory: true)
        _ = try f.model("refused", parent: candidates, refused: true)
        let qwen = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact)
        func message(_ models: [ClusterRuntimeApprovalFacts.ReleaseModel]) -> String {
            do {
                _ = try ClusterRuntimeApprovalFacts.release(installation: f.installation,
                    candidates: try ClusterRuntimeApprovalFacts.candidates(in: candidates), models: models)
                return ""
            } catch { return String(describing: error) }
        }
        let refused = message([qwen])
        #expect(refused.contains("Qwen3.5-9B (registered_qwen35_9b, \(Self.qwenArtifact))") && refused.contains("refused/manifest.json"))

        _ = try f.model("accepted", parent: candidates)
        let another = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_other", artifactSHA256: Self.qwenArtifact)
        #expect(message([another]).contains("is registered_qwen35_9b"))
        let absent = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_glm53_flash",
                                                              artifactSHA256: ClusterGLMImageCandidate.artifactSHA256)
        #expect(message([absent]).contains("No candidate folder holds a model this build qualifies on a cluster"))
        #expect(message([]).contains("No candidate folder holds a model this build qualifies on a cluster"))
    }

    @Test func releaseModelsComeFromPassingRecordsOfModelsWithAStageAdapter() throws {
        let bundled = ClusterRuntimeApprovalFacts.releaseModels
        for required in [ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact),
                         .init(runtimeModelID: "registered_glm53_flash", artifactSHA256: ClusterGLMImageCandidate.artifactSHA256)] {
            #expect(bundled.contains(required))
        }
        #expect(bundled == bundled.sorted { ($0.runtimeModelID, $0.artifactSHA256) < ($1.runtimeModelID, $1.artifactSHA256) })
        #expect(Set(bundled).count == bundled.count)

        let passing = try #require(ClusterPairServingGrants.records.first { $0.runtimeModelID == "registered_qwen35_9b" && $0.passed })
        #expect(ClusterRuntimeApprovalFacts.qualifiedModels(records: [passing])
                == [.init(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact)])
        let excluded: [(String, ClusterPairQualificationRecord)] = [
            ("no stage adapter", try Self.record(passing) { $0["runtimeModelID"] = "registered_unknown_model" }),
            ("diverged", try Self.record(passing) { object in
                var comparisons = object["comparisons"] as! [[String: Any]]
                comparisons[0]["verdict"] = "diverged"; comparisons[0].removeValue(forKey: "gapInULPs")
                object["comparisons"] = comparisons; object["passed"] = false
            }),
            ("inconsistent", try Self.record(passing) { $0["schema"] = "another_schema" }),
        ]
        for (label, excludedRecord) in excluded {
            #expect(ClusterRuntimeApprovalFacts.qualifiedModels(records: [excludedRecord]).isEmpty, "\(label)")
        }
    }

    /// Facts with three models (byte order: uppercase before lowercase), the first with a grant, for the codec rows.
    static func facts() throws -> ClusterRuntimeApprovalFacts {
        func model(_ name: String, _ seed: Character, grant: ClusterRuntimeApprovalFacts.PairServingGrant? = nil) -> ClusterRuntimeApprovalFacts.Model {
            .init(model: name, artifactSHA256: String(repeating: seed, count: 64), capabilitySHA256: String(repeating: "c", count: 64),
                  profileSHA256: String(repeating: "d", count: 64), resourcePolicySHA256: String(repeating: "e", count: 64),
                  pairServingGrant: grant)
        }
        let grant = ClusterRuntimeApprovalFacts.PairServingGrant(evidenceSHA256: String(repeating: "f", count: 64),
                                                                 modeFamilies: ["pipeline", "tensor_parallel"])
        return try .init(nativeRuntimeSHA256: String(repeating: "1", count: 64), metallibSHA256: String(repeating: "2", count: 64),
            resourceLibrarySHA256: String(repeating: "3", count: 64), placementPolicySHA256: String(repeating: "4", count: 64),
            models: [model("EigenLabs/Qwen3.8-27B-4bit-mtp", "5", grant: grant), model("Qwen3.5-9B", "6"), model("glm-5.3-flash", "7")])
    }

    /// A copy of `base` with fields of its JSON changed.
    static func record(_ base: ClusterPairQualificationRecord, _ change: (inout [String: Any]) -> Void) throws -> ClusterPairQualificationRecord {
        var object = try JSONSerialization.jsonObject(with: Data(base.encodedLine().utf8)) as! [String: Any]
        change(&object)
        return try JSONDecoder().decode(ClusterPairQualificationRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// An app bundle's four cluster helpers in a private temporary folder, with a
/// shell child in the worker's place that prints the capability bytes saved
/// beside the manifest it is given, and records how it was run.
private struct Fixture {
    let root: URL
    let installation: ClusterRuntimeApprovalFacts.Installation
    let workerSHA256: String
    let callsFile: URL

    init() throws {
        let manager = FileManager.default
        // The real path: the installed-file checks refuse a link in any component (/var is one).
        guard let temporary = realpath(manager.temporaryDirectory.path, nil) else { throw ClusterConfigurationError.invalid("no temporary folder") }
        defer { free(temporary) }
        root = URL(fileURLWithPath: String(cString: temporary)).appendingPathComponent("runtime-facts-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Darkbloom Dev.app", isDirectory: true)
        installation = .init(app: app)
        let helpers = installation.worker.deletingLastPathComponent()
        try manager.createDirectory(at: helpers, withIntermediateDirectories: true)
        for directory in [root, app, app.appendingPathComponent("Contents"), helpers] {
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        callsFile = root.appendingPathComponent("calls.txt")
        let expected = root.appendingPathComponent("expected-worker")
        let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(callsFile.path)"
            [ "$#" = 7 ] && [ "$1" = --describe-runtime ] && [ "$2" = --config ] && [ "$4" = --manifest ] || exit 64
            [ "$6" = --expected-executable-sha256 ] && [ "$7" = "$(/bin/cat "\(expected.path)")" ] || exit 65
            folder="$(/usr/bin/dirname "$5")"
            [ -e "$folder/refuse" ] && exit 66
            exec /bin/cat "$folder/capability.out"
            """
        try Data(script.utf8).write(to: installation.worker)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: installation.placementTool)
        try Data("metallib bytes".utf8).write(to: installation.metallib)
        try Data("paged attention source".utf8).write(to: installation.resourceLibrary)
        for (file, mode) in [(installation.worker, 0o755), (installation.placementTool, 0o755),
                             (installation.metallib, 0o644), (installation.resourceLibrary, 0o644)] {
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        workerSHA256 = ClusterConfigurationCodec.sha256(try Data(contentsOf: installation.worker))
        try Data(workerSHA256.utf8).write(to: expected)
    }

    static var metadataFixtures: URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.lastPathComponent != "provider-swift", root.path != "/" { root.deleteLastPathComponent() }
        return root.deletingLastPathComponent().appendingPathComponent("libs/darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures")
    }

    /// One model folder: a pinned fixture's config.json and manifest.json (or
    /// replacements), and the capability the runtime catalog describes for them.
    func model(_ name: String, parent: URL? = nil, fixture: String = "registered-qwen35-9b", capabilityFixture: String? = nil,
               workerSHA256: String? = nil, imageCandidate: Bool = false, manifest: Data? = nil, modelID: String? = nil,
               refused: Bool = false) throws -> URL {
        let folder = (parent ?? root.appendingPathComponent("models", isDirectory: true)).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func read(_ fixture: String, _ kind: String) throws -> Data {
            try Data(contentsOf: Self.metadataFixtures.appendingPathComponent("\(fixture).\(kind).json"))
        }
        var manifestBytes = try manifest ?? read(fixture, "manifest")
        if let modelID {
            var object = try JSONSerialization.jsonObject(with: manifestBytes) as! [String: Any]
            object["model_id"] = modelID
            manifestBytes = try JSONSerialization.data(withJSONObject: object)
        }
        try read(fixture, "configuration").write(to: folder.appendingPathComponent("config.json"))
        try manifestBytes.write(to: folder.appendingPathComponent("manifest.json"))
        let source = capabilityFixture ?? fixture
        let pin = workerSHA256 ?? self.workerSHA256
        let capability = try imageCandidate
            ? MiMoResidentCapabilityMetadata.describe(configuration: read(source, "configuration"),
                manifest: read(source, "manifest"), runtimeBinarySHA256: pin, imageCandidate: true)
            : ClusterResidentModelCatalog.describe(configuration: read(source, "configuration"),
                manifest: read(source, "manifest"), runtimeBinarySHA256: pin)
        try ClusterRuntimeCapabilityCodec.encode(capability).write(to: folder.appendingPathComponent("capability.out"))
        if refused { try Data().write(to: folder.appendingPathComponent("refuse")) }
        return folder
    }

    func calls() throws -> [String] {
        guard FileManager.default.fileExists(atPath: callsFile.path) else { return [] }
        return try String(contentsOf: callsFile, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func digest(_ url: URL) -> String { ClusterConfigurationCodec.sha256((try? Data(contentsOf: url)) ?? Data()) }

    func chmod(_ url: URL, _ mode: Int) throws { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }

    func real(_ url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else { throw ClusterConfigurationError.invalid("missing") }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
