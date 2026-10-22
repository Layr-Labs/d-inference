import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

struct ModelCheckpointStorageArtifact: Codable, Sendable {
    let position: Int
    let backendLayout: String
    let usesLossyNativeCheckpoint: Bool
    let keyBits: Int?
    let valueBits: Int?
    let nativeDTypes: [String]?
    let encodedTensorBytes: Int
    let encryptedFileBytes: Int

    /// Authenticate every segment outside timed requests, retaining only the
    /// manifest. Never inspect the normal provider hierarchy or publish tokens,
    /// tenant strings, encryption keys, or plaintext checkpoint payloads.
    static func inspect(_ fixture: ModelPrefixBenchmarkFixture) async throws -> [Self]? {
        guard let namespace = fixture.persistentTestNamespace else { return nil }
        var environment = ModelPrefixBenchmarkFixture.checkpointEnvironment(root: fixture.root,
            soloPrefillStripeTokens: fixture.specification.soloPrefillStripeTokens)
        environment["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] = "1"
        let material = try await SSDCacheKeyMaterial.load(environment: environment,
            persistentTestNamespace: namespace)
        try #require(!material.ephemeral)
        let files = try checkpointFiles(in: fixture.root)
        var observations: [Self] = []
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            try #require(values.isRegularFile == true)
            var manifestData: Data?
            try SSDBlockStore.readStreaming(from: file, kekKey: material.key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: SSDPrefixCachePolicy.completeCheckpointMaxStageBytes(environment: environment),
                requireEOF: true, validateMetadata: { _ in },
                consumeChunk: { index, bytes in if index == 0 { manifestData = bytes } })
            let manifest = try SSDHybridCheckpointEnvelope.decodeManifest(#require(manifestData))
            try #require(manifest.identity.modelAggregateHash == fixture.specification.expectedWeightHash)
            try #require(manifest.backendLayout == fixture.session.checkpointBackendLayout)
            let encodedBytes = try manifest.validateStructure()
            observations.append(Self(position: manifest.position, backendLayout: manifest.backendLayout,
                usesLossyNativeCheckpoint: manifest.usesLossyNativeCheckpoint,
                keyBits: manifest.checkpointQuantization?.keyBits,
                valueBits: manifest.checkpointQuantization?.valueBits,
                nativeDTypes: manifest.checkpointNativeDTypes?.map(\.rawValue),
                encodedTensorBytes: encodedBytes, encryptedFileBytes: try #require(values.fileSize)))
        }
        return observations.sorted { $0.position < $1.position }
    }

    static func checkpointFiles(in root: URL) throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "dbk3" {
            files.append(file)
        }
        return files
    }
}
