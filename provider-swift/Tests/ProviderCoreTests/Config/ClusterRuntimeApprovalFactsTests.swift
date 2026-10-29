import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
@testable import ProviderCore

/// The cluster runtime facts a dev release registers. The capability bytes are
/// the runtime catalog's real description of the pinned Qwen3.5-9B and MiMo
/// metadata fixtures; a shell child stands in for the worker process at the
/// process seam and prints them. No model, GPU or network.
@Suite("Cluster runtime approval facts")
struct ClusterRuntimeApprovalFactsTests {
    static let qwenArtifact = "127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b"

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
        #expect(entry.resourcePolicySHA256 == NativePairMemberInstallation.hex(DistributedInstalledNativeStart.resourcePolicySHA256(capability)))

        // The worker ran its metadata command with the hash just computed.
        let configuration = try f.real(model.appendingPathComponent("config.json"))
        let manifest = try f.real(model.appendingPathComponent("manifest.json"))
        #expect(try f.calls() == ["--describe-runtime --config \(configuration) --manifest \(manifest) --expected-executable-sha256 \(facts.nativeRuntimeSHA256)"])
    }

    @Test func canonicalBytesRoundTripAndAreSortedWithoutWhitespace() throws {
        let facts = try Self.facts()
        let bytes = try facts.canonicalBytes()
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix(#"{"metallib_sha256":""#))
        #expect(text.contains(#""models":[{"artifact_sha256":""#))
        #expect(text.contains(#""model":"EigenLabs/Qwen3.8-27B-4bit-mtp""#))
        #expect(text.hasSuffix(#""schema":"darkbloom_cluster_runtime_v1"}"#))
        #expect(!text.contains(" ") && !text.contains("\n") && !text.contains(#"\/"#))
        let decoded = try ClusterRuntimeApprovalFacts(canonical: bytes)
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
        rows["unknown field"] = edited { $0["extra"] = 1 }
        rows["missing field"] = edited { $0.removeValue(forKey: "placement_policy_sha256") }
        rows["another schema"] = edited { $0["schema"] = "darkbloom_cluster_runtime_v2" }
        rows["unknown model field"] = editedModel { $0["extra"] = 1 }
        rows["missing model field"] = editedModel { $0.removeValue(forKey: "profile_sha256") }
        rows["mistyped digest"] = edited { $0["metallib_sha256"] = 7 }
        rows["models not a list"] = edited { $0["models"] = [:] as [String: Any] }
        for (label, value) in rows {
            let data = try JSONSerialization.data(withJSONObject: value)
            #expect(throws: ClusterConfigurationError.self, "\(label)") { try ClusterRuntimeApprovalFacts(canonical: data) }
        }
        for data in [Data("{".utf8), Data("[]".utf8), Data(repeating: 32, count: ClusterRuntimeApprovalFacts.maximumEncodedBytes + 1)] {
            #expect(throws: ClusterConfigurationError.self) { try ClusterRuntimeApprovalFacts(canonical: data) }
        }
    }

    @Test func rulesRefuseDigestsCountsOrderAndModelIDs() throws {
        let facts = try Self.facts(), good = facts.models
        func make(models: [ClusterRuntimeApprovalFacts.Model] = good, native: String? = nil) throws -> ClusterRuntimeApprovalFacts {
            try .init(nativeRuntimeSHA256: native ?? facts.nativeRuntimeSHA256, metallibSHA256: facts.metallibSHA256,
                      resourceLibrarySHA256: facts.resourceLibrarySHA256, placementPolicySHA256: facts.placementPolicySHA256,
                      models: models)
        }
        func named(_ name: String, _ base: ClusterRuntimeApprovalFacts.Model = good[0]) -> ClusterRuntimeApprovalFacts.Model {
            .init(model: name, artifactSHA256: base.artifactSHA256, capabilitySHA256: base.capabilitySHA256,
                  profileSHA256: base.profileSHA256, resourcePolicySHA256: base.resourcePolicySHA256)
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
        ]
        for (label, row) in rows {
            #expect(throws: ClusterConfigurationError.self, "\(label)") { _ = try row() }
        }
        // The bounds themselves are accepted, in byte order (uppercase first).
        _ = try make(models: (0..<64).map { named(String(format: "m%02d", $0)) })
        _ = try make(models: [named(" " + String(repeating: "~", count: 127))])
        _ = try make(models: [named("Z"), named("a")])
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

    @Test func releaseChoosesTheCandidateTheWorkerDescribesAsEachListedModel() throws {
        let f = try Fixture()
        let candidates = f.root.appendingPathComponent("candidates", isDirectory: true)
        _ = try f.model("0-refused", parent: candidates, refused: true)
        _ = try f.model("1-accepted", parent: candidates)
        _ = try f.model("2-later", parent: candidates)
        let listed = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact)
        let facts = try ClusterRuntimeApprovalFacts.release(installation: f.installation,
            candidates: try ClusterRuntimeApprovalFacts.candidates(in: candidates), required: ["Qwen3.5-9B"], models: [listed])
        #expect(facts.models.map(\.model) == ["Qwen3.5-9B"])
        // The refused candidate was tried, the accepted one chosen, the rest not run.
        #expect(try f.calls().count == 2)
        #expect(try f.calls().last?.contains("1-accepted") == true)
    }

    @Test func releaseNamesEveryModelItCannotDescribeAndEveryRequiredModelItLacks() throws {
        let f = try Fixture()
        let candidates = f.root.appendingPathComponent("candidates", isDirectory: true)
        _ = try f.model("refused", parent: candidates, refused: true)
        let all = try ClusterRuntimeApprovalFacts.candidates(in: candidates)
        let qwen = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact)
        let absent = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_glm53_flash",
                                                              artifactSHA256: ClusterGLMImageCandidate.artifactSHA256)
        func message(_ body: () throws -> Void) -> String {
            do { try body(); return "" } catch { return String(describing: error) }
        }
        let refused = message { _ = try ClusterRuntimeApprovalFacts.release(installation: f.installation, candidates: all,
                                                                             required: [], models: [qwen, absent]) }
        #expect(refused.contains("registered_qwen35_9b") && refused.contains("refused/manifest.json"))
        #expect(refused.contains("registered_glm53_flash") && refused.contains("no candidate folder has this artifact"))

        _ = try f.model("accepted", parent: candidates)
        let another = ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_other", artifactSHA256: Self.qwenArtifact)
        let foreign = message { _ = try ClusterRuntimeApprovalFacts.release(installation: f.installation,
            candidates: try ClusterRuntimeApprovalFacts.candidates(in: candidates), required: [], models: [another]) }
        #expect(foreign.contains("is registered_qwen35_9b"))

        let lacking = message { _ = try ClusterRuntimeApprovalFacts.release(installation: f.installation,
            candidates: try ClusterRuntimeApprovalFacts.candidates(in: candidates), required: ["Qwen3.5-9B", "glm-5.3-flash"],
            models: [qwen]) }
        #expect(lacking.contains("lack required models: glm-5.3-flash"))
        #expect(!lacking.contains("Qwen3.5-9B"))
    }

    /// `softReleaseModels`: the GLM runtime model is left out, and reported,
    /// only when the worker refused every candidate and the caller reports
    /// omissions. Qwen, every other refusal and every other model still fail.
    @Test func releaseLeavesOutOnlyASoftModelEveryCandidateOfWhichTheWorkerRefuses() throws {
        let f = try Fixture()
        typealias Listed = ClusterRuntimeApprovalFacts.ReleaseModel
        let otherArtifact = try Self.aggregate(of: "registered-qwen38-27b")
        let qwen = Listed(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact)
        let glm = Listed(runtimeModelID: "registered_glm53_flash", artifactSHA256: otherArtifact)
        /// A candidate folder per (name, fixture, refused, worker pin); then release with or without a reporter.
        func release(_ folders: [(String, String, Bool, String?)], models: [Listed], required: [String] = ["Qwen3.5-9B", "glm-5.3-flash"],
                     reporting: Bool = true) throws -> (ClusterRuntimeApprovalFacts, [ClusterRuntimeApprovalFacts.Omission]) {
            let parent = f.root.appendingPathComponent("candidates-\(UUID().uuidString)", isDirectory: true)
            for (name, fixture, refused, pin) in folders {
                _ = try f.model(name, parent: parent, fixture: fixture, workerSHA256: pin, refused: refused)
            }
            var omissions: [ClusterRuntimeApprovalFacts.Omission] = []
            var report: ((ClusterRuntimeApprovalFacts.Omission) -> Void)?
            if reporting { report = { omissions.append($0) } }
            let facts = try ClusterRuntimeApprovalFacts.release(installation: f.installation,
                candidates: try ClusterRuntimeApprovalFacts.candidates(in: parent), required: required, models: models,
                omitted: report)
            return (facts, omissions)
        }
        func failure(_ body: () throws -> Void) -> String {
            do { try body(); return "" } catch { return String(describing: error) }
        }
        let qwenFolder = ("qwen", "registered-qwen35-9b", false, String?.none)
        let refusedGLM = ("glm", "registered-qwen38-27b", true, String?.none)

        // GLM refused by the worker: left out, reported once, required GLM met.
        let (facts, omissions) = try release([qwenFolder, refusedGLM], models: [qwen, glm])
        #expect(facts.models.map(\.model) == ["Qwen3.5-9B"])
        #expect(omissions.map(\.model) == ["glm-5.3-flash"] && omissions.map(\.runtimeModelID) == ["registered_glm53_flash"])
        #expect(omissions.first?.reason.contains("glm/manifest.json: Installed capability command failed") == true)

        let rows: [(String, String, () throws -> Void)] = [
            ("a caller that reports no omission", "registered_glm53_flash", {
                _ = try release([qwenFolder, refusedGLM], models: [qwen, glm], reporting: false) }),
            ("Qwen refused by the worker", "registered_qwen35_9b", {
                _ = try release([("qwen", "registered-qwen35-9b", true, nil), refusedGLM], models: [qwen, glm]) }),
            ("GLM described as another build", "registered_glm53_flash", {
                _ = try release([qwenFolder, ("glm", "registered-qwen38-27b", false, String(repeating: "e", count: 64))],
                                models: [qwen, glm]) }),
            ("GLM's candidate is another runtime model", "registered_glm53_flash", {
                _ = try release([qwenFolder], models: [qwen, Listed(runtimeModelID: glm.runtimeModelID, artifactSHA256: Self.qwenArtifact)]) }),
            ("GLM without a candidate", "no candidate folder has this artifact", {
                _ = try release([qwenFolder], models: [qwen, glm]) }),
            ("a model outside the soft list", "registered_other", {
                _ = try release([qwenFolder, refusedGLM], models: [qwen, Listed(runtimeModelID: "registered_other", artifactSHA256: otherArtifact)],
                                required: ["Qwen3.5-9B"]) }),
            ("required GLM that is not listed", "lack required models: glm-5.3-flash", {
                _ = try release([qwenFolder], models: [qwen]) }),
        ]
        for (label, named, row) in rows {
            #expect(failure(row).contains(named), "\(label)")
        }
        #expect(ClusterRuntimeApprovalFacts.softReleaseModels == ["registered_glm53_flash": "glm-5.3-flash"])
    }

    @Test func releaseModelsComeFromPassingRecordsOfModelsWithAStageAdapter() throws {
        let bundled = ClusterRuntimeApprovalFacts.releaseModels
        for required in [ClusterRuntimeApprovalFacts.ReleaseModel(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact),
                         .init(runtimeModelID: "registered_glm53_flash", artifactSHA256: ClusterGLMImageCandidate.artifactSHA256)] {
            #expect(bundled.contains(required))
        }
        #expect(bundled == bundled.sorted { ($0.runtimeModelID, $0.artifactSHA256) < ($1.runtimeModelID, $1.artifactSHA256) })
        #expect(Set(bundled).count == bundled.count)

        let line = try #require(ClusterPairQualificationRecordsBundled.jsonLines.split(separator: "\n")
            .first { $0.contains("registered_qwen35_9b") && $0.contains(#""passed":true"#) })
        let base = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        func record(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> ClusterPairQualificationRecord {
            var object = base; change(&object)
            return try JSONDecoder().decode(ClusterPairQualificationRecord.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let passing = try record()
        #expect(ClusterRuntimeApprovalFacts.qualifiedModels(records: [passing])
                == [.init(runtimeModelID: "registered_qwen35_9b", artifactSHA256: Self.qwenArtifact)])
        let excluded: [(String, ClusterPairQualificationRecord)] = [
            ("no stage adapter", try record { $0["runtimeModelID"] = "registered_unknown_model" }),
            ("diverged", try record { object in
                var comparisons = object["comparisons"] as! [[String: Any]]
                comparisons[0]["verdict"] = "diverged"; comparisons[0].removeValue(forKey: "gapInULPs")
                object["comparisons"] = comparisons; object["passed"] = false
            }),
            ("inconsistent", try record { $0["schema"] = "another_schema" }),
        ]
        for (label, excludedRecord) in excluded {
            #expect(ClusterRuntimeApprovalFacts.qualifiedModels(records: [excludedRecord]).isEmpty, "\(label)")
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

    /// The catalog aggregate a metadata fixture's manifest names.
    static func aggregate(of fixture: String) throws -> String {
        let data = try Data(contentsOf: Fixture.metadataFixtures.appendingPathComponent("\(fixture).manifest.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(object?["aggregate_sha256"] as? String)
    }

    /// Facts with three models (byte order: uppercase before lowercase), for the codec rows.
    static func facts() throws -> ClusterRuntimeApprovalFacts {
        func model(_ name: String, _ seed: Character) -> ClusterRuntimeApprovalFacts.Model {
            .init(model: name, artifactSHA256: String(repeating: seed, count: 64), capabilitySHA256: String(repeating: "c", count: 64),
                  profileSHA256: String(repeating: "d", count: 64), resourcePolicySHA256: String(repeating: "e", count: 64))
        }
        return try .init(nativeRuntimeSHA256: String(repeating: "1", count: 64), metallibSHA256: String(repeating: "2", count: 64),
            resourceLibrarySHA256: String(repeating: "3", count: 64), placementPolicySHA256: String(repeating: "4", count: 64),
            models: [model("EigenLabs/Qwen3.8-27B-4bit-mtp", "5"), model("Qwen3.5-9B", "6"), model("glm-5.3-flash", "7")])
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
