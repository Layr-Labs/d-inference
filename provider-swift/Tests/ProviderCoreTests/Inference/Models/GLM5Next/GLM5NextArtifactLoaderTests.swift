import CryptoKit
import Foundation
import MLX
import Testing

@testable import MLXLLM

/// Complete, deterministic, tiny local safetensors. No real artifact paths,
/// downloads, model conversion or cache directories are touched by these tests.
final class GLM5NextLocalArtifactFixture {
    let directory: URL
    let configuration: GLM5NextConfiguration
    let storage: GLM5NextWeightInventory.Storage
    let shards: [String]
    let tensors: [GLM5NextWeightInventory.Tensor]

    init(q4: Bool = false, mtp: Bool = true) throws {
        let shardNames = [
            "weights-0.safetensors", "weights-1.safetensors", "weights-2.safetensors",
        ]
        shards = shardNames
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "glm5-next-artifact-\(UUID())")
        let original = try GLM5NextInventoryFixture.configuration(q4: q4)
        if mtp {
            configuration = original
        } else {
            var json =
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
                as! [String: Any]
            var text = json["text_config"] as! [String: Any]
            text["num_nextn_predict_layers"] = 0
            json["text_config"] = text
            configuration = try JSONDecoder().decode(
                GLM5NextConfiguration.self,
                from: JSONSerialization.data(withJSONObject: json))
        }
        storage = q4 ? .vontraQ4 : .float32
        tensors = try GLM5NextWeightInventory.expectedTensors(
            configuration: configuration,
            storage: storage, shard: shards[0]
        ).enumerated().map { index, tensor in
            .init(
                name: tensor.name, shape: tensor.shape, dtype: tensor.dtype,
                shard: shardNames[index % shardNames.count])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try JSONEncoder().encode(configuration).write(to: url("config.json"))
        var total = 0
        for shard in shards {
            var header: [String: Any] = ["__metadata__": ["fixture": "synthetic"]]
            var payload = Data()
            for tensor in tensors where tensor.shard == shard {
                let bytes = Self.bytes(tensor)
                let start = payload.count
                payload.append(bytes)
                header[tensor.name] = [
                    "shape": tensor.shape, "dtype": tensor.dtype,
                    "data_offsets": [start, payload.count],
                ]
            }
            total += payload.count
            try Self.safetensors(header: header, payload: payload).write(to: url(shard))
        }
        let index: [String: Any] = [
            "metadata": ["total_size": total],
            "weight_map": Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0.shard) }),
        ]
        try JSONSerialization.data(withJSONObject: index, options: .sortedKeys)
            .write(to: url("model.safetensors.index.json"))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func identity() throws -> GLM5NextArtifactIdentity {
        let files = try Dictionary(
            uniqueKeysWithValues: (["config.json", "model.safetensors.index.json"] + shards).map {
                name in
                let bytes = try Data(contentsOf: url(name))
                return (
                    name,
                    GLM5NextArtifactIdentity.File(
                        bytes: bytes.count,
                        sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    )
                )
            })
        return .init(
            repository: "synthetic/glm5-next", revision: String(repeating: "a", count: 40),
            files: files)
    }

    func loader(limits: GLM5NextArtifactLimits = .init()) throws -> GLM5NextArtifactLoader {
        try .init(
            directory: directory, expectedIdentity: identity(), storage: storage, limits: limits)
    }

    func rewriteHeader(_ transform: (inout [String: Any], inout Data) -> Void) throws {
        let data = try Data(contentsOf: url(shards[0]))
        let size = data.prefix(8).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        var header =
            try JSONSerialization.jsonObject(with: data.subdata(in: 8 ..< (size + 8)))
            as! [String: Any]
        var payload = data.subdata(in: (size + 8) ..< data.count)
        transform(&header, &payload)
        try Self.safetensors(header: header, payload: payload).write(to: url(shards[0]))
    }

    static func safetensors(header: [String: Any], payload: Data) throws -> Data {
        var encoded = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)
        while encoded.count % 8 != 0 { encoded.append(32) }
        return safetensors(rawHeader: encoded, payload: payload)
    }

    static func safetensors(rawHeader: Data, payload: Data) -> Data {
        var length = UInt64(rawHeader.count).littleEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(rawHeader)
        result.append(payload)
        return result
    }

    private static func bytes(_ tensor: GLM5NextWeightInventory.Tensor) -> Data {
        var bytes = Data()
        let count = tensor.shape.reduce(1, *)
        let salt = tensor.name.utf8.reduce(0) { ($0 + Int($1)) % 13 }
        for index in 0 ..< count {
            let value: Float
            if tensor.name.hasSuffix(".scales") {
                value = 0.01
            } else if tensor.name.contains("norm.weight") || tensor.name.hasSuffix("_scale") {
                value = 1
            } else if tensor.name.hasSuffix("A_log") {
                value = -0.7
            } else if tensor.name.hasSuffix("dt_bias") {
                value = -0.2
            } else if tensor.name.hasSuffix(".bias") || tensor.name.hasSuffix("_base")
                || tensor.name.hasSuffix(".biases")
            {
                value = 0
            } else {
                value = Float((index + salt) % 11 - 5) * 0.025
            }
            if tensor.dtype == "BF16" {
                var bits = UInt16(truncatingIfNeeded: value.bitPattern >> 16).littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            } else {
                var bits = (tensor.dtype == "U32" ? UInt32(0x1111_1111) : value.bitPattern)
                    .littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
        }
        return bytes
    }
}

extension KernelTests {
    @Suite struct GLM5NextArtifactLoaderTests {
        @Test func completeInventoryIsValidatedBeforeAnyPayloadAndPartitionsRemainAvailable() throws
        {
            let fixture = try GLM5NextLocalArtifactFixture()
            let loader = try fixture.loader()
            #expect(loader.inventory.entries.count == fixture.tensors.count)
            #expect(loader.unresolved(in: .text).count > 0)
            #expect(loader.unresolved(in: .mtp).count == 31)
            #expect(loader.unresolved(in: .vision).count == 25)
            let resources = loader.resources
            #expect(resources.textBytes == loader.inventory.bytes(in: .text))
            #expect(resources.mtpBytes == loader.inventory.bytes(in: .mtp))
            #expect(resources.visionBytes == loader.inventory.bytes(in: .vision))
            #expect(resources.largestExpertStackBytes > 0)
            #expect(
                resources.conservativeLoadPeakBytes > resources.textBytes + resources.mtpBytes
                    + resources.visionBytes)
            #expect(throws: GLM5NextArtifactError.self) { try loader.requireConsumed(.text) }
        }

        @Test func realRangeResolutionAndTextForwardDoNotConsumeDeferredPartitions() throws {
            try Device.withDefaultDevice(.cpu) {
                let fixture = try GLM5NextLocalArtifactFixture()
                let loader = try fixture.loader()
                let model = try loader.loadTextModel()
                #expect(loader.unresolved(in: .text).isEmpty)
                #expect(!loader.unresolved(in: .mtp).isEmpty)
                #expect(!loader.unresolved(in: .vision).isEmpty)
                let output = try model.forward(
                    tokens: MLXArray([Int32(2), 3, 4], [1, 3]), cache: nil)
                #expect(output.logits.shape == [1, 3, 32])
                #expect(output.logits.asArray(Float.self).allSatisfy { $0.isFinite })
                #expect(throws: GLM5NextArtifactError.self) { try loader.tensor("lm_head.weight") }
                try loader.verifyUnchanged()
            }
        }

        @Test func missingExtraWrongDtypeAndUncoveredOffsetsFailEvenWithFreshHashes() throws {
            for mode in 0 ..< 5 {
                let fixture = try GLM5NextLocalArtifactFixture()
                try fixture.rewriteHeader { header, payload in
                    let name = header.keys.sorted().first { $0 != "__metadata__" }!
                    var entry = header[name] as! [String: Any]
                    switch mode {
                    case 0: header.removeValue(forKey: name)
                    case 1: header["unexpected.weight"] = header.removeValue(forKey: name)
                    case 2:
                        entry["dtype"] = "I32"
                        header[name] = entry
                    case 3:
                        var offsets = entry["data_offsets"] as! [Int]
                        offsets[0] += 1
                        entry["data_offsets"] = offsets
                        header[name] = entry
                    default: payload.append(0)
                    }
                }
                #expect(throws: (any Error).self) { try fixture.loader() }
            }
        }

        @Test func payloadShapeAndWrongShardMappingAreRejected() throws {
            let fixture = try GLM5NextLocalArtifactFixture()
            try fixture.rewriteHeader { header, _ in
                let name = header.keys.sorted().first { $0 != "__metadata__" }!
                var entry = header[name] as! [String: Any]
                entry["shape"] = [1]
                header[name] = entry
            }
            #expect(throws: GLM5NextArtifactError.self) { try fixture.loader() }
            let other = try GLM5NextLocalArtifactFixture()
            let indexURL = other.url("model.safetensors.index.json")
            var json =
                try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [String: Any]
            var map = json["weight_map"] as! [String: String]
            map[other.tensors[0].name] = other.shards[1]
            json["weight_map"] = map
            try JSONSerialization.data(withJSONObject: json).write(to: indexURL)
            #expect(throws: GLM5NextArtifactError.self) { try other.loader() }
        }

        @Test func unindexedShardMissingShardTruncationAndHashMismatchFailClosed() throws {
            let extra = try GLM5NextLocalArtifactFixture()
            try Data().write(to: extra.url("extra.safetensors"))
            #expect(throws: GLM5NextArtifactError.self) { try extra.loader() }
            let missing = try GLM5NextLocalArtifactFixture()
            let expected = try missing.identity()
            try FileManager.default.removeItem(at: missing.url(missing.shards[0]))
            #expect(throws: GLM5NextArtifactError.self) {
                try GLM5NextArtifactLoader(
                    directory: missing.directory, expectedIdentity: expected, storage: .float32)
            }
            let truncated = try GLM5NextLocalArtifactFixture()
            var data = try Data(contentsOf: truncated.url(truncated.shards[0]))
            data.removeLast()
            try data.write(to: truncated.url(truncated.shards[0]))
            #expect(throws: GLM5NextArtifactError.self) { try truncated.loader() }
            let wrongHash = try GLM5NextLocalArtifactFixture()
            let original = try wrongHash.identity()
            var files = original.files
            files[wrongHash.shards[0]] = .init(
                bytes: files[wrongHash.shards[0]]!.bytes,
                sha256: String(repeating: "0", count: 64))
            #expect(throws: GLM5NextArtifactError.self) {
                try GLM5NextArtifactLoader(
                    directory: wrongHash.directory,
                    expectedIdentity: .init(
                        repository: original.repository, revision: original.revision, files: files),
                    storage: .float32)
            }
        }

        @Test func changedFilesAndSymlinksCannotServeDeferredWeights() throws {
            let fixture = try GLM5NextLocalArtifactFixture()
            let loader = try fixture.loader()
            let configURL = fixture.url("config.json")
            var config = try Data(contentsOf: configURL)
            config.append(32)
            try config.write(to: configURL)
            #expect(throws: GLM5NextArtifactError.self) { try loader.verifyUnchanged() }
            #expect(throws: GLM5NextArtifactError.self) { try loader.tensor("lm_head.weight") }
            let link = try GLM5NextLocalArtifactFixture()
            let expected = try link.identity()
            let target = link.url("saved-weights.bin")
            try FileManager.default.moveItem(at: link.url(link.shards[0]), to: target)
            try FileManager.default.createSymbolicLink(
                at: link.url(link.shards[0]), withDestinationURL: target)
            #expect(throws: GLM5NextArtifactError.self) {
                try GLM5NextArtifactLoader(
                    directory: link.directory, expectedIdentity: expected, storage: .float32)
            }
        }

        @Test func duplicateJSONKeysAndOversizedHeadersAreRejected() throws {
            let fixture = try GLM5NextLocalArtifactFixture()
            let raw = Data(
                "{\"metadata\":{\"total_size\":1},\"metadata\":{\"total_size\":2},\"weight_map\":{}}"
                    .utf8)
            try raw.write(to: fixture.url("model.safetensors.index.json"))
            #expect(throws: GLM5NextArtifactError.self) { try fixture.loader() }
            let header = try GLM5NextLocalArtifactFixture()
            try GLM5NextLocalArtifactFixture.safetensors(
                rawHeader: Data("{\"x\":{},\"\\u0078\":{}}".utf8), payload: Data()
            )
            .write(to: header.url(header.shards[0]))
            #expect(throws: GLM5NextArtifactError.self) { try header.loader() }
            let bounded = try GLM5NextLocalArtifactFixture()
            var limits = GLM5NextArtifactLimits()
            limits.maximumHeaderBytes = 8
            #expect(throws: GLM5NextArtifactError.self) { try bounded.loader(limits: limits) }
        }

        @Test func packedArtifactRetainsOriginalWordsAndLoadsWithoutRequantization() throws {
            try Device.withDefaultDevice(.cpu) {
                let fixture = try GLM5NextLocalArtifactFixture(q4: true)
                let loader = try fixture.loader()
                let text = try loader.loadTextModel()
                #expect(text.lmHead.weight.dtype == .uint32)
                #expect(text.lmHead.weight.asArray(UInt32.self).allSatisfy { $0 == 0x1111_1111 })
                #expect(loader.unresolved(in: .text).isEmpty)
                #expect(!loader.unresolved(in: .mtp).isEmpty)
                let mtp = try loader.loadMTP(target: text)
                #expect(mtp.targetIdentity == ObjectIdentifier(text))
                #expect(loader.unresolved(in: .mtp).isEmpty)
                #expect(!loader.unresolved(in: .vision).isEmpty)
            }
        }
    }
}
