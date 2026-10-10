import DarkbloomClusterPlacement
import Foundation

/// An artifact directory as placement reads it: tensor headers and the
/// configuration, nothing else. No weight byte is read and nothing is hashed,
/// so this takes milliseconds for a model of any size. It proves nothing
/// about the payload; the verified loader does that when a rank loads.
public enum ClusterPlacementArtifact {
    static let maximumHeaderBytes = 16 * 1024 * 1024
    static let maximumFiles = 512

    /// Every stored tensor named by the safetensors headers of a flat
    /// directory of regular files.
    public static func storedTensors(directory: URL) throws -> [ClusterPlacementStoredTensor] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".safetensors") }.sorted()
        guard !names.isEmpty, names.count <= maximumFiles else {
            throw ProbeError("The model directory has no safetensors file, or more than \(maximumFiles)")
        }
        var result: [ClusterPlacementStoredTensor] = [], seen = Set<String>()
        for name in names {
            let url = directory.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? Int, size >= 8 else {
                throw ProbeError("Not a regular safetensors file: \(name)")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else { throw ProbeError("Truncated safetensors file: \(name)") }
            let length64 = prefix.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            guard length64 <= UInt64(maximumHeaderBytes), Int(length64) <= size - 8 else {
                throw ProbeError("Invalid or oversized safetensors header: \(name)")
            }
            let length = Int(length64)
            guard let bytes = try handle.read(upToCount: length), bytes.count == length,
                  let header = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw ProbeError("Invalid safetensors header: \(name)")
            }
            for (tensor, value) in header where tensor != "__metadata__" {
                guard seen.insert(tensor).inserted, let entry = value as? [String: Any],
                      let dtype = entry["dtype"] as? String, let shape = entry["shape"] as? [Int],
                      let offsets = entry["data_offsets"] as? [Int], offsets.count == 2,
                      offsets[0] >= 0, offsets[1] > offsets[0], offsets[1] <= size - 8 - length else {
                    throw ProbeError("Invalid or duplicate safetensors entry: \(tensor)")
                }
                result.append(.init(name: tensor, byteCount: offsets[1] - offsets[0], dtype: dtype, shape: shape))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// The layout of the artifact in a directory, from its `config.json` and
    /// tensor headers.
    public static func layout(directory: URL) throws -> ClusterModelLayout {
        let configuration = try BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576)
        return try ClusterPlacementLayouts.layout(configuration: configuration, tensors: storedTensors(directory: directory))
    }
}
