import CryptoKit
import Foundation
import MLX
import Testing
@_spi(Diagnostics) @testable import MLXLMCommon
@testable import radix_engine

struct BenchmarkAttentionPacketExportTests {
    private func fixture(outcome: String = "confirmed", missing: String? = nil) throws
        -> CBv2AttentionPacketSnapshot {
        let shapes = ["queries": [1, 2, 1, 2], "output": [1, 2, 1, 2],
                      "incomingKeys": [1, 1, 1, 2], "incomingValues": [1, 1, 1, 2],
                      "storedKeys": [1, 1, 3, 2], "storedValues": [1, 1, 3, 2]]
        var tensors: [String: CBv2AttentionPacketTensor] = [:]
        var metadata: [String: CBv2AttentionTensorMetadata] = [:]
        for (name, shape) in shapes {
            // Deliberately chosen BF16 native bits, constructed on the host.
            let words = (0..<shape.reduce(1, *)).map { UInt16(0x3F80 + $0 % 2).littleEndian }
            let data = words.withUnsafeBytes { Data($0) }
            var stride = 1
            let strides = shape.reversed().map { width -> Int in
                defer { stride *= width }
                return stride
            }.reversed()
            tensors[name] = .init(dtype: "bfloat16", shape: shape, packedStrides: Array(strides), data: data)
            metadata[name] = .init(MLXArray(data, shape, dtype: .bfloat16))
        }
        let record = CBv2AttentionMetadataRecord(
            requestID: 2, outputIndex: 62, phase: "chained_decode", batchIndex: 0,
            batchSize: 1, inputWidth: 1, storageLayerIndex: 9, modelLayerIndex: 39,
            offsetBefore: 2, offsetAfter: 3, scaleBits: Float(0.5).bitPattern,
            queries: metadata["queries"]!, incomingKeys: metadata["incomingKeys"]!,
            incomingValues: metadata["incomingValues"]!,
            storage: ["visible_keys": metadata["storedKeys"]!, "visible_values": metadata["storedValues"]!],
            kernelOutputDType: "bfloat16", output: metadata["output"]!, dispatch: "contiguous_sdpa",
            sinksPresent: false, softcapPresent: false, spansPresent: false)
        let snapshot = CBv2AttentionMetadataSnapshot(
            configuration: try .init(requestID: 2, outputIndex: 62, maximumRecords: 1),
            records: [record], selectedForwards: 1, expectedOwnerCount: 1,
            forwardSucceeded: true, sampleOutcome: outcome, seedToken: 11346,
            targetToken: outcome == "confirmed" ? 1928 : nil, refusals: [:])
        if let missing { tensors.removeValue(forKey: missing) }
        return .init(configuration: try .init(requestID: 2, outputIndex: 62, storageLayerIndex: 9),
                     metadata: snapshot, evaluationStatus: outcome == "confirmed" ? "completed" : outcome,
                     reservedBytes: 256, tensors: tensors)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("packet-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test func emitsOneOwnerV1PacketWithExactNativeBytesAndIndependentIdentity() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("packet")
        let packet = try fixture()
        let artifact = String(repeating: "a", count: 64)
        let input = String(repeating: "b", count: 64)
        let result = try BenchmarkAttentionPacket.write(packet: packet, modelID: "fixture-qwen",
            verifiedModelSHA256: artifact, inputSHA256: input, backend: "contiguous", directory: destination)
        #expect(result["status"] as? String == "captured")
        let data = try Data(contentsOf: destination.appendingPathComponent("packet.json"))
        #expect(result["packet_sha256"] as? String == digest(data))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema"] as? String == "darkbloom.attention-packet.v1")
        let identity = try #require(object["identity"] as? [String: String])
        #expect(identity == ["modelID": "fixture-qwen", "artifactSHA256": artifact,
                             "inputSHA256": input, "backend": "contiguous"])
        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(metadata["recordIndex"] as? Int == 0)
        let metadataData = try Data(contentsOf: destination.appendingPathComponent("attention-metadata.json"))
        #expect(metadata["byteCount"] as? Int == metadataData.count)
        #expect(metadata["sha256"] as? String == digest(metadataData))
        let decoded = try #require(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        #expect(decoded["expectedOwnerCount"] as? Int == 1)
        #expect(decoded["sampleOutcome"] as? String == "confirmed")
        let records = try #require(decoded["records"] as? [[String: Any]])
        #expect(records.count == 1 && records[0]["storageLayerIndex"] as? Int == 9)
        #expect(records[0]["modelLayerIndex"] as? Int == 39)
        let tensors = try #require(object["tensors"] as? [String: [String: Any]])
        #expect(Set(tensors.keys) == Set(packet.tensors.keys))
        for (name, expected) in packet.tensors {
            let descriptor = try #require(tensors[name])
            let filename = try #require(descriptor["file"] as? String)
            let native = try Data(contentsOf: destination.appendingPathComponent(filename))
            #expect(native == expected.data)
            #expect(descriptor["dtype"] as? String == "bfloat16")
            #expect(descriptor["byteOrder"] as? String == "little")
            #expect(descriptor["shape"] as? [Int] == expected.shape)
            #expect(descriptor["packedStrides"] as? [Int] == expected.packedStrides)
            #expect(descriptor["byteCount"] as? Int == native.count)
            #expect(descriptor["sha256"] as? String == digest(native))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(names.count == 8, "six tensors, raw metadata, and the final descriptor")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func incompleteUnconfirmedOrUnverifiedPacketsCannotPublish() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("packet")
        let artifact = String(repeating: "a", count: 64)
        let input = String(repeating: "b", count: 64)
        for outcome in ["discarded", "retired_unconfirmed", "forward_failed"] {
            let result = try BenchmarkAttentionPacket.write(packet: fixture(outcome: outcome), modelID: "fixture",
                verifiedModelSHA256: artifact, inputSHA256: input, backend: "contiguous", directory: destination)
            #expect(result["status"] as? String == "inconclusive")
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        for hash in [nil, "unverified", String(repeating: "A", count: 64)] as [String?] {
            #expect(throws: (any Error).self) {
                try BenchmarkAttentionPacket.write(packet: fixture(), modelID: "fixture",
                    verifiedModelSHA256: hash, inputSHA256: input, backend: "contiguous", directory: destination)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(throws: (any Error).self) {
            try BenchmarkAttentionPacket.write(packet: fixture(missing: "storedKeys"), modelID: "fixture",
                verifiedModelSHA256: artifact, inputSHA256: input, backend: "contiguous", directory: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try BenchmarkAttentionPacket.write(packet: fixture(), modelID: "fixture",
                verifiedModelSHA256: artifact, inputSHA256: input, backend: "contiguous", directory: destination)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}
