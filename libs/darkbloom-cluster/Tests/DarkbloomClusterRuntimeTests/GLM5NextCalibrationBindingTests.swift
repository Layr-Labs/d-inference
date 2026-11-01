import DarkbloomClusterProtocol
import Foundation
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// Real tiny SDK files and verified loader; no tensor read or model construction.
@Suite("GLM calibration metadata binding", .serialized)
struct GLM5NextCalibrationBindingTests {
    private let aggregate = String(repeating: "b", count: 64)

    private func descriptor(
        artifact: GLM5NextStageSessionTests.Artifact, identity: GLM5NextArtifactIdentity,
        cut: Int = 3, policy: GLM5NextExecutionPolicy = .reference,
        aggregate: String? = nil, configuration: Data? = nil,
        storage: GLM5NextWeightInventory.Storage = .float32,
        profileID: String = "glm-calibration-binding-fixture",
        prompt: Int = 128, chunk: Int = 16, output: Int = 8, context: Int = 256
    ) throws -> GLM5NextResidentDescriptor {
        try .init(modelID: "glm-calibration-binding-fixture", artifactIdentity: identity,
            artifactAggregateSHA256: aggregate ?? self.aggregate,
            configurationBytes: configuration ?? Data(contentsOf: artifact.url("config.json")),
            cut: cut, storage: storage, executionPolicy: policy, profileID: profileID,
            maximumPromptTokens: prompt, maximumChunkTokens: chunk,
            maximumOutputTokens: output, maximumContextTokens: context)
    }

    @Test(arguments: [1, 3, 7])
    func metadataMatchesActualVerifiedLoaderContractForBothRanks(cut: Int) throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let descriptor = try descriptor(artifact: artifact, identity: loader.identity, cut: cut)
        let inventory = try descriptor.inspectInventory(directory: artifact.directory)
        let binding = try GLM5NextCalibration.binding(descriptor: descriptor, inventory: inventory)
        let c = loader.configuration.textConfig
        #expect(binding.profile == ClusterWorkerProfile(
            id: "glm-calibration-binding-fixture", vocabularySize: c.vocabularySize,
            maximumPromptTokens: 128, maximumOutputTokens: 8,
            maximumChunkTokens: 16, maximumContextTokens: 256))
        #expect(binding.executionPlanSHA256 != descriptor.fingerprint)
        var stageFingerprints: [String] = []
        for rank in 0...1 {
            let resources = try GLM5NextStageLoadResourcesTests.resources(
                loader.inventory, rank: rank, cut: cut, mtp: false)
            let contract = try GLM5NextStageContract(loader: loader,
                artifactAggregateSHA256: aggregate,
                storageCommitmentSHA256: resources.storageCommitmentSHA256, cut: cut)
            #expect(binding.executionPlanSHA256 == contract.source.planFingerprint)
            stageFingerprints.append(contract.stageFingerprints[rank])
        }
        #expect(stageFingerprints[0] != stageFingerprints[1])
        try loader.verifyUnchanged()
    }

    @Test func profileScopeIsComparedSeparatelyFromCommonStagePlan() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let first = try descriptor(artifact: artifact, identity: loader.identity)
        let changed = try descriptor(artifact: artifact, identity: loader.identity,
            profileID: "smaller-cold-request", prompt: 64, chunk: 8, output: 4, context: 128)
        let original = try GLM5NextCalibration.binding(descriptor: first, inventory: loader.inventory)
        let smaller = try GLM5NextCalibration.binding(descriptor: changed, inventory: loader.inventory)
        #expect(original.executionPlanSHA256 == smaller.executionPlanSHA256)
        #expect(original.profile != smaller.profile)
        #expect(original != smaller)
        #expect(smaller.profile.id == "smaller-cold-request")
        #expect(smaller.profile.vocabularySize == loader.configuration.textConfig.vocabularySize)
        #expect(smaller.profile.maximumPromptTokens == 64)
        #expect(smaller.profile.maximumOutputTokens == 4)
        #expect(smaller.profile.maximumChunkTokens == 8)
        #expect(smaller.profile.maximumContextTokens == 128)
    }

    @Test func exactArtifactSourceCutAndPolicyChangesCannotReusePlanIdentity() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let first = try descriptor(artifact: artifact, identity: loader.identity)
        let baseline = try GLM5NextCalibration.binding(descriptor: first, inventory: loader.inventory)
        func requireDifferent(_ changed: GLM5NextResidentDescriptor) throws {
            let actual = try GLM5NextCalibration.binding(descriptor: changed, inventory: loader.inventory)
            #expect(actual.executionPlanSHA256 != baseline.executionPlanSHA256)
        }
        try requireDifferent(descriptor(artifact: artifact, identity: loader.identity, cut: 2))
        try requireDifferent(descriptor(artifact: artifact, identity: loader.identity,
            aggregate: String(repeating: "c", count: 64)))
        var policy = GLM5NextExecutionPolicy.reference
        policy.stepEvaluation = .earlyAsync
        try requireDifferent(descriptor(artifact: artifact, identity: loader.identity, policy: policy))
        let revision = GLM5NextArtifactIdentity(repository: loader.identity.repository,
            revision: String(repeating: "d", count: 40), files: loader.identity.files)
        try requireDifferent(descriptor(artifact: artifact, identity: revision))
        let repository = GLM5NextArtifactIdentity(repository: "synthetic/other-glm-binding",
            revision: loader.identity.revision, files: loader.identity.files)
        try requireDifferent(descriptor(artifact: artifact, identity: repository))
        var files = loader.identity.files
        let shard = try #require(files["a.safetensors"])
        files["a.safetensors"] = .init(bytes: shard.bytes, sha256: String(repeating: "e", count: 64))
        let changedShard = GLM5NextArtifactIdentity(repository: loader.identity.repository,
            revision: loader.identity.revision, files: files)
        try requireDifferent(descriptor(artifact: artifact, identity: changedShard))
        files = loader.identity.files
        let index = try #require(files["model.safetensors.index.json"])
        files["model.safetensors.index.json"] = .init(bytes: index.bytes + 1, sha256: index.sha256)
        let changedSize = GLM5NextArtifactIdentity(repository: loader.identity.repository,
            revision: loader.identity.revision, files: files)
        try requireDifferent(descriptor(artifact: artifact, identity: changedSize))
        // Same decoded configuration, different authoritative raw-file bytes.
        var config = try Data(contentsOf: artifact.url("config.json"))
        config.append(10)
        files = loader.identity.files
        files["config.json"] = .init(bytes: config.count, sha256: sha256(config))
        let changedConfig = GLM5NextArtifactIdentity(repository: loader.identity.repository,
            revision: loader.identity.revision, files: files)
        let rawChanged = try descriptor(artifact: artifact, identity: changedConfig, configuration: config)
        #expect(rawChanged.configuration == first.configuration)
        try requireDifferent(rawChanged)
    }

    @Test func mismatchedConfigurationStorageAndUndeclaredShardsAreRejected() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let descriptor = try descriptor(artifact: artifact, identity: loader.identity)
        let foreign = try GLM5NextMetadataTestFixture(layers: 7)
        #expect(throws: ProbeError.self) {
            try GLM5NextCalibration.binding(descriptor: descriptor, inventory: foreign.inventory)
        }
        let packed = try self.descriptor(artifact: artifact, identity: loader.identity, storage: .nvfp4Hybrid)
        #expect(throws: ProbeError.self) {
            try GLM5NextCalibration.binding(descriptor: packed, inventory: loader.inventory)
        }
        let tensors = loader.inventory.entries.values.map {
            GLM5NextWeightInventory.Tensor(name: $0.tensor.name, shape: $0.tensor.shape,
                dtype: $0.tensor.dtype, shard: "undeclared.safetensors")
        }
        let wrongShards = try GLM5NextWeightInventory.validate(
            configuration: loader.configuration, tensors: tensors, storage: .float32)
        #expect(throws: ProbeError.self) {
            try GLM5NextCalibration.binding(descriptor: descriptor, inventory: wrongShards)
        }
    }

    @Test func extraMetadataFilesCannotEnterNativeWeightIdentity() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        var files = loader.identity.files
        let metadata = Data("{}".utf8)
        files["metadata.json"] = .init(bytes: metadata.count, sha256: sha256(metadata))
        let fullManifestIdentity = GLM5NextArtifactIdentity(repository: loader.identity.repository,
            revision: loader.identity.revision, files: files)
        let withExtra = try descriptor(artifact: artifact, identity: fullManifestIdentity)
        #expect(throws: ProbeError.self) {
            try GLM5NextCalibration.binding(descriptor: withExtra, inventory: loader.inventory)
        }
        // The metadata projection must not admit a file scope the actual SDK
        // loader rejects before reading any tensor payload or constructing MLX arrays.
        #expect(throws: (any Error).self) {
            try GLM5NextArtifactLoader(directory: artifact.directory,
                expectedIdentity: fullManifestIdentity, storage: .float32)
        }
        let strict = try descriptor(artifact: artifact, identity: loader.identity)
        _ = try GLM5NextCalibration.binding(descriptor: strict, inventory: loader.inventory)
        try loader.verifyUnchanged()
    }

    @Test func invalidCutsAndProfileBoundsAreRejected() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        for cut in [-1, 0, 8, Int.max] {
            #expect(throws: ProbeError.self) {
                try descriptor(artifact: artifact, identity: loader.identity, cut: cut)
            }
            #expect(throws: ProbeError.self) {
                try GLM5NextStageContractMetadata.storageCommitment(
                    inventory: loader.inventory, cut: cut, includeMTP: false)
            }
        }
        #expect(throws: ProbeError.self) {
            try descriptor(artifact: artifact, identity: loader.identity, prompt: 0)
        }
        #expect(throws: ProbeError.self) {
            try descriptor(artifact: artifact, identity: loader.identity, prompt: 8, chunk: 9)
        }
    }

    @Test func calibrationBindingCannotReuseMTPContract() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let descriptor = try descriptor(artifact: artifact, identity: loader.identity)
        let binding = try GLM5NextCalibration.binding(descriptor: descriptor, inventory: loader.inventory)
        for rank in 0...1 {
            let resources = try GLM5NextStageLoadResourcesTests.resources(loader.inventory, rank: rank, mtp: true)
            let mtp = try GLM5NextStageContract(loader: loader, artifactAggregateSHA256: aggregate,
                storageCommitmentSHA256: resources.storageCommitmentSHA256,
                cut: 3, loadMTPEmbedding: true)
            #expect(binding.executionPlanSHA256 != mtp.source.planFingerprint)
        }
    }

    @Test func projectionNeedsNoFilesAndCannotReplaceVerifiedCustody() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let descriptor = try descriptor(artifact: artifact, identity: loader.identity)
        let before = try GLM5NextCalibration.binding(descriptor: descriptor, inventory: loader.inventory)
        try FileManager.default.removeItem(at: artifact.url("a.safetensors"))
        let after = try GLM5NextCalibration.binding(descriptor: descriptor, inventory: loader.inventory)
        #expect(before == after)
        #expect(throws: (any Error).self) { try loader.verifyUnchanged() }
    }

    @Test func codableProjectionRoundTripsButChangedClaimFailsComparison() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let descriptor = try descriptor(artifact: artifact, identity: loader.identity)
        let binding = try GLM5NextCalibration.binding(descriptor: descriptor, inventory: loader.inventory)
        let bytes = try canonicalJSONData(binding)
        #expect(try JSONDecoder().decode(GLM5NextCalibration.Binding.self, from: bytes) == binding)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == ["profile", "executionPlanSHA256"])
        var profile = try #require(object["profile"] as? [String: Any])
        #expect(Set(profile.keys) == ["id", "vocabularySize", "maximumPromptTokens",
            "maximumOutputTokens", "maximumChunkTokens", "maximumContextTokens"])
        profile["maximumChunkTokens"] = 1
        object["profile"] = profile
        let changed = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(GLM5NextCalibration.Binding.self, from: changed) != binding)
        object["executionPlanSHA256"] = "not-a-plan-sha"
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GLM5NextCalibration.Binding.self, from: invalid)
        }
    }
}
