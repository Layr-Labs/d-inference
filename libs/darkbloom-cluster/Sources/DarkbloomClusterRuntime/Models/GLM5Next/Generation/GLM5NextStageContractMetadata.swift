import Foundation
import MLXLLM

/// Pure shared identity arithmetic. This value cannot construct a stage binding
/// or establish payload custody; the verified-loader contract still owns LOAD.
struct GLM5NextStageContractMetadata {
    let source: QwenLayerStageWireSourceIdentity
    let stageFingerprints: [String]
    let constructionConfigurationSHA256: String
    let numericalPolicySHA256: String
    let configuration: GLM5NextConfiguration
    let executionPolicy: GLM5NextExecutionPolicy
    let storage: GLM5NextWeightInventory.Storage
    let artifactIdentitySHA256: String
    let plans: [GLM5NextTextStagePlan]

    init(configuration: GLM5NextConfiguration, artifactIdentity: GLM5NextArtifactIdentity,
         storage: GLM5NextWeightInventory.Storage, executionPolicy: GLM5NextExecutionPolicy,
         artifactAggregateSHA256: String, storageCommitmentSHA256: String,
         cut: Int, loadMTPEmbedding: Bool = false) throws {
        guard let configFile = artifactIdentity.files["config.json"],
              qwenStageWireIsSHA256(artifactAggregateSHA256),
              qwenStageWireIsSHA256(storageCommitmentSHA256),
              cut > 0, cut < configuration.textConfig.hiddenLayers else {
            throw ProbeError("GLM contract requires a verified source and an interior two-stage cut")
        }
        let plans = try [
            GLM5NextTextStagePlan(configuration: configuration.textConfig, layers: 0..<cut),
            GLM5NextTextStagePlan(configuration: configuration.textConfig,
                layers: cut..<configuration.textConfig.hiddenLayers, loadMTPEmbedding: loadMTPEmbedding),
        ]
        let constructionHash = sha256(try canonicalJSONData(configuration.textConfig))
        let artifactHash = try Self.artifactHash(artifactIdentity)
        let policyHash = try GLM5NextStageContract.policySHA256(executionPolicy)
        let storageName: String
        switch storage {
        case .float32: storageName = "float32"
        case .vontraQ4: storageName = "vontraQ4"
        case .affineMixed: storageName = "affineMixed"
        case .nvfp4Hybrid: storageName = "nvfp4Hybrid"
        }
        let planHash = sha256(try canonicalJSONData([
            "schema": "glm5-next-stage-plan-v1",
            "artifactIdentitySHA256": artifactHash,
            "artifactAggregateSHA256": artifactAggregateSHA256,
            "sourceConfigurationSHA256": configFile.sha256,
            "constructionConfigurationSHA256": constructionHash,
            "storageCommitmentSHA256": storageCommitmentSHA256,
            "storage": storageName,
            "numericalPolicySHA256": policyHash,
            "cut": String(cut),
            "hiddenLayers": String(configuration.textConfig.hiddenLayers),
            "finalLoadsMTPEmbedding": loadMTPEmbedding ? "true" : "false",
        ]))
        let fingerprints = try plans.enumerated().map { rank, plan in
            sha256(try canonicalJSONData([
                "schema": "glm5-next-stage-v1", "planFingerprint": planHash,
                "rank": String(rank), "lower": String(plan.layers.lowerBound),
                "upper": String(plan.layers.upperBound),
                "loadsMTPEmbedding": plan.loadsMTPEmbedding ? "true" : "false",
            ]))
        }
        self.configuration = configuration
        self.executionPolicy = executionPolicy
        self.storage = storage
        self.artifactIdentitySHA256 = artifactHash
        self.plans = plans
        self.constructionConfigurationSHA256 = constructionHash
        self.numericalPolicySHA256 = policyHash
        self.stageFingerprints = fingerprints
        source = try .init(sourceConfigurationSHA256: configFile.sha256,
            artifactAggregateSHA256: artifactAggregateSHA256,
            storageCommitmentSHA256: storageCommitmentSHA256,
            planFingerprint: planHash, producerStageFingerprint: fingerprints[0])
    }

    /// Both ranks commit the same complete inventory and cut. Allocator bounds
    /// and rank are deliberately absent, exactly as in resident LOAD accounting.
    static func storageCommitment(inventory: GLM5NextWeightInventory, cut: Int,
                                  includeMTP: Bool) throws -> String {
        guard cut > 0, cut < inventory.configuration.textConfig.hiddenLayers else {
            throw ProbeError("GLM storage commitment requires an interior two-stage cut")
        }
        return try storageCommitment(inventorySHA256: GLM5NextArtifactMetadata.fingerprint(inventory),
            cut: cut, includeMTP: includeMTP)
    }

    /// The same commitment from a pinned inventory digest, for capability
    /// metadata that names every cut without reading shard headers.
    static func storageCommitment(inventorySHA256: String, cut: Int, includeMTP: Bool) throws -> String {
        sha256(try canonicalJSONData([
            "schema": "glm5-next-resident-storage-v1",
            "inventorySHA256": inventorySHA256,
            "cut": String(cut), "includesMTP": includeMTP ? "true" : "false",
        ]))
    }

    static func artifactHash(_ identity: GLM5NextArtifactIdentity) throws -> String {
        struct File: Encodable {
            let name: String
            let bytes: Int
            let sha256: String
        }
        struct Record: Encodable {
            let schema = "glm5-next-artifact-identity-v1"
            let repository: String
            let revision: String
            let files: [File]
        }
        let files = identity.files.keys.sorted().map { name in
            File(name: name, bytes: identity.files[name]!.bytes, sha256: identity.files[name]!.sha256)
        }
        return sha256(try canonicalJSONData(Record(repository: identity.repository,
            revision: identity.revision, files: files)))
    }
}
