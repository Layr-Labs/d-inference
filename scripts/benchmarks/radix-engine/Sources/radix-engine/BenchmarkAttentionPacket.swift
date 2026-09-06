import CryptoKit
import Foundation
@_spi(Diagnostics) import MLXLMCommon

/// Idle-only export of finalized host bytes. No tensor evaluation or model work.
enum BenchmarkAttentionPacket {
    static func install(_ configuration: CBv2AttentionPacketConfig?, loaded: Loaded) throws {
        guard let configuration else { return }
        guard let engine = loaded.engine as? EngineV2, loaded.verifiedModelHash != nil else {
            throw RadixBenchmark.Failure.message("attention packet requires the verified serving engine")
        }
        try engine.configureAttentionPacket(configuration)
    }

    static func take(loaded: Loaded, modelID: String, inputSHA256: String,
                     directory: URL) throws -> [String: Any] {
        guard let engine = loaded.engine as? EngineV2,
            let packet = try engine.takeAttentionPacketSnapshot() else {
            throw RadixBenchmark.Failure.message("attention packet disappeared before idle drain")
        }
        try engine.configureAttentionPacket(nil)
        return try write(packet: packet, modelID: modelID, verifiedModelSHA256: loaded.verifiedModelHash,
                         inputSHA256: inputSHA256, backend: loaded.backend, directory: directory)
    }

    /// Pure host export seam, also exercised without creating an engine/model.
    static func write(packet: CBv2AttentionPacketSnapshot, modelID: String,
                      verifiedModelSHA256: String?, inputSHA256: String,
                      backend: String, directory: URL) throws -> [String: Any] {
        let metadata = packet.metadata
        let metadataData = try JSONEncoder().encode(metadata)
        var summary: [String: Any] = [
            "status": "inconclusive", "evaluation_status": packet.evaluationStatus,
            "reserved_bytes": packet.reservedBytes,
            "snapshot": try JSONSerialization.jsonObject(with: metadataData),
            "timing_scope": "Packet gather, successor barrier and host copies are diagnostic overhead; timing is not release performance evidence.",
            "proof_scope": "Actual input, stored-view and returned-output bytes for one confirmed owner; native replay and an independent history mirror are separate proofs.",
        ]
        guard packet.evaluationStatus == "completed", metadata.forwardSucceeded,
            metadata.sampleOutcome == "confirmed", metadata.selectedForwards == 1,
            metadata.expectedOwnerCount == 1, metadata.records.count == 1,
            metadata.refusals.isEmpty, let record = metadata.records.first,
            record.storageLayerIndex == packet.configuration.storageLayerIndex else { return summary }
        guard let artifact = verifiedModelSHA256, validSHA256(artifact), validSHA256(inputSHA256),
            ["paged", "contiguous"].contains(backend), metadataData.count <= 256 * 1_024 else {
            throw RadixBenchmark.Failure.message("packet identity or metadata size is invalid")
        }
        let files = ["queries": "queries.bin", "incomingKeys": "incoming-keys.bin",
                     "incomingValues": "incoming-values.bin", "storedKeys": "stored-keys.bin",
                     "storedValues": "stored-values.bin", "output": "output.bin"]
        guard Set(packet.tensors.keys) == Set(files.keys) else {
            throw RadixBenchmark.Failure.message("packet must contain exactly six native tensors")
        }
        var tensors: [String: Any] = [:]
        var bytes = 0
        for (name, file) in files {
            let tensor = packet.tensors[name]!
            bytes += tensor.data.count
            guard bytes <= CBv2AttentionPacketConfig.byteLimit else {
                throw RadixBenchmark.Failure.message("packet native byte budget exceeded")
            }
            tensors[name] = ["file": file, "dtype": tensor.dtype, "byteOrder": "little",
                             "shape": tensor.shape, "packedStrides": tensor.packedStrides,
                             "byteCount": tensor.data.count, "sha256": digest(tensor.data)]
        }
        let body: [String: Any] = [
            "schema": "darkbloom.attention-packet.v1",
            "identity": ["modelID": modelID, "artifactSHA256": artifact,
                         "inputSHA256": inputSHA256, "backend": backend],
            "metadata": ["file": "attention-metadata.json", "byteCount": metadataData.count,
                         "sha256": digest(metadataData), "recordIndex": 0],
            "geometry": ["attention": "full", "isBidirectional": false, "sharesKV": false,
                         "mtpEnabled": false, "visibleStart": 0, "visibleEnd": record.offsetAfter],
            "capture": ["evaluationStatus": "completed", "tensorPayloadBytes": bytes],
            "tensors": tensors,
        ]
        let packetData = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        guard packetData.count <= 256 * 1_024, !FileManager.default.fileExists(atPath: directory.path) else {
            throw RadixBenchmark.Failure.message("packet directory already exists or manifest exceeds budget")
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try metadataData.write(to: directory.appendingPathComponent("attention-metadata.json"), options: .atomic)
        for (name, file) in files {
            try packet.tensors[name]!.data.write(to: directory.appendingPathComponent(file), options: .atomic)
        }
        // Publish the descriptor last: a partially written directory is never a complete packet.
        try packetData.write(to: directory.appendingPathComponent("packet.json"), options: .atomic)
        summary["status"] = "captured"
        summary["directory"] = directory.path
        summary["packet_sha256"] = digest(packetData)
        summary["tensor_payload_bytes"] = bytes
        return summary
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
