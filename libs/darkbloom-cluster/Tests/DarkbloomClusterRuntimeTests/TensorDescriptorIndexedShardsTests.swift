import CryptoKit
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// A caller of `tensorDescriptors` may declare that only the shards named by the
// safetensors index are weight shards: a manifest `.safetensors` file outside
// the indexed checkpoint is then hashed and not described. Real safetensors
// files on CPU, no model.

/// One indexed shard (a `U8` and a `U32` tensor), optionally a sidecar
/// `.safetensors` in a subdirectory, and optionally the index.
struct IndexedShardFixture {
    let root: URL
    let config = Data(#"{"arch":"indexed-fixture"}"#.utf8)
    let scales: [UInt8] = [3, 1, 4, 1, 5, 9, 2, 6]
    let weights: [UInt32] = [0xDEAD_BEEF, 7, 0, 0xFFFF_FFFF]

    private static func hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private static func safetensors(_ tensors: [(String, String, [Int], Data)]) throws -> Data {
        var header: [String: Any] = [:], payload = Data()
        for (name, dtype, shape, bytes) in tensors {
            header[name] = ["dtype": dtype, "shape": shape, "data_offsets": [payload.count, payload.count + bytes.count]]
            payload.append(bytes)
        }
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var file = Data(), length = UInt64(json.count).littleEndian
        file.append(Data(bytes: &length, count: 8)); file.append(json); file.append(payload)
        return file
    }

    /// `index` nil writes no index; otherwise the tensor-to-file map it holds.
    init(index: [String: String]? = ["block.scales": "model-00001-of-00001.safetensors",
                                    "block.weight": "model-00001-of-00001.safetensors"],
         sidecar: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("indexed-fixture-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("side"),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files: [(String, Data)] = [("config.json", config)]
        files.append(("model-00001-of-00001.safetensors", try Self.safetensors([
            ("block.scales", "U8", [2, 4], Data(scales)),
            ("block.weight", "U32", [2, 2], weights.withUnsafeBytes { Data($0) }),
        ])))
        if sidecar {
            // The same tensor name as a shard's: a sidecar is another namespace.
            files.append(("side/model.safetensors", try Self.safetensors([
                ("block.weight", "F32", [1], Data([0, 0, 128, 63])),
            ])))
        }
        if let index {
            files.append(("model.safetensors.index.json",
                try JSONSerialization.data(withJSONObject: ["metadata": [:], "weight_map": index], options: [.sortedKeys])))
        }
        var aggregate = SHA256()
        var entries: [[String: Any]] = []
        for (path, data) in files.sorted(by: { $0.0 < $1.0 }) {
            try data.write(to: root.appendingPathComponent(path), options: .withoutOverwriting)
            aggregate.update(data: Data(SHA256.hash(data: data)))
            entries.append(["path": path, "sha256": Self.hex(data), "size_bytes": data.count])
        }
        let manifest: [String: Any] = [
            "aggregate_sha256": aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
            "file_count": files.count, "total_size_bytes": files.reduce(0) { $0 + $1.1.count }, "files": entries,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    }

    func checkpoint() throws -> VerifiedCheckpoint { try VerifiedCheckpoint(directory: root, configurationData: config) }
}

@Suite("Tensor descriptor scope: indexed shards (CPU fixtures)")
struct TensorDescriptorIndexedShardsTests {
    @Test func theDefaultScopeRefusesBothAsBefore() throws {
        // A U8 tensor is refused by name.
        let plain = try IndexedShardFixture(index: nil, sidecar: false)
        defer { try? FileManager.default.removeItem(at: plain.root) }
        #expect(throws: ProbeError.self) { _ = try tensorDescriptors(checkpoint: plain.checkpoint()) }
        // With U8 accepted, a second `.safetensors` file is still a shard by default:
        // its duplicate tensor name is refused.
        let fixture = try IndexedShardFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(throws: ProbeError.self) {
            _ = try tensorDescriptors(checkpoint: fixture.checkpoint(), scope: .init(acceptsUInt8: true))
        }
        let dense = TensorDescriptorScope.dense
        #expect(!dense.acceptsUInt8 && !dense.indexedShardsOnly)
    }

    @Test func indexedShardsAreDescribedAndTheSidecarIsOnlyHashed() throws {
        let fixture = try IndexedShardFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let checkpoint = try fixture.checkpoint()
        // The sidecar is a manifest file: it was hashed and is held open like the rest.
        #expect(checkpoint.files["side/model.safetensors"] != nil)
        let descriptors = try tensorDescriptors(checkpoint: checkpoint,
            scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
        #expect(Set(descriptors.keys) == ["block.scales", "block.weight"])
        #expect(descriptors.values.allSatisfy { $0.file.path == "model-00001-of-00001.safetensors" })
        let scales = try #require(descriptors["block.scales"])
        #expect(scales.shape == [2, 4] && scales.dtype == .uint8 && scales.byteCount == 8)
        let read = try scales.read(.all)
        #expect(read.copiedBytes == 8 && read.array.asArray(UInt8.self) == fixture.scales)
        let weight = try #require(descriptors["block.weight"])
        let weights = try weight.read(.all).array.asArray(UInt32.self)
        #expect(weight.dtype == .uint32 && weights == fixture.weights)
        // Indexed shards alone do not admit U8.
        #expect(throws: ProbeError.self) {
            _ = try tensorDescriptors(checkpoint: checkpoint, scope: .init(indexedShardsOnly: true))
        }
    }

    @Test func anIndexedScopeNeedsAnIndexThatNamesVerifiedShardsAndEveryTensor() throws {
        let absent = try IndexedShardFixture(index: nil)
        defer { try? FileManager.default.removeItem(at: absent.root) }
        #expect(throws: ProbeError.self) {
            _ = try tensorDescriptors(checkpoint: absent.checkpoint(), scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
        }
        // A shard the manifest does not carry.
        let unknown = try IndexedShardFixture(index: ["block.scales": "model-00002-of-00002.safetensors"])
        defer { try? FileManager.default.removeItem(at: unknown.root) }
        #expect(throws: ProbeError.self) {
            _ = try tensorDescriptors(checkpoint: unknown.checkpoint(), scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
        }
        // An index that leaves out a tensor its shard holds, and one that names a tensor it does not hold.
        for index in [["block.scales": "model-00001-of-00001.safetensors"],
                      ["block.scales": "model-00001-of-00001.safetensors", "block.weight": "model-00001-of-00001.safetensors",
                       "block.other": "model-00001-of-00001.safetensors"]] {
            let partial = try IndexedShardFixture(index: index)
            defer { try? FileManager.default.removeItem(at: partial.root) }
            #expect(throws: ProbeError.self) {
                _ = try tensorDescriptors(checkpoint: partial.checkpoint(), scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
            }
        }
        // An index that points at the sidecar makes it a shard, and its tensors must then all be indexed.
        let side = try IndexedShardFixture(index: ["block.weight": "side/model.safetensors"])
        defer { try? FileManager.default.removeItem(at: side.root) }
        let descriptors = try tensorDescriptors(checkpoint: side.checkpoint(), scope: .init(indexedShardsOnly: true))
        #expect(Set(descriptors.keys) == ["block.weight"] && descriptors["block.weight"]?.dtype == .float32)
    }
}
