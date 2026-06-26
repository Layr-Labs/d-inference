/// ActivationCodec -- serialize a hidden-state `MLXArray` to bytes and back,
/// so it can be sealed (`ClusterLinkCrypto`) and shipped across the encrypted
/// ring link.
///
/// In a plaintext exo cluster the activation crosses the wire via MLX's native
/// `mx.distributed.send` (raw tensor, no encryption). Darkbloom cannot do that:
/// the activation is sensitive (approximately invertible to the prompt) and the
/// link is operator-controlled. So we take the tensor out of MLX as bytes,
/// AEAD-seal it, transfer ciphertext, then rebuild the tensor on the peer. The
/// transferred frame carries a tiny header (dtype + shape) so the receiver can
/// reconstruct the exact array.
///
/// Pure MLX + Foundation. The round-trip (encode → bytes → decode) is testable
/// on one machine; only the *transport* of those bytes needs two machines.

import Foundation
import MLX

public enum ActivationCodecError: Error, Equatable, Sendable {
    case unsupportedDType(String)
    case truncatedHeader
    case shapeByteMismatch(expected: Int, got: Int)
}

/// Wire-stable dtype tags for the activation header. Pipeline activations are
/// floating hidden states; we support the dtypes mlx-swift-lm emits.
enum ActivationDType: UInt8 {
    case float32 = 1
    case float16 = 2
    case bfloat16 = 3

    init(_ dtype: DType) throws {
        switch dtype {
        case .float32: self = .float32
        case .float16: self = .float16
        case .bfloat16: self = .bfloat16
        default: throw ActivationCodecError.unsupportedDType("\(dtype)")
        }
    }

    var mlx: DType {
        switch self {
        case .float32: return .float32
        case .float16: return .float16
        case .bfloat16: return .bfloat16
        }
    }
}

public enum ActivationCodec {
    /// Frame layout (all integers big-endian):
    ///   [1]  dtype tag
    ///   [1]  rank (number of shape dims, ≤ 255)
    ///   [4]*rank  each dimension as UInt32
    ///   [..] raw tensor bytes (contiguous, row-major)
    public static func encode(_ array: MLXArray) throws -> Data {
        array.eval()
        let tag = try ActivationDType(array.dtype)
        let shape = array.shape
        precondition(shape.count <= 255, "activation rank too large")

        var out = Data()
        out.append(tag.rawValue)
        out.append(UInt8(shape.count))
        for dim in shape {
            var be = UInt32(dim).bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
        out.append(array.asData(access: .copy).data)
        return out
    }

    /// Reconstruct the `MLXArray` from a frame produced by `encode`.
    public static func decode(_ data: Data) throws -> MLXArray {
        guard data.count >= 2 else { throw ActivationCodecError.truncatedHeader }
        var idx = data.startIndex
        guard let tag = ActivationDType(rawValue: data[idx]) else {
            throw ActivationCodecError.unsupportedDType("tag=\(data[idx])")
        }
        idx = data.index(after: idx)
        let rank = Int(data[idx])
        idx = data.index(after: idx)

        let shapeBytes = rank * 4
        guard data.distance(from: idx, to: data.endIndex) >= shapeBytes else {
            throw ActivationCodecError.truncatedHeader
        }
        var shape = [Int]()
        for _ in 0..<rank {
            var be: UInt32 = 0
            withUnsafeMutableBytes(of: &be) { dst in
                for b in 0..<4 { dst[b] = data[data.index(idx, offsetBy: b)] }
            }
            shape.append(Int(UInt32(bigEndian: be)))
            idx = data.index(idx, offsetBy: 4)
        }

        let payload = data.subdata(in: idx..<data.endIndex)
        let expected = shape.reduce(1, *) * tag.mlx.size
        guard payload.count == expected else {
            throw ActivationCodecError.shapeByteMismatch(expected: expected, got: payload.count)
        }
        return MLXArray(payload, shape, dtype: tag.mlx)
    }
}
