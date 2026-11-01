import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
@testable import ProviderCore

/// The GLM manifest a Mac downloads (the CDN's `manifest.json`, kept byte for byte with its `config.json` in the
/// worker's capability fixtures) through the cluster worker's describe path, the cluster store's manifest parser and
/// the product store's receipt. Metadata only: no weights, no network, no GPU work.
@Suite("GLM downloaded manifest pin (CPU)")
struct ClusterGLMManifestPinTests {
    private static let binary = String(repeating: "1", count: 64)

    private static func fixture(_ kind: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.lastPathComponent != "provider-swift", root.path != "/" { root.deleteLastPathComponent() }
        root.deleteLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent(
            "libs/darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-glm53-flash.\(kind).json"))
    }

    /// The worker describes the downloaded bytes as the registered row, as text and as the local image candidate the
    /// GLM local qualification selects.
    @Test func workerDescribesTheDownloadedManifest() throws {
        let configuration = try Self.fixture("configuration"), manifest = try Self.fixture("manifest")
        #expect(ClusterConfigurationCodec.sha256(manifest) == ClusterGLMImageCandidate.manifestSHA256)
        let text = try ClusterResidentModelCatalog.describe(configuration: configuration, manifest: manifest,
                                                            runtimeBinarySHA256: Self.binary)
        #expect(text.runtimeModelID == ClusterGLMImageCandidate.runtimeModelID)
        #expect(text.manifestSHA256 == ClusterGLMImageCandidate.manifestSHA256)
        #expect(text.artifactSHA256 == ClusterGLMImageCandidate.artifactSHA256)
        #expect(text.configurationSHA256 == ClusterGLMImageCandidate.configurationSHA256)
        #expect(text.partitions.map { $0.stages[0].sourceLayerEnd } == Array(1..<45))
        let image = try ClusterResidentModelCatalog.describe(configuration: configuration, manifest: manifest,
            runtimeBinarySHA256: Self.binary, runtimeProfile: ClusterGLMImageCandidate.profileID)
        try ClusterGLMOnboardingSelection.requireCandidate(image)
        #expect(image.manifestSHA256 == text.manifestSHA256)
    }

    /// The product store keeps a re-encoding of the same manifest (`.darkbloom-manifest.json`). The cluster store
    /// reads it as the same artifact, and the worker refuses it: the clone-in must write the CDN's bytes.
    @Test func receiptIsTheSameArtifactButNotThePinnedBytes() throws {
        let configuration = try Self.fixture("configuration"), manifest = try Self.fixture("manifest")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ModelDownloader.writeRevisionReceipt(
            ModelCatalogClient.manifestDecoder.decode(ModelManifest.self, from: manifest), at: directory)
        let receipt = try Data(contentsOf: directory.appendingPathComponent(".darkbloom-manifest.json"))

        let pinned = try ClusterCatalogArtifact.parse(manifest: manifest)
        let held = try ClusterCatalogArtifact.parse(manifest: receipt)
        #expect(pinned.modelID == "glm-5.3-flash" && pinned.version == "2026-10-15-nvfp4-r1")
        #expect(pinned.aggregateSHA256 == ClusterGLMImageCandidate.artifactSHA256)
        #expect(pinned.totalBytes == 181_752_181_866 && pinned.files.count == 42)
        #expect(pinned.r2Prefix == "v2/glm-5.3-flash--0d8724178b09/2026-10-15-nvfp4-r1")
        #expect(pinned.sameArtifact(held))
        #expect(ClusterConfigurationCodec.sha256(receipt) != ClusterGLMImageCandidate.manifestSHA256)
        #expect(throws: (any Error).self) {
            _ = try ClusterResidentModelCatalog.describe(configuration: configuration, manifest: receipt,
                                                         runtimeBinarySHA256: Self.binary)
        }
    }
}
