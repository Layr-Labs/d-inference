import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Bonsai 9B registered metadata and pipeline admission")
struct ResidentAdmissionBonsai9Tests {
    private typealias F = Bonsai9Fixture

    @Test func exactArtifactAndHeaderBindTheNewRow() throws {
        let spec = try F.specification(), inventory = try F.inventory()
        #expect(sha256(try F.data("configuration")) == spec.configurationSHA256)
        #expect(sha256(try F.data("manifest")) == spec.manifestSHA256)
        #expect(sha256(try F.data("header")) == "3ac34a22f409632a5db6984373649c03a2ec463152a9d7965ce588df24ddc3e0")
        #expect(sha256(try F.data("hadamard")) == "6d0b37a136e1b5b25b3e8b0467599c78dd0a90c341b640a1f49271cb0be7c73b")
        let profile = try QwenRegisteredDenseModelProfile.admit(configuration: F.data("configuration"),
            manifest: F.data("manifest"), expectedArtifactAggregateSHA256: spec.artifactSHA256, canonicalTensors: inventory)
        #expect(profile.model == F.model)
        #expect(inventory.count == 831 && spec.tensorCount == inventory.count)
        #expect(QwenDenseProfileIdentity.fingerprint(inventory.map(\.identity)) == spec.inventorySHA256)
        #expect(inventory.reduce(0) { $0 + $1.byteCount } == spec.sourceBytes && spec.sourceBytes == 2_545_600_512)
        #expect(inventory.map(\.byteCount).max() == 254_279_680)
        let signs = try F.header().filter { $0.key.hasSuffix(".signs") }
        #expect(signs.count == 202 && signs.values.reduce(0) { $0 + $1.bytes } == 4_358_144)
        #expect(try QwenRegisteredContentInventory.admit(spec) == nil)
    }

    @Test func pipelineRowAndMemoryAreSpecificToNineB() throws {
        let definition = try QwenResidentModelDefinition(model: F.model)
        #expect(definition.supportedCuts == F.cuts)
        #expect(definition.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit])
        #expect(definition.speculativeDecodeFactor == nil)
        #expect(definition.adapter == .qwen35PrismHadamard && definition.arithmetic == .prismHadamard)
        #expect(try QwenResidentModelDefinition(configuration: F.data("configuration")).specification.model == F.model)
        #expect(ClusterRuntimeAdapter.qwen35PrismHadamard.runtimeModelID == BonsaiFixture.modelID)
        let profile = try QwenResidentAdapterDefinition.profile(specification: definition.specification)
        #expect(profile.hiddenSize == 4096 && profile.activationDType == "float32")
        #expect(profile.maximumContextTokens == 65_536)
        let ceiling = try QwenResidentResourceCeilings(model: F.model)
        #expect(ceiling.maximumManifestPayloadBytes == 3_475_181_460)
        #expect(ceiling.maximumNamedStateBytes == 754_188_320)
        #expect(try QwenLongPrefillTensorBudget.estimate(geometry: definition.specification.expectedGeometry(),
            maximumTokens: 8193, chunkSize: 512).conservativeStateAndBoundaryBytes == 745_345_056)
        #expect(try QwenResidentResourceCeilings(model: .ternaryBonsai2TwentySevenB).maximumManifestPayloadBytes == 8_608_670_713)
        #expect(try QwenResidentResourceCeilings(model: .qwen35NineB).maximumManifestPayloadBytes == 8 << 30)
    }

    @Test func capabilityRoundTripsTheNewProfileWithoutChangingTheExistingDefault() throws {
        let capability = try QwenResidentCapabilityMetadata.describe(configuration: F.data("configuration"),
            manifest: F.data("manifest"), runtimeBinarySHA256: String(repeating: "1", count: 64))
        #expect(capability.runtimeModelID == F.model.rawValue)
        #expect(capability.profile.id == "registered_ternary_bonsai_2_9b_greedy_generation_v1")
        #expect(capability.adapterID == ClusterRuntimeAdapter.qwen35PrismHadamard.rawValue)
        #expect(capability.partitions.count == 7 && capability.speculation == "off")
        #expect(capability.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit])
        #expect(try ClusterRuntimeCapabilityCodec.decode(ClusterRuntimeCapabilityCodec.encode(capability)) == capability)
    }

    @Test func everyStructuralCutAgreesAndCrossPackIdentityFails() throws {
        for cut in F.cuts {
            let identity = try F.identity()
            let leader = try F.admit(cut: cut, identity: identity), follower = try F.admit(rank: 1, cut: cut, identity: identity)
            #expect(leader.plan.stages.map(\.sourceRange) == [0..<cut, cut..<32])
            #expect(try leader.loadAgreementFingerprint() == follower.loadAgreementFingerprint())
            for stage in leader.plan.stages {
                let records = try QwenPrismStageConfiguration.stageModules(constructionConfiguration: stage.constructionConfiguration)
                #expect(!records.isEmpty && records.allSatisfy { $0.block == 4096 })
            }
        }
        for cut in [0, 2, 6, 30, 32, 60] {
            #expect(throws: (any Error).self) { _ = try F.admit(cut: cut) }
        }
        for model in [QwenRegisteredDenseModel.ternaryBonsai2TwentySevenB, .qwen35NineB] {
            #expect(throws: (any Error).self) { _ = try F.admit(identity: F.identity(modelID: model.rawValue)) }
        }
        #expect(throws: (any Error).self) {
            _ = try F.admit(configuration: BonsaiFixture.data("configuration"), manifest: BonsaiFixture.data("manifest"))
        }
        #expect(throws: (any Error).self) {
            _ = try BonsaiFixture.admit(BonsaiFixture.configuration(cut: 16, identity: BonsaiFixture.identity()),
                                       config: F.data("configuration"), manifest: F.data("manifest"))
        }
    }

    @Test func transformBlocksRemainClosedAndPreserved() throws {
        var root = try #require(JSONSerialization.jsonObject(with: F.data("configuration")) as? [String: Any])
        let declaration = try #require(try QwenPrismStageConfiguration.admit(root: root, nested: true))
        #expect(declaration.modules.count == 202 && declaration.modules.allSatisfy { $0.block == 4096 })
        let oldRoot = try #require(JSONSerialization.jsonObject(with: BonsaiFixture.data("configuration")) as? [String: Any])
        #expect(try QwenPrismStageConfiguration.admit(root: oldRoot, nested: true)?.modules.allSatisfy { $0.block == 1024 } == true)
        let original = try #require(root["modules"] as? [[String: Any]])
        for block in [0, 512, 2048, 8192] {
            root["modules"] = original.map { var record = $0; record["block"] = block; return record }
            #expect(throws: (any Error).self) { _ = try QwenPrismStageConfiguration.admit(root: root, nested: true) }
        }
        var mixed = original; mixed[0]["block"] = 1024; root["modules"] = mixed
        #expect(throws: (any Error).self) { _ = try QwenPrismStageConfiguration.admit(root: root, nested: true) }
        // Even another valid block is not this registered artifact's configuration.
        root["modules"] = original.map { var record = $0; record["block"] = 1024; return record }
        #expect(throws: (any Error).self) { _ = try F.admit(configuration: JSONSerialization.data(withJSONObject: root)) }
    }
}
