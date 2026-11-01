import Foundation
import CryptoKit
import ProviderCoreFoundation
import DarkbloomClusterProtocol

enum DistributedInstalledManifest {
    /// The native decoder reads a subset of ModelManifest. Validate the full
    /// product record from the same pinned raw bytes before publishing its route.
    /// Recomputing metadata digests does not verify checkpoint payload contents.
    static func validate(_ data: Data, configuration: ClusterConfiguration,
                         capability: ClusterRuntimeCapability) throws -> ModelManifest {
        guard !data.isEmpty, data.count <= 65_536,
              ClusterConfigurationCodec.sha256(data) == capability.manifestSHA256 else {
            throw ClusterConfigurationError.invalid("Product manifest raw pin or bound differs")
        }
        var scan = Data(), quoted = false, escaped = false
        for byte in data {
            if quoted {
                scan.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else {
                if byte == 34 { quoted = true }
                scan.append([9, 10, 13].contains(byte) ? 32 : byte)
            }
        }
        scan.append(10)
        try validateClusterWorkerEnvelope(scan, commandStream: true)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schema_version", "model_id", "version", "r2_prefix", "aggregate_sha256",
                "total_size_bytes", "file_count", "files", "created_at"]),
              let entries = object["files"] as? [[String: Any]], (1...4096).contains(entries.count),
              entries.allSatisfy({ Set($0.keys) == Set(["path", "size_bytes", "sha256", "role"]) }) else {
            throw ClusterConfigurationError.invalid("Product manifest fields differ")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(ModelManifest.self, from: data)
        guard value.schemaVersion == 1, value.modelID == configuration.publicModelID,
              value.aggregateSHA256 == capability.artifactSHA256,
              value.fileCount == value.files.count, Set(value.files.map(\.path)).count == value.files.count,
              value.totalSizeBytes > 0,
              [value.version, value.r2Prefix].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }),
              value.files.allSatisfy({ ClusterConfigurationSyntax.relativePath($0.path)
                && ClusterConfigurationSyntax.hash($0.sha256) && $0.sizeBytes >= 0
                && ["weight", "tokenizer", "config", "template", "preprocessor", "index", "other"].contains($0.role) }) else {
            throw ClusterConfigurationError.invalid("Product model identity or inventory differs")
        }
        var sum: Int64 = 0, digest = SHA256()
        for entry in value.files.sorted(by: { $0.path < $1.path }) {
            let next = sum.addingReportingOverflow(entry.sizeBytes)
            guard !next.overflow else { throw ClusterConfigurationError.invalid("Product manifest byte sum overflow") }
            sum = next.partialValue
            let hex = Array(entry.sha256.utf8)
            func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
            let raw = stride(from: 0, to: 64, by: 2).map { nibble(hex[$0]) * 16 + nibble(hex[$0 + 1]) }
            digest.update(data: Data(raw))
        }
        let aggregate = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard sum == value.totalSizeBytes, aggregate == value.aggregateSHA256,
              let config = value.files.first(where: { $0.path == "config.json" }),
              config.role == "config", config.sha256 == capability.configurationSHA256 else {
            throw ClusterConfigurationError.invalid("Product manifest config or aggregate differs")
        }
        let tokenizer = value.files.filter { ["tokenizer", "template"].contains($0.role) }
        guard Set(tokenizer.map(\.path)) == Set(configuration.tokenizerFiles.map(\.path)),
              configuration.tokenizerFiles.allSatisfy({ pin in
                tokenizer.contains(where: { $0.path == pin.path && $0.sha256 == pin.sha256
                    && $0.role == (pin.purpose == .tokenizer ? "tokenizer" : "template") })
              }) else {
            throw ClusterConfigurationError.invalid("Tokenizer/template pins must cover the exact product inventory")
        }
        return value
    }
}
