import Foundation
import MLX

/// Real affine W4 tensors generated directly in their stored representation.
/// A selected reader generates only requested expert planes. No float model or
/// full-bank tensor is constructed to initialize a rank-local bank.
struct ExpertAxisSyntheticSource {
    let geometry: ExpertAxisGeometry

    func read(_ name: String, selection: TensorSelection) throws -> MLXArray {
        let sourceShape = try geometry.shape(name)
        let shape = try selection.resultShape(sourceShape)
        let ids: [Int]
        switch selection {
        case .all: ids = Array(0..<geometry.experts)
        case .axis(let axis, let ranges):
            guard axis == 0 else { throw ProbeError("Synthetic expert reader requires whole expert planes") }
            ids = ranges.flatMap { Array($0) }
        }
        let dtype = geometry.dtype(name), plane = shape[1] * shape[2]
        var data = Data(count: shape.reduce(dtype.size, *))
        data.withUnsafeMutableBytes { raw in
            if dtype == .uint32 {
                let words = raw.bindMemory(to: UInt32.self)
                let salt: UInt32 = name.hasPrefix("gate") ? 17 : name.hasPrefix("up") ? 71 : 139
                for (local, global) in ids.enumerated() {
                    for index in 0..<plane {
                        // All eight nibbles vary with global expert and position.
                        let key = UInt32(index) &* 1_664_525 &+ UInt32(global) &* 1_013_904_223 &+ salt
                        words[local * plane + index] = (key ^ (key >> 11)).littleEndian
                    }
                }
            } else {
                let offset = name.hasSuffix(".biases")
                for (local, global) in ids.enumerated() {
                    // Exactly representable BF16 metadata and finite projections.
                    let scale = Float(1 + global % 3) / 512
                    let value = offset ? -7 * scale : scale
                    for index in 0..<plane {
                        let position = local * plane + index
                        if dtype == .float32 { raw.bindMemory(to: UInt32.self)[position] = value.bitPattern.littleEndian }
                        else { raw.bindMemory(to: UInt16.self)[position] = UInt16(value.bitPattern >> 16).littleEndian }
                    }
                }
            }
        }
        return MLXArray(data, shape, dtype: dtype)
    }
}
