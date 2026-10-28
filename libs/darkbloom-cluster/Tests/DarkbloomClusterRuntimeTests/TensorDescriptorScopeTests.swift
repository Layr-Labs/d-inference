import CryptoKit
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// The tensor header reader's scope: a dense caller still refuses an unsigned
// byte tensor anywhere in a shard, and a caller that declares it reads one as
// exactly its stored bytes. A real safetensors fixture on CPU; no model.

@Suite("Tensor descriptor scope (CPU fixture)")
struct TensorDescriptorScopeTests {
    private static func hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    /// One shard holding a packed-word tensor, its per-group exponent bytes and a bias.
    private static func fixture() throws -> (root: URL, config: Data, exponents: [UInt8]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tensor-scope-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = Data(#"{"arch":"scope-fixture"}"#.utf8)
        let words: [UInt32] = (0..<12).map { UInt32($0) &* 0x0101_0101 }
        let exponents: [UInt8] = (0..<24).map { UInt8(120 + $0) }
        let bias: [Float] = [0.5, -1.5]
        let parts = [words.withUnsafeBytes { Data($0) }, Data(exponents), bias.withUnsafeBytes { Data($0) }]
        let header: [String: Any] = [
            "proj.weight": ["dtype": "U32", "shape": [2, 2, 3], "data_offsets": [0, parts[0].count]],
            "proj.scales": ["dtype": "U8", "shape": [2, 2, 6], "data_offsets": [parts[0].count, parts[0].count + parts[1].count]],
            "proj.bias": ["dtype": "F32", "shape": [2],
                          "data_offsets": [parts[0].count + parts[1].count, parts[0].count + parts[1].count + parts[2].count]],
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var file = Data()
        var length = UInt64(headerData.count).littleEndian
        file.append(Data(bytes: &length, count: 8))
        file.append(headerData)
        parts.forEach { file.append($0) }
        try file.write(to: root.appendingPathComponent("model.safetensors"), options: .withoutOverwriting)
        try config.write(to: root.appendingPathComponent("config.json"), options: .withoutOverwriting)
        var aggregate = SHA256()
        aggregate.update(data: Data(SHA256.hash(data: config)))
        aggregate.update(data: Data(SHA256.hash(data: file)))
        let manifest: [String: Any] = [
            "aggregate_sha256": aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
            "file_count": 2, "total_size_bytes": config.count + file.count,
            "files": [
                ["path": "config.json", "sha256": hex(config), "size_bytes": config.count],
                ["path": "model.safetensors", "sha256": hex(file), "size_bytes": file.count],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        return (root, config, exponents)
    }

    @Test func aDenseCallerStillRefusesUnsignedBytes() throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let checkpoint = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config)
        #expect(throws: ProbeError.self) { _ = try tensorDescriptors(checkpoint: checkpoint) }
        #expect(throws: ProbeError.self) { _ = try tensorDescriptors(checkpoint: checkpoint, scope: .dense) }
    }

    @Test func aDeclaringCallerReadsTheStoredBytes() throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let checkpoint = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config)
        let descriptors = try tensorDescriptors(checkpoint: checkpoint, scope: .init(acceptsUInt8: true))
        #expect(Set(descriptors.keys) == ["proj.weight", "proj.scales", "proj.bias"])
        let scales = try #require(descriptors["proj.scales"])
        #expect(scales.dtype == .uint8 && scales.shape == [2, 2, 6] && scales.byteCount == 24)
        #expect(descriptors["proj.weight"]?.dtype == .uint32 && descriptors["proj.bias"]?.dtype == .float32)
        let read = try scales.read(.all)
        #expect(read.copiedBytes == 24 && read.array.dtype == .uint8 && read.array.shape == [2, 2, 6])
        #expect(read.array.asArray(UInt8.self) == fixture.exponents)
        // A selection along an axis keeps whole exponent groups.
        let second = try scales.read(.axis(0, [1..<2]))
        #expect(second.array.asArray(UInt8.self) == Array(fixture.exponents[12...]))
    }
}
