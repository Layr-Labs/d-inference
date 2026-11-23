import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

/// Inkling 2 Mini's DSpark drafter is `mtp.safetensors` beside the target,
/// outside the target's index. Its declaration (`mtp_config` on the native
/// looped target) makes it the checkpoint's inline assistant; its header is
/// bounded and every tensor range must lie in the file.
@Suite("Inkling 2 DSpark drafter artifact")
struct Inkling2DSparkArtifactTests {
    static func configuration() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "config.json", withExtension: nil,
            subdirectory: "Fixtures/Inkling2"))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func safetensors(_ header: [String: Any], payload: Int) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)
        var data = Data()
        withUnsafeBytes(of: UInt64(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(Data(repeating: 0, count: payload))
        return data
    }

    static var header: [String: Any] {
        [
            "__metadata__": ["format": "pt"],
            "fuse_weight": ["dtype": "BF16", "shape": [2, 4], "data_offsets": [0, 16]],
            "layers.0.mlp.up_proj.weight": ["dtype": "BF16", "shape": [4], "data_offsets": [16, 24]],
        ]
    }

    /// A checkpoint directory with the pinned config, a target index and the drafter.
    static func checkpoint(config: [String: Any]? = nil, drafter: Data?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkling2-dspark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: try config ?? configuration())
            .write(to: directory.appendingPathComponent("config.json"))
        try Data(#"{"metadata":{"total_size":2},"weight_map":{"model.llm.embed.weight":"model-00001-of-00001.safetensors"}}"#.utf8)
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        if let drafter { try drafter.write(to: directory.appendingPathComponent("mtp.safetensors")) }
        return directory
    }

    @Test func declaredDrafterIsTheInlineAssistant() throws {
        let drafter = try Self.safetensors(Self.header, payload: 24)
        let directory = try Self.checkpoint(drafter: drafter)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SpecDecStore.declaresInkling2DSparkMTP(try Self.configuration()))
        #expect(SpecDecStore.inlineDeclarationProbe(directory: directory) == .declared)
        let artifact = try SpecDecStore.inspectInlineArtifact(directory: directory).get()
        #expect(artifact.source == .inline)
        #expect(artifact.artifactBytes == 24)
        #expect(artifact.revision.hasPrefix("inline-"))
        let headerLength = Int(drafter.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian })
        let headerDigest = SHA256.hash(data: drafter.dropFirst(8).prefix(headerLength))
            .map { String(format: "%02x", $0) }.joined()
        #expect(artifact.inlineIndexSHA256 == headerDigest)
        #expect(SpecDecStore.revalidateForLoad(artifact) == .resolved(artifact))

        // A drafter whose tensors change after admission falls back.
        var changed = Self.header
        changed["extra"] = ["dtype": "BF16", "shape": [4], "data_offsets": [24, 32]]
        try Self.safetensors(changed, payload: 32).write(to: directory.appendingPathComponent("mtp.safetensors"))
        #expect(SpecDecStore.revalidateForLoad(artifact).reason == .inlineArtifactInvalid)
    }

    @Test func undeclaredTargetIsNoInlineCheckpoint() throws {
        var config = try Self.configuration()
        config["mtp_config"] = nil
        #expect(!SpecDecStore.declaresInkling2DSparkMTP(config))
        let directory = try Self.checkpoint(config: config, drafter: try Self.safetensors(Self.header, payload: 24))
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SpecDecStore.inlineDeclarationProbe(directory: directory) == .absent)
        #expect((try? SpecDecStore.inspectInlineArtifact(directory: directory).get()) == nil)
    }

    @Test func malformedDrafterIsRefused() throws {
        let cases: [(String, [String: Any]?, Int)] = [
            ("missing", nil, 0),
            ("beyond the file", ["w": ["dtype": "BF16", "shape": [64], "data_offsets": [0, 128]]], 24),
            ("empty range", ["w": ["dtype": "BF16", "shape": [0], "data_offsets": [8, 8]]], 24),
            ("no tensors", ["__metadata__": ["format": "pt"]], 24),
            ("not offsets", ["w": ["dtype": "BF16", "shape": [4], "data_offsets": [true, 8]]], 24),
        ]
        for (name, header, payload) in cases {
            let drafter = try header.map { try Self.safetensors($0, payload: payload) }
            let directory = try Self.checkpoint(drafter: drafter)
            defer { try? FileManager.default.removeItem(at: directory) }
            // Declared, so inspection runs and names its rejection.
            #expect(SpecDecStore.inlineDeclarationProbe(directory: directory) == .declared, "\(name)")
            #expect((try? SpecDecStore.inspectInlineArtifact(directory: directory).get()) == nil, "\(name)")
        }
    }

    @Test func implausibleDrafterGeometryIsUndeclared() throws {
        for (key, value) in [("block_size", 1 as Any), ("block_size", 64), ("num_hidden_layers", 0),
                             ("target_layer_ids", [] as [Int]), ("target_layer_ids", [-1])] {
            var config = try Self.configuration()
            var mtp = try #require(config["mtp_config"] as? [String: Any])
            mtp[key] = value
            config["mtp_config"] = mtp
            #expect(!SpecDecStore.declaresInkling2DSparkMTP(config), "\(key)")
        }
    }
}
