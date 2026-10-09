import Foundation
import MLXLMCommon

/// Split the token axis independently for each KV head. Flattening a growing
/// [1, H, T, D] tensor into fixed byte chunks moves later head boundaries and
/// hides identical prefixes. Other complete state stays checkpoint-specific.
enum SSDCheckpointPageGeometry {
    static let strideTokens = 1024
    static let maximumPages = 8192

    struct Page: Sendable {
        let tensor: Int
        let offset: Int
        let bytes: Int
        let coordinate: String
    }

    static func pages(_ manifest: CBv2CompleteCheckpointManifest) throws -> [Page] {
        _ = try manifest.validateStructure()
        var result: [Page] = []
        func append(_ page: Page) throws {
            guard result.count < maximumPages else { throw CBv2CompleteCheckpointError.invalidManifest }
            result.append(page)
        }
        for (index, tensor) in manifest.tensors.enumerated() {
            if (tensor.role == .keys || tensor.role == .values), tensor.shape.count == 4,
                tensor.shape[0] == 1, tensor.shape[2] <= manifest.position {
                let heads = tensor.shape[1], tokens = tensor.shape[2]
                let rowBytes = tensor.byteCount / heads / tokens
                let firstToken = manifest.position - tokens
                let cap = min(strideTokens, CBv2CompleteCheckpointManifest.maximumSegmentBytes / rowBytes)
                guard cap > 0 else { throw CBv2CompleteCheckpointError.invalidSegment }
                for head in 0..<heads {
                    var token = 0
                    while token < tokens {
                        // Align absolute ranges, including partially filled sliding pages.
                        let absolute = firstToken + token
                        let count = min(tokens - token, cap - absolute % cap)
                        try append(.init(tensor: index,
                            offset: (head * tokens + token) * rowBytes, bytes: count * rowBytes,
                            coordinate: "kv:\(tensor.role.rawValue):\(tensor.layer ?? -1):\(tensor.dtype.rawValue):\(tensor.shape[3]):\(head):\(absolute):\(count)"))
                        token += count
                    }
                }
            } else {
                var offset = 0
                while offset < tensor.byteCount {
                    let count = min(CBv2CompleteCheckpointManifest.maximumSegmentBytes, tensor.byteCount - offset)
                    try append(.init(tensor: index, offset: offset, bytes: count,
                        coordinate: "state:\(manifest.position):\(index):\(offset):\(count)"))
                    offset += count
                }
            }
        }
        return result
    }
}
