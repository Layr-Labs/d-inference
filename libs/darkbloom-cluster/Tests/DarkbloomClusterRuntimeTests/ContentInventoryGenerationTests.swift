import CryptoKit
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// Content inventory generation over real safetensors files on CPU: every
// descriptor is hashed over exactly its stored range through its verified
// descriptor, nothing is evaluated, and an artifact that is not a registered
// model's is refused. The last test needs the registered artifact itself and
// runs only when DARKBLOOM_CLUSTER_REGISTERED_MODEL_DIR names its directory.

private func sha256Hex(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
}

/// One safetensors file whose payload order is not name order, with a tensor
/// larger than one hashing block.
private struct InventoryFixture {
    static let file = "model-00001-of-00001.safetensors"
    let root: URL
    let config = Data(#"{"arch":"inventory-fixture"}"#.utf8)
    /// (name, dtype, shape, bytes) in payload order.
    let tensors: [(name: String, dtype: String, shape: [Int], bytes: Data)]
    let headerBytes: Int

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inventory-fixture-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A 4,099-byte period, so no two hashing blocks of the large tensor are equal.
        func pattern(_ count: Int, _ seed: Int) -> Data {
            let period = Data((0..<4099).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ $0 / 251 &+ seed) })
            var data = Data(capacity: count + period.count)
            while data.count < count { data.append(period) }
            return data.prefix(count)
        }
        let large = CheckpointAlignedReadPlan.maximumScratchRequestBytes + 4096
        tensors = [
            ("model.z.weight", "U32", [2, 4], pattern(32, 1)),
            ("model.big.weight", "F32", [large / 4], pattern(large, 2)),
            ("model.a.scales", "BF16", [3, 2], pattern(12, 3)),
        ]
        var header: [String: Any] = [:], payload = Data()
        for tensor in tensors {
            header[tensor.name] = ["dtype": tensor.dtype, "shape": tensor.shape,
                                   "data_offsets": [payload.count, payload.count + tensor.bytes.count]]
            payload.append(tensor.bytes)
        }
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        headerBytes = headerData.count
        var length = UInt64(headerData.count).littleEndian
        let stored = Data(bytes: &length, count: 8) + headerData + payload
        try stored.write(to: root.appendingPathComponent(Self.file), options: .withoutOverwriting)
        try config.write(to: root.appendingPathComponent("config.json"), options: .withoutOverwriting)
        var aggregate = SHA256()
        aggregate.update(data: Data(SHA256.hash(data: config)))
        aggregate.update(data: Data(SHA256.hash(data: stored)))
        let manifest: [String: Any] = [
            "aggregate_sha256": aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
            "file_count": 2, "total_size_bytes": config.count + stored.count,
            "files": [
                ["path": "config.json", "sha256": sha256Hex(config), "size_bytes": config.count],
                ["path": Self.file, "sha256": sha256Hex(stored), "size_bytes": stored.count],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// `uncached` reads as the generator does on a real artifact: aligned, bypassing the file cache.
    func descriptors(uncached: Bool = false) throws -> [String: TensorDescriptor] {
        let checkpoint = try VerifiedCheckpoint(directory: root, configurationData: config)
        if uncached { try checkpoint.bypassTensorPayloadCache() }
        return try tensorDescriptors(checkpoint: checkpoint)
    }
}

@Suite("Content inventory generation (CPU fixtures)")
struct ContentInventoryGenerationTests {
    @Test func everyDescriptorIsHashedOverItsStoredRange() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        let inventory = try layerStageTensorContentInventory(fixture.descriptors(), check: {})
        // Canonical order is offset order within the file, which is the payload order.
        #expect(inventory.records.map { $0.source.layout.canonicalName } == fixture.tensors.map(\.name))
        var offset = 8 + fixture.headerBytes
        for (record, tensor) in zip(inventory.records, fixture.tensors) {
            #expect(record.source.sourceFile == InventoryFixture.file)
            #expect(record.source.sourceOffset == offset)
            #expect(record.source.layout.sourceDType == tensor.dtype)
            #expect(record.source.layout.shape == tensor.shape)
            #expect(record.source.layout.byteCount == tensor.bytes.count)
            #expect(record.contentSHA256 == sha256Hex(tensor.bytes))
            offset += tensor.bytes.count
        }
        #expect(try LayerStageTensorContentInventory.decode(inventory.encoded()) == inventory)
        #expect(try layerStageTensorContentInventory(fixture.descriptors(uncached: true), check: {}) == inventory)
    }

    @Test func aSubsetOfDescriptorsGivesOnlyThoseRecords() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        let inventory = try layerStageTensorContentInventory(
            fixture.descriptors().filter { $0.key != "model.big.weight" }, check: {})
        #expect(inventory.records.map { $0.source.layout.canonicalName } == ["model.z.weight", "model.a.scales"])
        #expect(inventory.payloadBytes == 44)
    }

    @Test func theCheckRunsBeforeEveryBlockAndStopsTheHashing() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        var calls = 0
        _ = try layerStageTensorContentInventory(fixture.descriptors(), check: { calls += 1 })
        // Two small tensors take one block each; the large one takes two.
        #expect(calls == 4)
        let stopped = #expect(throws: ProbeError.self) {
            _ = try layerStageTensorContentInventory(fixture.descriptors(), check: { throw ProbeError("past deadline") })
        }
        #expect(stopped?.description == "past deadline")
    }

    @Test func anArtifactThatIsNotARegisteredModelsIsRefused() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        // The closed model catalog refuses it, before any file is hashed.
        let refusal = #expect(throws: QwenDenseProfileError.self) {
            _ = try QwenContentInventoryGenerator.run(modelDirectory: fixture.root,
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
        }
        #expect(refusal?.description == "Configuration is not a registered resident model's")
    }

    /// Reads every byte of the registered artifact (about 6 GB, twice). No model is constructed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_CLUSTER_REGISTERED_MODEL_DIR"] != nil))
    func theRegisteredArtifactReproducesItsPinnedInventory() throws {
        let path = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_CLUSTER_REGISTERED_MODEL_DIR"])
        let output = try QwenContentInventoryGenerator.run(modelDirectory: URL(fileURLWithPath: path),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 280_000_000_000)
        let specification = try #require(QwenDenseRegisteredSpecification.all.first {
            $0.model.rawValue == output.receipt.model
        })
        let pin = try #require(specification.contentInventorySHA256)
        #expect(output.receipt.contentInventorySHA256 == pin)
        #expect(output.receipt.matchesRegisteredPin == true)
        #expect(output.receipt.verifiedAggregateSHA256 == specification.artifactSHA256)
        #expect(output.receipt.layoutInventorySHA256 == specification.inventorySHA256)
        #expect(output.receipt.tensorCount == specification.tensorCount)
        #expect(output.receipt.payloadBytes == specification.sourceBytes)
        #expect(!output.receipt.modelConstructed && !output.receipt.collectiveCreated)
        // The document compiled into the runtime is this one, and the committed
        // generated file is exactly what the generator writes.
        #expect(String(decoding: output.document, as: UTF8.self) == QwenRegisteredContentInventory.document(specification.model))
        let embedded = try #require(try QwenRegisteredContentInventory.admit(specification))
        #expect(embedded.encoded() == output.document)
        #expect(output.receipt.sourceTensorManifestSHA256
            == (try QwenStageSourceTensorManifest.fingerprint(embedded, bf16ConversionEnabled: true)))
        if specification.model == .qwen35NineB {
            let generated = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(
                    "Sources/DarkbloomClusterRuntime/Models/Qwen/Metadata/QwenRegistered9BContentInventory.swift")
            #expect(try String(contentsOf: generated, encoding: .utf8) == output.swiftSource)
        }
    }
}
