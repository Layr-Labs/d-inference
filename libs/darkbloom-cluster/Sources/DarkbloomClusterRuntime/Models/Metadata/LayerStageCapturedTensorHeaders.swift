import Foundation

struct LayerStageCapturedTensorHeader {
    let sourceFile: String
    let data: Data
}

/// Pure projection of already captured header/index bytes. No file is opened or authenticated.
enum LayerStageCapturedTensorHeaders {
    static func parse(manifest: CheckpointManifest, index: Data,
                      headers: [LayerStageCapturedTensorHeader]) throws -> [LayerStageSourceTensor] {
        guard (1...32).contains(headers.count), (1...2_097_152).contains(index.count),
              Set(headers.map(\.sourceFile)).count == headers.count,
              manifest.files.count == manifest.file_count, (1...64).contains(manifest.files.count),
              Set(manifest.files.map(\.path)).count == manifest.files.count else {
            throw ProbeError("Captured header inputs exceed bounds or duplicate files")
        }
        try validateWorkerJSON(index)
        struct Index: Decodable {
            struct Metadata: Decodable { let total_size: Int }
            let metadata: Metadata
            let weight_map: [String: String]
        }
        let decoded = try JSONDecoder().decode(Index.self, from: index)
        let files = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        guard Set(headers.map(\.sourceFile)) == Set(files.keys.filter { $0.hasSuffix(".safetensors") }),
              (1...4096).contains(decoded.weight_map.count) else { throw ProbeError("Captured index/file coverage differs") }
        var result: [String: LayerStageSourceTensor] = [:]
        for capture in headers {
            guard (1...2_097_152).contains(capture.data.count), let file = files[capture.sourceFile],
                  file.size_bytes >= 8 + capture.data.count else { throw ProbeError("Invalid captured header size") }
            try validateWorkerJSON(capture.data)
            guard let object = try JSONSerialization.jsonObject(with: capture.data) as? [String: Any],
                  object["__metadata__"] as? [String: String] == ["format": "mlx"] else {
                throw ProbeError("Captured header format differs")
            }
            var spans: [Range<Int>] = []
            for (name, raw) in object where name != "__metadata__" {
                guard result[name] == nil, result.count < 4096,
                      let entry = raw as? [String: Any], Set(entry.keys) == ["dtype", "shape", "data_offsets"],
                      let shapeValues = entry["shape"] as? [Any],
                      let offsetValues = entry["data_offsets"] as? [Any], offsetValues.count == 2,
                      let dtype = entry["dtype"] as? String else { throw ProbeError("Malformed or duplicate captured tensor") }
                let shape = shapeValues.compactMap { BoundedProbeInput.integer($0) }
                let offsets = offsetValues.compactMap { BoundedProbeInput.integer($0) }
                guard shape.count == shapeValues.count, offsets.count == 2,
                      offsets[0] >= 0, offsets[1] > offsets[0],
                      offsets[1] <= file.size_bytes - 8 - capture.data.count,
                      decoded.weight_map[name] == capture.sourceFile else { throw ProbeError("Captured tensor extent/index mismatch") }
                let layout = try LayerStageTensorLayout(canonicalName: name, shape: shape,
                    sourceDType: dtype, byteCount: offsets[1] - offsets[0])
                result[name] = try LayerStageSourceTensor(layout: layout, sourceFile: capture.sourceFile,
                    sourceOffset: QwenLongPrefillCheckedBytes.sum([8, capture.data.count, offsets[0]]))
                spans.append(offsets[0]..<offsets[1])
            }
            var end = 0
            for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                guard span.lowerBound == end else { throw ProbeError("Captured tensor extents overlap or contain gaps") }
                end = span.upperBound
            }
            guard end == file.size_bytes - 8 - capture.data.count else { throw ProbeError("Captured extents do not cover declared payload") }
        }
        guard Set(result.keys) == Set(decoded.weight_map.keys),
              try QwenLongPrefillCheckedBytes.sum(result.values.map { $0.layout.byteCount }) == decoded.metadata.total_size else {
            throw ProbeError("Captured tensor coverage or byte total differs from index")
        }
        return result.values.sorted { $0.layout.canonicalName < $1.layout.canonicalName }
    }
}
