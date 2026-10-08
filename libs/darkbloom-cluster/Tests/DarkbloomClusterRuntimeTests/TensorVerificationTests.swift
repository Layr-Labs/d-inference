import CryptoKit
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// Tensor-level verification over real safetensors fixtures on CPU: descriptor
// parsing and refusal, full and axis-selected verified reads, the in-memory
// slice oracle, and local correctness storage budgets. No GPU group, no
// distributed backend, no model download, no network.

private func sha256Hex(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
}

private struct SafetensorsFixture {
    let root: URL
    let config: Data
    let tensorA: [Float] // [4,4] F32
    let tensorB: [Float] // [6] F32
    let manifestData: Data

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tensor-fixture-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        config = Data(#"{"arch":"fixture"}"#.utf8)
        tensorA = (0..<16).map { Float($0) + 0.5 }
        tensorB = (0..<6).map { Float($0 * 10) - 20.0 }
        let aBytes = tensorA.withUnsafeBytes { Data($0) }
        let bBytes = tensorB.withUnsafeBytes { Data($0) }
        // safetensors: 8-byte LE header length, JSON header, then payloads.
        let header: [String: Any] = [
            "a": ["dtype": "F32", "shape": [4, 4], "data_offsets": [0, aBytes.count]],
            "b": ["dtype": "F32", "shape": [6], "data_offsets": [aBytes.count, aBytes.count + bBytes.count]],
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var file = Data()
        var length = UInt64(headerData.count).littleEndian
        file.append(Data(bytes: &length, count: 8))
        file.append(headerData)
        file.append(aBytes)
        file.append(bBytes)
        try file.write(to: root.appendingPathComponent("model-00001-of-00001.safetensors"), options: .withoutOverwriting)
        try config.write(to: root.appendingPathComponent("config.json"), options: .withoutOverwriting)
        var aggregateHasher = SHA256()
        let configDigest = Data(SHA256.hash(data: config))
        let fileDigest = Data(SHA256.hash(data: file))
        aggregateHasher.update(data: configDigest)
        aggregateHasher.update(data: fileDigest)
        let aggregate = aggregateHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = [
            "aggregate_sha256": aggregate,
            "file_count": 2,
            "total_size_bytes": config.count + file.count,
            "files": [
                ["path": "config.json", "sha256": sha256Hex(config), "size_bytes": config.count],
                ["path": "model-00001-of-00001.safetensors", "sha256": sha256Hex(file), "size_bytes": file.count],
            ],
        ]
        manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: root.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    }

    func checkpoint() throws -> VerifiedCheckpoint {
        try VerifiedCheckpoint(directory: root, configurationData: config)
    }
}

@Suite("Tensor verification (CPU fixtures)")
struct TensorVerificationTests {
    @Test func descriptorsAndFullReadsMatchSourceBytes() throws {
        let fixture = try SafetensorsFixture()
        let descriptors = try tensorDescriptors(checkpoint: fixture.checkpoint())
        #expect(Set(descriptors.keys) == ["a", "b"])
        let a = try #require(descriptors["a"])
        #expect(a.shape == [4, 4] && a.dtype == .float32)
        let (array, copied, _) = try a.read(.all)
        #expect(copied == 64)
        let values = array.asArray(Float32.self)
        #expect(values == fixture.tensorA)
        let b = try #require(descriptors["b"])
        let (bArray, _, _) = try b.read(.all)
        #expect(bArray.asArray(Float32.self) == fixture.tensorB)
    }

    @Test func axisSelectionMatchesSliceOracle() throws {
        let fixture = try SafetensorsFixture()
        let descriptors = try tensorDescriptors(checkpoint: fixture.checkpoint())
        let a = try #require(descriptors["a"])
        // Select columns 1..3 of the [4,4] tensor: rows stay outer, exact
        // element window per row, ordered and disjoint.
        let (array, copied, _) = try a.read(.axis(1, [1..<3]))
        #expect(copied == 32)
        #expect(array.shape == [4, 2])
        var expected: [Float] = []
        for row in 0..<4 { expected.append(contentsOf: fixture.tensorA[row * 4 + 1...row * 4 + 2]) }
        #expect(array.asArray(Float32.self) == expected)
        // The in-memory oracle agrees with the verified descriptor read.
        let source = MLXArray(fixture.tensorA, [4, 4])
        let oracle = try copySelectedTensor(source, selection: .axis(1, [1..<3]))
        #expect(oracle.asArray(Float32.self) == expected)
        // Disordered, overlapping and out-of-range selections are refused.
        #expect(throws: ProbeError.self) { _ = try a.read(.axis(1, [2..<3, 0..<2])) }
        #expect(throws: ProbeError.self) { _ = try a.read(.axis(1, [1..<5])) }
        #expect(throws: ProbeError.self) { _ = try a.read(.axis(4, [0..<1])) }
        #expect(throws: ProbeError.self) { _ = try a.read(.axis(1, [])) }
    }

    @Test func malformedFilesNeverProduceDescriptors() throws {
        let fixture = try SafetensorsFixture()
        _ = try fixture.checkpoint()
        // Truncated header claim: write a file whose 8-byte prefix lies.
        let path = fixture.root.appendingPathComponent("model-00001-of-00001.safetensors")
        var raw = try Data(contentsOf: path)
        raw[0] = 0xFF
        let tamperedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tensor-tampered-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: tamperedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tamperedRoot) }
        for file in ["config.json", "model-00001-of-00001.safetensors", "manifest.json"] {
            try FileManager.default.copyItem(at: fixture.root.appendingPathComponent(file),
                to: tamperedRoot.appendingPathComponent(file))
        }
        try raw.write(to: tamperedRoot.appendingPathComponent("model-00001-of-00001.safetensors"))
        // The verified checkpoint refuses before descriptors are ever built:
        // the payload bytes no longer match the manifest's own SHA-256.
        #expect(throws: ProbeError.self) {
            _ = try VerifiedCheckpoint(directory: tamperedRoot, configurationData: fixture.config)
        }
    }

    @Test func correctnessStorageBudgetsAreClosed() throws {
        // A consistent local correctness budget validates.
        try LocalCorrectnessStorage.validateByteCounts(sourceModelTensorBytes: 1000,
            rankLoadedTensorBytes: [400, 500], rankLargestHostTensorBytes: [200, 250])
        #expect(throws: ProbeError.self) {
            try LocalCorrectnessStorage.validateByteCounts(sourceModelTensorBytes: 0,
                rankLoadedTensorBytes: [400, 500], rankLargestHostTensorBytes: [200, 250])
        }
        #expect(throws: ProbeError.self) {
            try LocalCorrectnessStorage.validateByteCounts(sourceModelTensorBytes: 1000,
                rankLoadedTensorBytes: [400], rankLargestHostTensorBytes: [200, 250])
        }
        #expect(throws: ProbeError.self) {
            try LocalCorrectnessStorage.validateByteCounts(sourceModelTensorBytes: 1000,
                rankLoadedTensorBytes: [400, 500], rankLargestHostTensorBytes: [600, 250])
        }
        #expect(throws: ProbeError.self) {
            try LocalCorrectnessStorage.validateByteCounts(sourceModelTensorBytes: 1000,
                rankLoadedTensorBytes: [Int.max - 1, 500], rankLargestHostTensorBytes: [200, 250])
        }
    }
}
