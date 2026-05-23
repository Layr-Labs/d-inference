import CryptoKit
import Foundation
import MLX
import Cmlx

// MARK: - TensorCrypto
//
// AES-256-GCM encryption/decryption for MLXArray data in transit.
//
// Wire format of a sealed tensor message:
//   [12 bytes: AES-GCM nonce] [N bytes: ciphertext + 16-byte tag]
//
// Plaintext layout inside the GCM envelope:
//   [4 bytes: seqLen as Int32 little-endian]   ← -1 = stop sentinel
//   [N bytes: raw bfloat16 tensor bytes]        ← absent when seqLen == -1

public enum TensorCrypto {

    // MARK: - Seal activation (rank 0 → rank 1)

    /// Encrypt seqLen + activation tensor into a single AES-GCM sealed blob.
    /// Pass seqLen = -1 (with any activation) to produce a stop sentinel.
    public static func sealActivation(
        seqLen: Int32,
        activation: MLXArray,
        key: SymmetricKey
    ) throws -> Data {
        var plaintext = Data(capacity: 4 + Int(mlx_array_nbytes(activation.ctx)))
        withUnsafeBytes(of: seqLen.littleEndian) { plaintext.append(contentsOf: $0) }

        if seqLen != -1 {
            mlx_array_eval(activation.ctx)
            guard let ptr = mlx_array_data_bfloat16(activation.ctx) else {
                throw TensorCryptoError.arrayDataUnavailable
            }
            let byteCount = Int(mlx_array_nbytes(activation.ctx))
            plaintext.append(Data(bytes: UnsafeRawPointer(ptr), count: byteCount))
        }

        return try seal(plaintext, key: key)
    }

    /// Decrypt a sealed activation frame. Returns seqLen and the reconstructed tensor.
    /// seqLen == -1 means stop sentinel (no tensor follows).
    /// Shape is derived as [1, seqLen, hiddenDim] — the caller supplies hiddenDim from config.
    public static func openActivation(
        _ sealed: Data,
        key: SymmetricKey,
        hiddenDim: Int
    ) throws -> (seqLen: Int32, activation: MLXArray?) {
        let plaintext = try open(sealed, key: key)
        guard plaintext.count >= 4 else { throw TensorCryptoError.truncatedPayload }

        let seqLen = plaintext.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
        if seqLen == -1 { return (-1, nil) }

        let tensorBytes = plaintext.dropFirst(4)
        let shape = [1, Int(seqLen), hiddenDim]
        let array = try arrayFromBytes(tensorBytes, shape: shape, dtype: .bfloat16)
        return (seqLen, array)
    }

    // MARK: - Seal token (rank 1 → rank 0)

    /// Encrypt a single Int32 token ID.
    public static func sealToken(_ tokenID: Int32, key: SymmetricKey) throws -> Data {
        var plaintext = Data(count: 4)
        withUnsafeBytes(of: tokenID.littleEndian) { plaintext.replaceSubrange(0..<4, with: $0) }
        return try seal(plaintext, key: key)
    }

    /// Decrypt a sealed token frame, returning the token ID.
    public static func openToken(_ sealed: Data, key: SymmetricKey) throws -> Int32 {
        let plaintext = try open(sealed, key: key)
        guard plaintext.count >= 4 else { throw TensorCryptoError.truncatedPayload }
        return plaintext.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
    }

    // MARK: - Seal stop sentinel (rank 0 → rank 1)

    public static func sealStop(key: SymmetricKey) throws -> Data {
        var plaintext = Data(count: 4)
        withUnsafeBytes(of: Int32(-1).littleEndian) { plaintext.replaceSubrange(0..<4, with: $0) }
        return try seal(plaintext, key: key)
    }

    // MARK: - AES-256-GCM primitives

    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        // nonce (12) + ciphertext + tag (16)
        return sealed.combined!
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }

    // MARK: - MLXArray ↔ raw bytes

    static func arrayFromBytes(_ bytes: Data, shape: [Int], dtype: DType) throws -> MLXArray {
        var result = mlx_array_new()
        let cShape = shape.map { Int32($0) }
        bytes.withUnsafeBytes { rawPtr in
            _ = mlx_array_set_data(
                &result,
                rawPtr.baseAddress!,
                cShape,
                Int32(cShape.count),
                dtype.cmlxDtype
            )
        }
        return MLXArray(result)
    }
}

// MARK: - Errors

public enum TensorCryptoError: Error, Sendable {
    case arrayDataUnavailable
    case truncatedPayload
}
