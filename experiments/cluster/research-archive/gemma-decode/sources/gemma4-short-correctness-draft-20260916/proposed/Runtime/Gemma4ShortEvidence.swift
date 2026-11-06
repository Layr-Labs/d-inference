import Foundation

struct Gemma4ShortDescription: Encodable {
    struct Target: Encodable {
        let name: String, parameterLayoutSHA256: String
        let selectedTensorCount: Int, selectedBytes: Int
        let globalLayerIndices: [Int]
    }
    let schema = "gemma4_short_expected_v1"
    let scopeSHA256: String, membershipEpoch: String, buildIdentitySHA256: String
    let requestID: String, requestSHA256: String, promptFileSHA256: String, promptTokenIDsSHA256: String
    let profile: QwenLayerStageGenerationProfile
    let planSHA256: String, stageSHA256: [String], mappingSHA256: String
    let targets: [Target]
    let artifactSHA256 = Gemma4ArtifactMetadata.artifactAggregateSHA256
    let configurationSHA256 = Gemma4ArtifactMetadata.configurationSHA256
    let manifestSHA256 = Gemma4ArtifactMetadata.manifestSHA256
    let cut = 10, promptCount = 32, chunkSize = 16, outputCount = 2, maximumTokens = 34, finalFrontier = 33
    let stopTokenIDs: [Int] = []
    let metadataOnly = true, actualPayloadLoaded = false, actualKVTypeObserved = false
    let buildIdentityRequiresParentVerification = true, runtimeExecutionAuthorized = false
}

struct Gemma4ShortSessionBinding: Codable {
    struct Layer: Codable {
        let localIndex: Int, globalIndex: Int, kvHeads: Int, headDimension: Int, window: Int
        let dtype: String
    }
    let target: String, planSHA256: String, artifactSHA256: String, configurationSHA256: String
    let parameterLayoutSHA256: String, stateLayoutSHA256: String, readAccountingSHA256: String
    let selectedTensorCount: Int, selectedBytes: Int, maximumTokens: Int, maximumChunkTokens: Int
    let layers: [Layer]
    let probePrefillTokens: Int, probeDecodeTokens: Int
}

struct Gemma4ShortFile: Codable {
    let name: String, bytes: Int, sha256: String
}
struct Gemma4ShortRow: Encodable {
    let ordinal: Int, frontier: Int, tokenID: Int, maximumTieCount: Int
    let file: Gemma4ShortFile
    let dtype: String, logicalBytesSHA256: String
}
struct Gemma4ShortState: Encodable {
    struct Entry: Encodable {
        let localLayerIndex: Int, globalLayerIndex: Int
        let component: String, dtype: String, sha256: String
        let shape: [Int], byteCount: Int, logicalRange: [Int]
        let file: Gemma4ShortFile
    }
    let frontier: Int, fingerprint: String, entries: [Entry]
}
struct Gemma4ShortFrame: Encodable {
    let sequence: Int, frontier: Int, tokenIDsSHA256: String
    let boundarySHA256: String?
}
struct Gemma4ShortExecution: Encodable {
    let binding: Gemma4ShortSessionBinding
    let sourceLoad: Gemma4ForwardLoadReceipt
    let selectedTokenIDs: [Int], selectedTokenIDsSHA256: String
    let frames: [Gemma4ShortFrame], rows: [Gemma4ShortRow], finalState: Gemma4ShortState
    let files: [Gemma4ShortFile]
    let finishReason = "length", committedTokens = 33
    let requestStateRetired = true, modelReleaseNotYetEstablished = true
    let mtpEnabled = false, throughputMeasurementValid = false, numericalComparisonPerformed = false
}
