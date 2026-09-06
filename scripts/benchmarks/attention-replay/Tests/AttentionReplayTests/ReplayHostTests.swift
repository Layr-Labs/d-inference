import Foundation
import MLX
import Testing
@_spi(Benchmarking) import MLXLMCommon
@testable import attention_replay

/// These fixtures construct only Data and JSON; no operator or model is called.
struct ReplayHostTests {
    private func options(input: URL, hash: String, output: URL) throws -> ReplayOptions {
        try ReplayOptions(["--input", input.path, "--input-sha256", hash,
                           "--output", output.path, "--arm", "nativeSDPA"])
    }

    @Test func exactOptionsRejectDuplicatesMissingValuesAndRelativePaths() throws {
        let args = ["--input", "/input", "--input-sha256", String(repeating: "a", count: 64),
                    "--output", "/output", "--arm", "nativeSDPA"]
        #expect(try ReplayOptions(args).arm == "nativeSDPA")
        for index in [0, 2, 4, 6] {
            var bad = args; bad[index] = "--input"
            if index != 0 { #expect(throws: (any Error).self) { try ReplayOptions(bad) } }
        }
        for bad in [Array(args.dropLast()), args + ["--arm", "pagedFixed"],
                    ["--input", "relative"] + Array(args.dropFirst(2)),
                    Array(args.prefix(2)) + ["--input-sha256", "wrong"] + Array(args.dropFirst(4))] {
            #expect(throws: (any Error).self) { try ReplayOptions(bad) }
        }
    }

    @Test func descriptorsRejectTraversalTransposesOverflowAndWrongLengths() throws {
        let hash = String(repeating: "a", count: 64)
        let good = ReplayTensorDescriptor(file: "queries.bin", dtype: "float32", byteOrder: "little",
            sha256: hash, shape: [1, 2, 1, 64], packedStrides: [128, 64, 64, 1], byteCount: 512)
        try good.validate(name: "queries")
        let bad: [ReplayTensorDescriptor] = [
            .init(file: "../queries.bin", dtype: good.dtype, byteOrder: good.byteOrder, sha256: hash,
                  shape: good.shape, packedStrides: good.packedStrides, byteCount: 512),
            .init(file: good.file, dtype: good.dtype, byteOrder: "big", sha256: hash,
                  shape: good.shape, packedStrides: good.packedStrides, byteCount: 512),
            .init(file: good.file, dtype: good.dtype, byteOrder: good.byteOrder, sha256: hash,
                  shape: good.shape, packedStrides: [128, 1, 64, 2], byteCount: 512),
            .init(file: good.file, dtype: good.dtype, byteOrder: good.byteOrder, sha256: hash,
                  shape: [32768, 32768, 32768, 32768], packedStrides: good.packedStrides, byteCount: 512),
            .init(file: good.file, dtype: good.dtype, byteOrder: good.byteOrder, sha256: hash,
                  shape: good.shape, packedStrides: good.packedStrides, byteCount: 511),
        ]
        for value in bad { #expect(throws: (any Error).self) { try value.validate(name: "queries") } }
    }

    @Test func regularFileReadsRefuseSymlinksDirectoriesAndOversizedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("raw"), link = root.appendingPathComponent("alias")
        try Data([1, 2, 3]).write(to: file)
        #expect(try readBounded(file, limit: 3) == Data([1, 2, 3]))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for url in [link, root] {
            #expect(throws: (any Error).self) { try readBounded(url, limit: 3) }
        }
        #expect(throws: (any Error).self) { try readBounded(file, limit: 2) }
    }

    @Test func validatedTransferBindsHashAndNativePayloadBeforeAnyOperator() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let q = CBv2AttentionReplay.Tensor(bytes: Data(repeating: 0, count: 512), shape: [1, 2, 1, 64], dtype: .float32)
        let kv = CBv2AttentionReplay.Tensor(bytes: Data(repeating: 0, count: 256), shape: [1, 1, 1, 64], dtype: .float32)
        let input = CBv2AttentionReplay.Input(queries: q, storedKeys: kv, storedValues: kv,
            incomingKeys: kv, incomingValues: kv, scaleBits: Float(1).bitPattern)
        let geometry = try CBv2AttentionReplay.validate(input)
        let geometryJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReplayGeometry(geometry)))
        var tensors = [String: Any]()
        for name in ["queries", "storedKeys", "storedValues", "incomingKeys", "incomingValues", "output"] {
            let tensor = ["queries", "output"].contains(name) ? q : kv
            try tensor.bytes.write(to: root.appendingPathComponent(name + ".bin"))
            tensors[name] = ["file": name + ".bin", "dtype": "float32", "byteOrder": "little",
                "sha256": sha256(tensor.bytes), "shape": tensor.shape,
                "packedStrides": [tensor.shape[1] * 64, 64, 64, 1], "byteCount": tensor.bytes.count]
        }
        let sourceHash = String(repeating: "a", count: 64)
        let document: [String: Any] = ["schema": "darkbloom.attention-replay-input.v1",
            "packetSHA256": sourceHash, "metadataSHA256": sourceHash, "sampleOutcome": "confirmed",
            "identity": ["artifactSHA256": sourceHash, "inputSHA256": sourceHash, "backend": "contiguous", "modelID": "host-fixture"],
            "selection": ["requestID": 2, "outputIndex": 1, "storageLayerIndex": 0, "modelLayerIndex": 0,
                "offsetBefore": 0, "offsetAfter": 1, "phase": "decode", "dispatch": "contiguous_sdpa"],
            "scaleBits": Float(1).bitPattern, "geometry": geometryJSON, "tensors": tensors]
        let raw = try JSONSerialization.data(withJSONObject: document)
        let path = root.appendingPathComponent("input.json"), output = root.appendingPathComponent("uncreated")
        try raw.write(to: path)
        let selected = try options(input: path, hash: sha256(raw), output: output)
        #expect(try ReplayTransfer.load(selected).1.queries.bytes == q.bytes)
        let wrong = try options(input: path, hash: String(repeating: "b", count: 64), output: output)
        #expect(throws: (any Error).self) { try ReplayTransfer.load(wrong) }
        try Data(repeating: 1, count: 512).write(to: root.appendingPathComponent("queries.bin"))
        #expect(throws: (any Error).self) { try ReplayTransfer.load(selected) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
