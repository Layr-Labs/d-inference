import Foundation

/// Minimal, dependency-free (Foundation-only) safetensors shard-header sizing
/// utility. Parses ONLY the JSON header of each shard (never tensor bytes) to
/// sum byte sizes for tensors whose keys satisfy a predicate.
///
/// Used by the streaming-aware memory-admission math (see
/// `ExpertStreamingAdmission`) to size the routed-expert (`switch_mlp`)
/// footprint DeepSeek-V4 MoE-expert-streaming skips loading resident — see
/// `DeepseekV4ExpertStreaming` in `libs/mlx-swift-lm` (read-only from this
/// repo's side; NOT modified here). Deliberately independent of that
/// library's own `SafetensorsLayout` (MLX-adjacent, internal `parseHeader`)
/// so this admission math stays pure, Foundation-only, and independently
/// unit-testable without an MLX/Metal dependency.
///
/// Format (https://github.com/huggingface/safetensors):
///   [8 bytes little-endian u64: header length N]
///   [N bytes: JSON header — {"tensor.name": {"dtype", "shape",
///     "data_offsets": [start, end]}, ..., "__metadata__": {...}}]
///   [raw tensor bytes, contiguous]
/// `data_offsets` deltas (end - start) ARE the tensor's byte size, so summing
/// them needs no dtype/shape decoding — cheaper than a full tensor layout.
public enum SafetensorsSizing {

    public struct SizingError: Error, Equatable {
        public let path: String
        public let reason: String
    }

    /// Sum the byte size of every tensor in `snapshotDir`'s safetensors
    /// shard(s) whose key satisfies `matching`. Reads
    /// `model.safetensors.index.json` (if present) to enumerate shard
    /// filenames without guessing; falls back to every `*.safetensors` file
    /// directly for single-shard checkpoints or ones missing an index.
    /// Returns 0 when there is no index and no `.safetensors` files —
    /// callers treat that as "nothing matched", not a hard failure.
    public static func sumTensorBytes(
        in snapshotDir: URL,
        matching: (String) -> Bool
    ) throws -> UInt64 {
        var total: UInt64 = 0
        for name in try shardFileNames(in: snapshotDir) {
            let url = snapshotDir.appendingPathComponent(name)
            total += try sumMatchingTensorBytes(in: url, matching: matching)
        }
        return total
    }

    /// Shard filenames referenced by `model.safetensors.index.json`'s
    /// `weight_map`, or every `*.safetensors` file directly when there is no
    /// index (single-shard checkpoint). Exposed (not `private`) for testing.
    static func shardFileNames(in snapshotDir: URL) throws -> [String] {
        let indexURL = snapshotDir.appendingPathComponent("model.safetensors.index.json")
        let fm = FileManager.default
        if fm.fileExists(atPath: indexURL.path) {
            let data = try Data(contentsOf: indexURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let weightMap = json["weight_map"] as? [String: String]
            else {
                throw SizingError(path: indexURL.path, reason: "malformed weight_map")
            }
            return Array(Set(weightMap.values)).sorted()
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: snapshotDir.path) else {
            return []
        }
        return entries.filter { $0.hasSuffix(".safetensors") }.sorted()
    }

    /// Parse one shard's header and sum `data_offsets` deltas for matching
    /// keys. Only the 8-byte length prefix + JSON header are read — the
    /// (potentially many-GB) tensor payload after it is never touched.
    /// Exposed (not `private`) so it's independently unit-testable against a
    /// hand-built safetensors file.
    static func sumMatchingTensorBytes(
        in fileURL: URL,
        matching: (String) -> Bool
    ) throws -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw SizingError(path: fileURL.path, reason: "cannot open file")
        }
        defer { try? handle.close() }

        guard let lengthData = try handle.read(upToCount: 8), lengthData.count == 8 else {
            throw SizingError(path: fileURL.path, reason: "file too short for a safetensors header")
        }
        let headerLength = Int(lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        guard headerLength > 0,
            let headerData = try handle.read(upToCount: headerLength),
            headerData.count == headerLength
        else {
            throw SizingError(path: fileURL.path, reason: "truncated safetensors header")
        }

        guard let json = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw SizingError(path: fileURL.path, reason: "invalid safetensors header JSON")
        }

        var total: UInt64 = 0
        for (key, value) in json {
            guard key != "__metadata__", matching(key) else { continue }
            guard let entry = value as? [String: Any],
                let offsets = entry["data_offsets"] as? [Any], offsets.count == 2,
                let start = (offsets[0] as? NSNumber)?.int64Value,
                let end = (offsets[1] as? NSNumber)?.int64Value,
                end >= start
            else {
                // Skip a malformed entry rather than failing the whole shard —
                // sizing is a best-effort admission input, not a correctness
                // requirement for inference itself.
                continue
            }
            total += UInt64(end - start)
        }
        return total
    }
}
