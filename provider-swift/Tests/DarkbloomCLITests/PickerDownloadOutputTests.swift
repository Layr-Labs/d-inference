import CryptoKit
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// What `darkbloom start` prints when its picker downloads a model. The run
/// is a child process: the stub coordinator also answers for the CDN on the
/// shared URL session and the model cache is the sandbox's, so nothing leaves
/// the process. Without hardware facts no runtime capability is probed.
@Suite("Start picker download output")
struct PickerDownloadOutputTests {
    @Test("a model the picker downloads gets one completion line and no line per file")
    func oneCompletionLine() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            setenv("DARKBLOOM_R2_CDN_URL", "https://cdn.invalid", 1)
            ModelScanner.configureCacheDirectory(sandbox.cache.path)
            CoordinatorStub.install(try PickerDownloadFixture.replies())
            let snapshot = try sandbox.snapshot(hardware: nil)
            print("== PICK")
            let picked = try await Start.parse([]).interactiveCatalogPicker(
                snapshot: snapshot, config: snapshot.config, coordinatorURL: CLICommandSandbox.coordinatorURL,
                runtimeCapabilities: [], isInteractive: false, readInput: { "1" })
            print("== PICKED \(picked.joined(separator: ","))")
        }
        let output = decodedText(result.standardOutputContent)
        let lines = try #require(outputSection(output, from: "== PICK", to: "== PICKED"))
            .components(separatedBy: "\n")
        #expect(printedValue(output, label: "== PICKED") == PickerDownloadFixture.modelID)
        #expect(lines.contains("  Downloading Tiny (0.0 GB)..."))
        let completions = lines.filter { $0.localizedCaseInsensitiveContains("downloaded") && !$0.contains("[not downloaded]") }
        #expect(completions.count == 1, "\(completions)")
        #expect(completions.first?.hasPrefix("  \u{2713} Downloaded Tiny (300 KB in ") == true)
        #expect(!lines.contains { $0.contains("safetensors") || $0.contains("config.json") })
    }
}

/// A three-file model, 300,022 bytes, on the stub coordinator and CDN.
private enum PickerDownloadFixture {
    static let modelID = "acme/Tiny-4bit"
    static let prefix = "v2/acme/tiny/v1"

    private struct CatalogBody: Encodable {
        let models: [CatalogModel]
    }

    static func replies() throws -> [String: CoordinatorStub.Reply] {
        let files: [(path: String, bytes: Data)] = [
            ("config.json", Data(#"{"model_type": "test"}"#.utf8)),
            ("model-00001-of-00002.safetensors", Data((0..<200_000).map { UInt8($0 & 0xFF) })),
            ("model-00002-of-00002.safetensors", Data((0..<100_000).map { UInt8(($0 &* 7) & 0xFF) })),
        ]
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
            digest.map { String(format: "%02x", $0) }.joined()
        }
        var aggregate = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) { aggregate.update(data: Data(SHA256.hash(data: file.bytes))) }
        let aggregateSHA256 = hex(aggregate.finalize())
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix, aggregateSHA256: aggregateSHA256,
            totalSizeBytes: files.reduce(0) { $0 + Int64($1.bytes.count) }, fileCount: files.count,
            files: files.map {
                ManifestFile(path: $0.path, sizeBytes: Int64($0.bytes.count), sha256: hex(SHA256.hash(data: $0.bytes)),
                             role: $0.path.hasSuffix(".safetensors") ? "weight" : "config")
            },
            createdAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestJSON = try encoder.encode(manifest)
        let model = CatalogModel(id: modelID, s3Name: "tiny", displayName: "Tiny", sizeGb: 0.0003,
                                 r2Prefix: prefix, aggregateSHA256: aggregateSHA256)
        var replies: [String: CoordinatorStub.Reply] = [
            "/v1/models/catalog": .init(status: 200, body: try JSONEncoder().encode(CatalogBody(models: [model]))),
            // The ID is one percent-encoded path segment; either spelling of the path finds the manifest.
            "/v1/models/catalog/manifest/\(modelID)": .init(status: 200, body: manifestJSON),
            "/v1/models/catalog/manifest/acme%2FTiny-4bit": .init(status: 200, body: manifestJSON),
        ]
        for file in files { replies["/\(prefix)/\(file.path)"] = .init(status: 200, body: file.bytes) }
        return replies
    }
}
