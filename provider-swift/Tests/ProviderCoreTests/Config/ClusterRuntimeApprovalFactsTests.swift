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
        func model(_ name: String, _ seed: Character, _ qualifications: String) -> String {
            #"{"artifact_sha256":"\#(h(seed))","capability_sha256":"\#(h("c"))","model":"\#(name)","parity_qualifications":\#(qualifications),"#
                + #""profile_sha256":"\#(h("d"))","resource_policy_sha256":"\#(h("e"))"}"#
        }
        func qualification(_ schedule: Int) -> String {
            #"{"cuts":[],"diverged":false,"evidence_sha256":"\#(h("f"))","mode":"tensor_parallel_v1","#
                + #""numerics_classes":["g17d-nax1-mlx-22222222-macos27.0","g17d-nax1-mlx-22222222-macos27.0"],"promotable":true,"#
                + #""qualified_at":"2026-10-31T00:00:00Z","request_envelope":{"max_output_tokens":1048576,"max_prompt_tokens":1048576,"#
                + #""sampling":true,"tools":true,"video":true,"vision":true},"schedule":\#(schedule),"tensor_parallel_shares":null}"#
        }
        // Keys in byte order at every level, equal shares written as null, no whitespace, no escaped slash and no
        // trailing newline.
        let golden = #"{"metallib_sha256":"\#(h("2"))","models":["#
            + [model("EigenLabs/Qwen3.8-27B-4bit-mtp", "5", "[" + qualification(1) + "," + qualification(2) + "]"),
               model("Qwen3.5-9B", "6", "[]"), model("glm-5.3-flash", "7", "[]")].joined(separator: ",")
            + #"],"native_runtime_sha256":"\#(h("1"))","placement_policy_sha256":"\#(h("4"))","#
            + #""resource_library_sha256":"\#(h("3"))","schema":"darkbloom_cluster_runtime_v2"}"#
        #expect(String(decoding: bytes, as: UTF8.self) == golden)
        let decoded = try ClusterRuntimeApprovalFacts(canonical: bytes, releaseVersion: Self.releaseVersion)
        #expect(decoded == facts)
        #expect(try decoded.canonicalBytes() == bytes)
    }

    /// The block the release lane computes for GLM-5.3-Flash on DevNet: the installed 0.10.5-dev.branch.16 app's own
    /// worker described DevNet's catalog metadata (`--release-candidates`, catalog entry text, image and video). Its
    /// v1 digests are the app's own v1 output; the qualifications are this build's declaration for that metallib.
    @Test func theGLMBlockOfTheBranch16AppIsPinned() throws {
        let data = try Data(contentsOf: Fixture.providerTests.appendingPathComponent("Fixtures/ClusterRuntime/glm-5.3-flash-dev-branch16.json"))
        let facts = try ClusterRuntimeApprovalFacts(canonical: data, releaseVersion: "0.10.5-dev.branch.17")
        #expect(try facts.canonicalBytes() == data)
        #expect(facts.nativeRuntimeSHA256 == "fcb75684ee50e02cb140f8c1f7b90d27b23e70bd523554ce42174f391742e5d3")
        #expect(facts.metallibSHA256 == "98bab9d77dc5078ad8dd8f1fd17e8f3581415193506e4791a3c4f1ebaab614be")
        let glm = try #require(facts.models.first)
        #expect(facts.models.map(\.model) == ["glm-5.3-flash"])
        #expect(glm.capabilitySHA256 == "980313314b1dc818d785541351b02f32a9b9777a1a7bf238cfea24c633eee95f")
        #expect(glm.parityQualifications == ClusterRuntimeApprovalFacts.parityQualifications(model: "glm-5.3-flash",
            runtimeModelID: "registered_glm53_flash", artifactSHA256: ClusterGLMImageCandidate.artifactSHA256,
            metallibSHA256: facts.metallibSHA256, inputModalities: ["text", "image", "video"], publicModels: ClusterPublicModels.declared))
        #expect(glm.parityQualifications.map(\.schedule) == [1, 2])
        // What both live M5 Ultras register (ClusterMemberDeviceProfile.numericsClass).
        #expect(glm.parityQualifications.allSatisfy { $0.numericsClasses == ["g17d-nax1-mlx-98bab9d7-macos27.0", "g17d-nax1-mlx-98bab9d7-macos27.0"] })
        #expect(glm.parityQualifications.allSatisfy { $0.requestEnvelope.vision && $0.requestEnvelope.video })
    }

    @Test func decoderRefusesUnknownMissingOrMistypedFields() throws {
        let object = try JSONSerialization.jsonObject(with: Self.facts().canonicalBytes()) as! [String: Any]
        var rows: [String: Any] = [:]
        func edited(_ change: (inout [String: Any]) -> Void) -> [String: Any] { var copy = object; change(&copy); return copy }
        func editedModel(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            edited { block in var models = block["models"] as! [[String: Any]]; change(&models[0]); block["models"] = models }
        }
        func editedQualification(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            editedModel { model in
                var qualifications = model["parity_qualifications"] as! [[String: Any]]
                change(&qualifications[0]); model["parity_qualifications"] = qualifications
            }
        }
        func editedEnvelope(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            editedQualification { q in var envelope = q["request_envelope"] as! [String: Any]; change(&envelope); q["request_envelope"] = envelope }
        }
        rows["unknown field"] = edited { $0["extra"] = 1 }
        rows["missing field"] = edited { $0.removeValue(forKey: "placement_policy_sha256") }
        rows["schema v1"] = edited { $0["schema"] = "darkbloom_cluster_runtime_v1" }
        rows["unknown model field"] = editedModel { $0["extra"] = 1 }
        rows["missing model field"] = editedModel { $0.removeValue(forKey: "profile_sha256") }
        rows["no parity_qualifications"] = editedModel { $0.removeValue(forKey: "parity_qualifications") }
        rows["a pair_serving_grant"] = editedModel { $0["pair_serving_grant"] = NSNull() }
        rows["qualifications null"] = editedModel { $0["parity_qualifications"] = NSNull() }
        rows["qualification a string"] = editedModel { $0["parity_qualifications"] = ["tensor_parallel"] }
        rows["unknown qualification field"] = editedQualification { $0["id"] = "q1" }
        rows["missing qualification field"] = editedQualification { $0.removeValue(forKey: "qualified_at") }
        rows["shares absent"] = editedQualification { $0.removeValue(forKey: "tensor_parallel_shares") }
        rows["shares not null"] = editedQualification { $0["tensor_parallel_shares"] = ["version": 1, "per_mille": [500, 500]] }
        rows["unknown mode"] = editedQualification { $0["mode"] = "tensor_parallel_v9" }
        rows["schedule a string"] = editedQualification { $0["schedule"] = "1" }
        rows["promotable a number"] = editedQualification { $0["promotable"] = 1 }
        rows["unknown envelope field"] = editedEnvelope { $0["logprobs"] = true }
        rows["missing envelope field"] = editedEnvelope { $0.removeValue(forKey: "video") }
        rows["mistyped digest"] = edited { $0["metallib_sha256"] = 7 }
        rows["models not a list"] = edited { $0["models"] = [:] as [String: Any] }
        for (label, value) in rows {
            let data = try JSONSerialization.data(withJSONObject: value)
            #expect(throws: ClusterConfigurationError.self, "\(label)") { try ClusterRuntimeApprovalFacts(canonical: data, releaseVersion: Self.releaseVersion) }
        }
        // A repeated key, also one spelled with an escape, at the top, in a model, in a qualification or its envelope.
        let text = String(decoding: try Self.facts().canonicalBytes(), as: UTF8.self)
        for (label, repeated) in [
            ("top", text.replacingOccurrences(of: #"{"metallib_sha256":"#,
                                              with: #"{"schema":"darkbloom_cluster_runtime_v2","metallib_sha256":"#)),
            ("escaped", text.replacingOccurrences(of: #"{"metallib_sha256":"#,
                                                  with: #"{"sch\u0065ma":"darkbloom_cluster_runtime_v2","metallib_sha256":"#)),
            ("model", text.replacingOccurrences(of: #"[{"artifact_sha256":"#, with: #"[{"model":"Z","artifact_sha256":"#)),
            ("qualification", text.replacingOccurrences(of: #"{"cuts":[],"#, with: #"{"schedule":2,"cuts":[],"#)),
            ("envelope", text.replacingOccurrences(of: #"{"max_output_tokens":"#, with: #"{"video":false,"max_output_tokens":"#)),
        ] {
            #expect(repeated != text, "\(label)")
            #expect(throws: ClusterConfigurationError.self, "\(label)") { try ClusterRuntimeApprovalFacts(canonical: Data(repeated.utf8), releaseVersion: Self.releaseVersion) }
        }
        for data in [Data("{".utf8), Data("[]".utf8), Data(repeating: 32, count: ClusterRuntimeApprovalFacts.maximumEncodedBytes + 1)] {
            #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: data, releaseVersion: Self.releaseVersion) }
        }
    }

    @Test func decoderRefusesFactsWhoseDerivedIDsExceedTheirBound() throws {
        // release/1.2.3/<model>/s2: 17 bytes plus the model ID; a qualification's ID adds "/q1".
        func block(_ model: String, qualified: Bool) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: Self.facts().canonicalBytes()) as! [String: Any]
            var models = object["models"] as! [[String: Any]]
            models = [models[0]]; models[0]["model"] = model
            if !qualified { models[0]["parity_qualifications"] = [Any]() }
            object["models"] = models
            return try JSONSerialization.data(withJSONObject: object)
        }
        func m(_ count: Int) -> String { String(repeating: "m", count: count) }
        #expect("release/1.2.3/\(m(111))/s2".utf8.count == ClusterRuntimeApprovalFacts.maximumDerivedIDBytes)
        #expect(try ClusterRuntimeApprovalFacts(canonical: block(m(111), qualified: false), releaseVersion: "1.2.3").models.map(\.model) == [m(111)])
        #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: block(m(112), qualified: false), releaseVersion: "1.2.3") }
        _ = try ClusterRuntimeApprovalFacts(canonical: block(m(108), qualified: true), releaseVersion: "1.2.3")
        #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: block(m(109), qualified: true), releaseVersion: "1.2.3") }
        // The bound follows the version the caller names: a dev release version
        // (30 bytes of ID before the model) leaves 98 bytes, or 95 with a qualification.
        let dev = "1.2.3-dev.branch.7"
        _ = try ClusterRuntimeApprovalFacts(canonical: block(m(98), qualified: false), releaseVersion: dev)
        #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: block(m(99), qualified: false), releaseVersion: dev) }
        _ = try ClusterRuntimeApprovalFacts(canonical: block(m(95), qualified: true), releaseVersion: dev)
        #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: block(m(96), qualified: true), releaseVersion: dev) }
        // n counts each schedule's qualifications in block order.
        let facts = try Self.facts()
        #expect(ClusterRuntimeApprovalFacts.derivedIDs(facts.models[0], releaseVersion: "V") == [
            "release/V/EigenLabs/Qwen3.8-27B-4bit-mtp/s1", "release/V/EigenLabs/Qwen3.8-27B-4bit-mtp/s2",
            "release/V/EigenLabs/Qwen3.8-27B-4bit-mtp/s1/q1", "release/V/EigenLabs/Qwen3.8-27B-4bit-mtp/s2/q1"])
    }

    @Test func rulesRefuseDigestsCountsOrderModelIDsAndQualifications() throws {
        let facts = try Self.facts(), good = facts.models
        func make(models: [ClusterRuntimeApprovalFacts.Model] = good, native: String? = nil) throws -> ClusterRuntimeApprovalFacts {
            try .init(nativeRuntimeSHA256: native ?? facts.nativeRuntimeSHA256, metallibSHA256: facts.metallibSHA256,
                      resourceLibrarySHA256: facts.resourceLibrarySHA256, placementPolicySHA256: facts.placementPolicySHA256,
                      models: models)
        }
        func named(_ name: String, _ base: ClusterRuntimeApprovalFacts.Model = good[1],
                   qualifications: [ClusterRuntimeApprovalFacts.ParityQualification] = []) -> ClusterRuntimeApprovalFacts.Model {
            .init(model: name, artifactSHA256: base.artifactSHA256, capabilitySHA256: base.capabilitySHA256,
                  profileSHA256: base.profileSHA256, resourcePolicySHA256: base.resourcePolicySHA256, parityQualifications: qualifications)
        }
        let q = good[0].parityQualifications[0]
        func qualified(schedule: UInt8 = 1, classes: [String]? = nil, cuts: [Int] = [], mode: ClusterGenerationMode = .tensorParallel,
                       promotable: Bool = true, diverged: Bool = false, evidence: String? = nil, at: String = "2026-10-31T00:00:00Z",
                       envelope: ClusterRequestEnvelope? = nil) -> ClusterRuntimeApprovalFacts.Model {
            named("a", qualifications: [.init(schedule: schedule, numericsClasses: classes ?? q.numericsClasses, cuts: cuts, mode: mode,
                promotable: promotable, diverged: diverged, evidenceSHA256: evidence ?? q.evidenceSHA256, qualifiedAt: at,
                requestEnvelope: envelope ?? q.requestEnvelope)])
        }
        func envelope(vision: Bool = true, video: Bool = true, prompt: Int = 1_048_576, output: Int = 1_048_576) -> ClusterRequestEnvelope {
            .init(sampling: true, tools: true, vision: vision, video: video, maxPromptTokens: prompt, maxOutputTokens: output)
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
            ("schedule 3", { try make(models: [qualified(schedule: 3)]) }),
            ("one numerics class", { try make(models: [qualified(classes: ["g17d"])]) }),
            ("three numerics classes", { try make(models: [qualified(classes: ["a", "b", "c"])]) }),
            ("empty numerics class", { try make(models: [qualified(classes: ["", "b"])]) }),
            ("space in a numerics class", { try make(models: [qualified(classes: ["a b", "b"])]) }),
            ("tensor parallel with a cut", { try make(models: [qualified(cuts: [8])]) }),
            ("pipeline without a cut", { try make(models: [qualified(mode: .pipeline)]) }),
            ("zero cut", { try make(models: [qualified(cuts: [0], mode: .pipeline)]) }),
            ("diverged and promotable", { try make(models: [qualified(diverged: true)]) }),
            ("zero evidence", { try make(models: [qualified(evidence: zero)]) }),
            ("not an instant", { try make(models: [qualified(at: "2026-10-31")]) }),
            ("video without vision", { try make(models: [qualified(envelope: envelope(vision: false, video: true))]) }),
            ("no prompt tokens", { try make(models: [qualified(envelope: envelope(prompt: 0))]) }),
            ("too many output tokens", { try make(models: [qualified(envelope: envelope(output: 1_048_577))]) }),
            ("a placement twice", { try make(models: [named("a", qualifications: [q, q])]) }),
            ("nine qualifications", { try make(models: [named("a", qualifications: (0..<9).map { index in
                .init(schedule: 1, numericsClasses: ["c\(index)", "c\(index)"], cuts: [], mode: .tensorParallel, promotable: true,
                      diverged: false, evidenceSHA256: q.evidenceSHA256, qualifiedAt: q.qualifiedAt, requestEnvelope: q.requestEnvelope)
            })]) }),
        ]
        for (label, row) in rows {
            #expect(throws: ClusterConfigurationError.self, "\(label)") { _ = try row() }
        }
        // The bounds themselves are accepted, in byte order (uppercase first).
        _ = try make(models: (0..<64).map { named(String(format: "m%02d", $0)) })
        _ = try make(models: [named(" " + String(repeating: "~", count: 127))])
        _ = try make(models: [named("Z"), named("a")])
        _ = try make(models: [qualified(cuts: [8], mode: .pipeline, promotable: false, diverged: true,
                                        at: "2026-10-31T00:00:00.5+02:00", envelope: envelope(vision: false, video: false, prompt: 1, output: 1))])
        _ = try make(models: [named("a", qualifications: [q, qualified(schedule: 2).parityQualifications[0]])])
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

    @Test func theDeclarationIsTheOwnersTwoModelsWithItsEvidenceDocument() throws {
        let declared = ClusterPublicModels.declared
        #expect(declared.map(\.runtimeModelID) == ["registered_glm53_flash", "registered_qwen38_27b"])
        #expect(declared.map(\.catalogModelID) == ["glm-5.3-flash", "EigenLabs/Qwen3.8-27B-4bit-mtp"])
        let placement = ClusterPublicModel.Placement(mode: .tensorParallel, ranks: 2, gpuArchitecture: "applegpu_g17d",
                                                     macOSMajor: 27, macOSMinor: 0, cuts: [])
        for model in declared {
            #expect(model.placements == [placement] && model.families == [.tensorParallel] && model.schedules == [1, 2])
            // The artifact the runtime registers for the model, which its bundled records ran.
            #expect(ClusterPairServingGrants.decisions.artifacts(runtimeModelID: model.runtimeModelID) == [model.artifactSHA256])
        }
        #expect(declared[0].artifactSHA256 == ClusterGLMImageCandidate.artifactSHA256)
        #expect(ClusterPublicModels.qualifiedAt == "2026-10-31T00:00:00Z")
        // The released CLI names the evidence document by its SHA-256: the checked-in report's.
        let report = try Data(contentsOf: Fixture.repository.appendingPathComponent(ClusterPublicModels.evidenceDocument))
        #expect(ClusterPublicModels.evidenceSHA256 == Self.sha256(report))
        // What both live M5 Ultras register with the 0.10.5-dev.branch.15 and .16 Metal library.
        #expect(ClusterRuntimeApprovalFacts.numericsClasses(placement,
                metallibSHA256: "98bab9d77dc5078ad8dd8f1fd17e8f3581415193506e4791a3c4f1ebaab614be")
            == ["g17d-nax1-mlx-98bab9d7-macos27.0", "g17d-nax1-mlx-98bab9d7-macos27.0"])
    }

    @Test func theRequestEnvelopeAdmitsTheMediaTheCatalogEntryLists() {
        func envelope(_ modalities: [String]) -> (vision: Bool, video: Bool) {
            let e = ClusterPublicModels.requestEnvelope(inputModalities: modalities)
            #expect(e.sampling && e.tools && e.maxPromptTokens == 1_048_576 && e.maxOutputTokens == 1_048_576)
            return (e.vision, e.video)
        }
        #expect(envelope([]) == (false, false))
        #expect(envelope(["text"]) == (false, false))
        #expect(envelope(["text", "image"]) == (true, false))
        #expect(envelope(["text", "video"]) == (false, false))
        #expect(envelope(["text", "image", "video"]) == (true, true))
    }

    @Test func parityQualificationsComeFromTheDeclarationOfTheModelCatalogIDAndArtifact() throws {
        let f = try Fixture()
        let metallibClass = ClusterMemberDeviceProfile.numericsClass(architecture: "applegpu_g17d",
            metallibSHA256: f.digest(f.installation.metallib), os: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        func qualifications(_ folder: URL, publicModels: [ClusterPublicModel] = ClusterPublicModels.declared,
                            catalog: Bool = false) throws -> [ClusterRuntimeApprovalFacts.ParityQualification] {
            let files = catalog ? try ClusterRuntimeApprovalFacts.candidates(in: folder.deletingLastPathComponent())
                .first { $0.manifest.deletingLastPathComponent().lastPathComponent == folder.lastPathComponent }!
                : ClusterRuntimeApprovalFacts.ModelFiles(directory: folder)
            return try #require(ClusterRuntimeApprovalFacts.compute(installation: f.installation, models: [files],
                                                                    publicModels: publicModels).models.first).parityQualifications
        }
        // The declared 27B given by hand: both schedules, this build's class on both ranks, text only.
        let q27 = try f.model("q27", fixture: "registered-qwen38-27b")
        let byHand = try qualifications(q27)
        #expect(byHand.map(\.schedule) == [1, 2])
        for q in byHand {
            #expect(q.numericsClasses == [metallibClass, metallibClass] && q.cuts == [] && q.mode == .tensorParallel)
            #expect(q.promotable && !q.diverged && q.evidenceSHA256 == ClusterPublicModels.evidenceSHA256 && q.qualifiedAt == "2026-10-31T00:00:00Z")
            #expect(q.requestEnvelope == ClusterPublicModels.requestEnvelope(inputModalities: []))
        }
        // As a release candidate, the catalog entry's media.
        let candidates = f.root.appendingPathComponent("candidates", isDirectory: true)
        let media = try f.model("27b-media", parent: candidates, fixture: "registered-qwen38-27b", modalities: ["text", "image", "video"])
        #expect(try qualifications(media, catalog: true).allSatisfy { $0.requestEnvelope.vision && $0.requestEnvelope.video })
        let images = try f.model("27b-images", parent: candidates, fixture: "registered-qwen38-27b", modalities: ["text", "image"])
        #expect(try qualifications(images, catalog: true).allSatisfy { $0.requestEnvelope.vision && !$0.requestEnvelope.video })
        // Undeclared: another model, the declared model under another catalog ID, or no declaration at all.
        #expect(try qualifications(try f.model("nine")).isEmpty)
        #expect(try qualifications(try f.model("copy", fixture: "registered-qwen38-27b", modelID: "EigenLabs/Qwen3.8-27B-copy")).isEmpty)
        #expect(try qualifications(q27, publicModels: []).isEmpty)
        // Another declaration declares another model, with its own artifact only.
        let nine = try f.model("nine-declared")
        let declaration = ClusterPublicModel(runtimeModelID: "registered_qwen35_9b", catalogModelID: "Qwen3.5-9B",
            artifactSHA256: Self.qwenArtifact, placements: [ClusterPublicModels.m5UltraTensorParallel], schedules: [2])
        #expect(try qualifications(nine, publicModels: [declaration]).map(\.schedule) == [2])
        let otherArtifact = ClusterPublicModel(runtimeModelID: "registered_qwen35_9b", catalogModelID: "Qwen3.5-9B",
            artifactSHA256: String(repeating: "e", count: 64), placements: [ClusterPublicModels.m5UltraTensorParallel], schedules: [2])
        #expect(try qualifications(nine, publicModels: [otherArtifact]).isEmpty)
    }

    @Test func aCandidateWhoseCatalogEntryIsNotItsOwnIsRefused() throws {
        let f = try Fixture()
        let listed = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact)
        for (label, entry) in [("another model's", #"{"id":"glm-5.3-flash","input_modalities":["text"]}"#),
                               ("missing modalities", #"{"id":"Qwen3.5-9B"}"#), ("modalities mistyped", #"{"id":"Qwen3.5-9B","input_modalities":"text"}"#),
                               ("an extra field", #"{"id":"Qwen3.5-9B","input_modalities":[],"r2_prefix":"x"}"#), ("not JSON", "{"), ("absent", nil)] {
            let candidates = f.root.appendingPathComponent("candidates-\(label)", isDirectory: true)
            let folder = try f.model("only", parent: candidates)
            let catalog = folder.appendingPathComponent("catalog.json")
            if let entry { try Data(entry.utf8).write(to: catalog) } else { try FileManager.default.removeItem(at: catalog) }
            #expect(throws: ClusterConfigurationError.self, "\(label)") {
                _ = try ClusterRuntimeApprovalFacts.release(installation: f.installation,
                    candidates: try ClusterRuntimeApprovalFacts.candidates(in: candidates), models: [listed])
            }
        }
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
        #expect(facts.models.first?.parityQualifications == [])
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

    /// Facts with three models (byte order: uppercase before lowercase), the first with two parity qualifications,
    /// for the codec rows.
    static func facts() throws -> ClusterRuntimeApprovalFacts {
        func model(_ name: String, _ seed: Character,
                   qualifications: [ClusterRuntimeApprovalFacts.ParityQualification] = []) -> ClusterRuntimeApprovalFacts.Model {
            .init(model: name, artifactSHA256: String(repeating: seed, count: 64), capabilitySHA256: String(repeating: "c", count: 64),
                  profileSHA256: String(repeating: "d", count: 64), resourcePolicySHA256: String(repeating: "e", count: 64),
                  parityQualifications: qualifications)
        }
        let classes = Array(repeating: "g17d-nax1-mlx-22222222-macos27.0", count: 2)
        let qualifications = [UInt8(1), 2].map {
            ClusterRuntimeApprovalFacts.ParityQualification(schedule: $0, numericsClasses: classes, cuts: [], mode: .tensorParallel,
                promotable: true, diverged: false, evidenceSHA256: String(repeating: "f", count: 64), qualifiedAt: "2026-10-31T00:00:00Z",
                requestEnvelope: ClusterPublicModels.requestEnvelope(inputModalities: ["text", "image", "video"]))
        }
        return try .init(nativeRuntimeSHA256: String(repeating: "1", count: 64), metallibSHA256: String(repeating: "2", count: 64),
            resourceLibrarySHA256: String(repeating: "3", count: 64), placementPolicySHA256: String(repeating: "4", count: 64),
            models: [model("EigenLabs/Qwen3.8-27B-4bit-mtp", "5", qualifications: qualifications), model("Qwen3.5-9B", "6"),
                     model("glm-5.3-flash", "7")])
    }

    /// A copy of `base` with fields of its JSON changed.
    static func record(_ base: ClusterPairQualificationRecord, _ change: (inout [String: Any]) -> Void) throws -> ClusterPairQualificationRecord {
        var object = try JSONSerialization.jsonObject(with: Data(base.encodedLine().utf8)) as! [String: Any]
        change(&object)
        return try JSONDecoder().decode(ClusterPairQualificationRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// The checkout's `provider-swift` folder.
    static var providerSwift: URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.lastPathComponent != "provider-swift", root.path != "/" { root.deleteLastPathComponent() }
        return root
    }

    static var repository: URL { providerSwift.deletingLastPathComponent() }

    static var providerTests: URL { providerSwift.appendingPathComponent("Tests/ProviderCoreTests") }

    static var metadataFixtures: URL {
        repository.appendingPathComponent("libs/darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures")
    }

    /// One model folder: a pinned fixture's config.json and manifest.json (or
    /// replacements), and the capability the runtime catalog describes for them.
    /// A release candidate (`parent`) also has its catalog entry (`catalog.json`).
    func model(_ name: String, parent: URL? = nil, fixture: String = "registered-qwen35-9b", capabilityFixture: String? = nil,
               workerSHA256: String? = nil, imageCandidate: Bool = false, manifest: Data? = nil, modelID: String? = nil,
               refused: Bool = false, modalities: [String] = ["text"]) throws -> URL {
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
        if parent != nil, let id = (try? JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])?["model_id"] as? String {
            try JSONSerialization.data(withJSONObject: ["id": id, "input_modalities": modalities], options: [.sortedKeys])
                .write(to: folder.appendingPathComponent("catalog.json"))
        }
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
