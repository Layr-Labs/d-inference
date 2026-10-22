import CryptoKit
import DarkbloomClusterProtocol
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// The resident source a rank derives with no weight file: metadata from the
// pinned content inventory and the registered configuration and manifest
// bytes. Models are constructed lazily and nothing is evaluated. The last
// test compares with the file-backed derivation and runs only when
// DARKBLOOM_CLUSTER_REGISTERED_MODEL_DIR names the registered 9B artifact. It
// admits as the stage check does, from the process environment, so it needs
// the stage check's three arithmetic settings as well.

@Suite("Resident source from the pinned inventory (no weight files)")
struct ResidentPinnedSourceTests {
    private static let now: UInt64 = 1_000

    private static func fixture(_ model: String, _ name: String) throws -> Data {
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-\(model).\(name).json"))
    }

    /// An admission from the retained registered metadata alone; the model directory is never opened.
    private static func admission(_ model: QwenRegisteredDenseModel, cut: Int) throws -> QwenResidentAdmission {
        let spec = try #require(QwenDenseRegisteredSpecification.all.first { $0.model == model })
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: model.rawValue,
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            peers: [ClusterWorkerPeer(id: "peer-a", buildSHA256: String(repeating: "a", count: 64)),
                    ClusterWorkerPeer(id: "peer-b", buildSHA256: String(repeating: "b", count: 64))])
        let files = model == .qwen35NineB ? "qwen35-9b" : "qwen38-27b"
        return try QwenResidentAdmission(
            configuration: .init(identity: identity, modelDirectory: URL(fileURLWithPath: "/var/empty"), rank: 0,
                                 stageCut: cut, deadlineUptimeNanoseconds: now + 300_000_000_000),
            configBytes: try fixture(files, "configuration"), manifestBytes: try fixture(files, "manifest"),
            environment: ["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1",
                          "JACCL_RANK": "0", "JACCL_IBV_DEVICES": "/opt/cluster/matrix.json", "JACCL_COORDINATOR": "10.0.0.5:4499"],
            now: now, read: { _, _ in Data(#"[[null,"tb5-a"],["tb5-b",null]]"#.utf8) })
    }

    /// The storage commitment a load derives from a source, as `loadQwenResidentStage` assembles it.
    private static func commitment(_ source: QwenResidentSource, _ admission: QwenResidentAdmission) throws -> String {
        let inventories = try admission.plan.stages.map { stage in
            let inventory = try withRandomState(MLXRandom.RandomState(seed: 7)) {
                try inspectOtherQwenLayerStage(source: source.source, stage: stage, check: {})
            }
            try QwenDenseObservedStageValidation.validateRegistered(source: source.validation, profile: source.profile,
                requirement: source.pairRequirement, plan: admission.plan, stageIndex: stage.index,
                active: inventory.active, inert: inventory.inert, summary: inventory.summary)
            return inventory
        }
        return sha256(try canonicalJSONData(qwenLayerStageStorageCommitment(source: source.source,
            originalConfiguration: admission.configBytes, plan: admission.plan, inventories: inventories)))
    }

    @Test(arguments: [
        (4, "e2e41be21c400e180645a3c0a10e8905ca71b4a48d558c8406c5dd0e66f0bb4f"),
        (8, "2b848d3d8f0302948d49ab3215d6fcd1bce55322e22cfa65006f677ea2ef536f"),
        (12, "2004594baaa2f8db889d4d674cb5290a89dbbfa5582dbade9c73de5d5fc95c85"),
        (16, "a3a852726b2cce3420a13eb345c46903deafc07ce2771ce678e1a0675b7e341d"),
    ])
    func thePinnedSourceCommitsToWhatALocalLoadRecorded(cut: Int, recorded: String) throws {
        let admission = try Self.admission(.qwen35NineB, cut: cut)
        let pinned = try prepareQwenResidentPinnedSource(admission, check: {})
        #expect(pinned.source.tensors.count == 927 && pinned.source.sourceTensorCount == 927)
        #expect(pinned.source.sourceBytes == 5_038_041_600 && pinned.source.largestSourceBytes == 508_559_360)
        #expect(pinned.source.verifiedAggregateSHA256 == admission.specification.artifactSHA256)
        #expect(pinned.source.activationDType == .bfloat16 && pinned.source.bf16ConversionEnabled)
        // The value verified local loads of the artifact recorded for this cut.
        #expect(try Self.commitment(pinned, admission) == recorded)
    }

    @Test func aModelWithNoPinnedInventoryIsRefused() throws {
        let admission = try Self.admission(.qwen38TwentySevenB, cut: 32)
        let refusal = #expect(throws: ProbeError.self) { _ = try prepareQwenResidentPinnedSource(admission, check: {}) }
        #expect(refusal?.description == "Registered model has no pinned content inventory")
    }

    @Test func anInventoryThatDiffersFromItsPinIsRefused() throws {
        let spec = try #require(QwenDenseRegisteredSpecification.all.first { $0.model == .qwen35NineB })
        let document = try #require(QwenRegisteredContentInventory.document(.qwen35NineB))
        // One content digest changed: still canonical, still the pinned layout, another hash.
        let changed = String(document.dropLast(2)) + (document.dropLast().last == "0" ? "1" : "0") + "\n"
        #expect(try QwenRegisteredContentInventory.admit(document: changed, pin: sha256(Data(changed.utf8)),
            layoutInventorySHA256: spec.inventorySHA256) != nil)
        let refusal = #expect(throws: ProbeError.self) {
            _ = try QwenRegisteredContentInventory.admit(document: changed, pin: spec.contentInventorySHA256,
                                                         layoutInventorySHA256: spec.inventorySHA256)
        }
        #expect(refusal?.description == "Registered content inventory differs from its pinned SHA-256")
    }

    @Test func metadataFilesAreHeldToTheirManifestPins() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-files-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["config.json": Data(#"{"arch":"fixture"}"#.utf8), "tokenizer.json": Data((0..<4096).map { UInt8($0 % 251) })]
        func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        // The weight file is listed, absent from disk, and never asked for.
        var entries: [[String: Any]] = [["path": "model-00001-of-00001.safetensors", "sha256": String(repeating: "0", count: 64), "size_bytes": 1 << 30]]
        for (name, data) in files {
            try data.write(to: root.appendingPathComponent(name))
            entries.append(["path": name, "sha256": hex(data), "size_bytes": data.count])
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["aggregate_sha256": String(repeating: "0", count: 64),
            "file_count": entries.count, "total_size_bytes": (1 << 30) + 4114, "files": entries], options: [.sortedKeys])
        let verified = try QwenResidentMetadataFiles.verify(directory: root, manifest: manifest)
        #expect(verified.fileCount == 2 && verified.byteCount == 4114)

        var flipped = files["tokenizer.json"]!
        flipped[100] ^= 1
        try flipped.write(to: root.appendingPathComponent("tokenizer.json"))
        let changed = #expect(throws: ProbeError.self) { _ = try QwenResidentMetadataFiles.verify(directory: root, manifest: manifest) }
        #expect(changed?.description == "Metadata file differs from its manifest SHA-256: tokenizer.json")
        func refusal() -> String? {
            #expect(throws: ProbeError.self) { _ = try QwenResidentMetadataFiles.verify(directory: root, manifest: manifest) }?.description
        }
        try (flipped + Data([0])).write(to: root.appendingPathComponent("tokenizer.json"))
        #expect(refusal() == "Checkpoint file size/type mismatch: tokenizer.json")
        try FileManager.default.removeItem(at: root.appendingPathComponent("tokenizer.json"))
        #expect(refusal() == "Cannot open checkpoint file tokenizer.json")
        // The right bytes behind a link are still refused: the file itself must be there.
        try files["tokenizer.json"]!.write(to: root.appendingPathComponent("elsewhere"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("tokenizer.json"),
                                                   withDestinationURL: root.appendingPathComponent("elsewhere"))
        #expect(refusal() == "Cannot open checkpoint file tokenizer.json")
        // A manifest whose metadata files sit in a subdirectory is not one this check reads.
        let nested = try JSONSerialization.data(withJSONObject: ["aggregate_sha256": String(repeating: "0", count: 64),
            "file_count": 1, "total_size_bytes": 4, "files": [["path": "sub/config.json", "sha256": String(repeating: "0", count: 64), "size_bytes": 4]]],
            options: [.sortedKeys])
        let unbounded = #expect(throws: ProbeError.self) { _ = try QwenResidentMetadataFiles.verify(directory: root, manifest: nested) }
        #expect(unbounded?.description == "Registered manifest has no bounded top-level metadata files")
    }

    /// Hashes the registered artifact once per cut (about 6 GB each). No tensor is materialized.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_CLUSTER_REGISTERED_MODEL_DIR"] != nil),
          arguments: [4, 8, 12, 16])
    func thePinnedSourceEqualsTheFileBackedSource(cut: Int) throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DARKBLOOM_CLUSTER_REGISTERED_MODEL_DIR"]))
        let admission = try QwenResidentStageLoadCheck.admit(modelDirectory: directory, rank: 1, stageCut: cut,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 280_000_000_000)
        try #require(admission.specification.model == .qwen35NineB)
        let local = try prepareQwenResidentSource(admission, check: {}).metadata
        let pinned = try prepareQwenResidentPinnedSource(admission, check: {})
        #expect(try canonicalJSONData(pinned.source.tensors) == canonicalJSONData(local.source.tensors))
        #expect(pinned.source.mappings == local.source.mappings)
        #expect(pinned.source.quantization.keys.sorted().map { "\($0)=\(String(describing: pinned.source.quantization[$0]))" }
            == local.source.quantization.keys.sorted().map { "\($0)=\(String(describing: local.source.quantization[$0]))" })
        #expect(pinned.source.sourceTensorManifestSHA256 == local.source.sourceTensorManifestSHA256)
        #expect(pinned.source.sourceParameterLayoutSHA256 == local.source.sourceParameterLayoutSHA256)
        #expect(pinned.source.verifiedAggregateSHA256 == local.source.verifiedAggregateSHA256)
        #expect(pinned.source.sourceTensorCount == local.source.sourceTensorCount)
        #expect(pinned.source.sourceBytes == local.source.sourceBytes)
        #expect(pinned.source.largestSourceBytes == local.source.largestSourceBytes)
        #expect(pinned.source.activationDType == local.source.activationDType)
        #expect(pinned.source.hiddenSize == local.source.hiddenSize && pinned.source.vocabularySize == local.source.vocabularySize)
        #expect(pinned.validation.expectedLayoutSHA256 == local.validation.expectedLayoutSHA256)
        #expect(pinned.pairRequirement.fingerprint == local.pairRequirement.fingerprint)
        #expect(pinned.profile.fingerprint == local.profile.fingerprint)
        #expect(try Self.commitment(pinned, admission) == Self.commitment(local, admission))
        let metadata = try QwenResidentMetadataFiles.verify(admission)
        #expect(metadata.fileCount == 9 && metadata.byteCount == 26_846_742)
    }
}
