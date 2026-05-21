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

// MARK: - Generic frame sealing helpers
//
// Used by ClusterSession.sendInferenceFrame / receiveInferenceFrame and by
// rank 1's handleConnection to seal every post-handshake ClusterFrame on the
// wire with AES-256-GCM. Without these, TP control frames (promptTokens,
// stepToken, sessionStop, jacclBootstrap, ping, pong) would travel in
// plaintext over the Thunderbolt cable — anyone with physical link access
// could observe prompt and response token IDs and trivially recover the
// consumer's content via the tokenizer.
//
// PP's TensorCrypto.sealActivation / openActivation provide a SECOND inner
// seal on activation/token payloads for defense in depth; that path is
// unchanged.

public enum ClusterLinkSeal {
    /// Wrap a raw cluster frame in AES-256-GCM using the session key.
    public static func seal(_ frame: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(frame, using: key)
        guard let combined = sealed.combined else {
            throw TensorCryptoError.arrayDataUnavailable
        }
        return combined
    }

    /// Unwrap an AES-256-GCM sealed cluster frame. Throws on auth failure
    /// (tampered ciphertext, wrong key) or malformed envelope.
    public static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: key)
    }
}

public enum TensorCrypto {

    // MARK: - Seal activation (rank 0 → rank 1)

    /// Encrypt seqLen + activation tensor into a single AES-GCM sealed blob.
    /// Pass seqLen = -1 (with any activation) to produce a stop sentinel.
    ///
    /// The activation MUST be bfloat16. Llama-3.x checkpoints are bf16; if
    /// a future TP-supported model ships with fp16 or fp32 activations, this
    /// will throw `dtypeMismatch` rather than silently produce wrong bytes.
    /// The fix at that point is to embed a dtype byte in the wire format and
    /// update `openActivation` to decode according to it.
    public static func sealActivation(
        seqLen: Int32,
        activation: MLXArray,
        key: SymmetricKey
    ) throws -> Data {
        var plaintext = Data(capacity: 4 + Int(mlx_array_nbytes(activation.ctx)))
        withUnsafeBytes(of: seqLen.littleEndian) { plaintext.append(contentsOf: $0) }

        if seqLen != -1 {
            mlx_array_eval(activation.ctx)
            // Validate dtype up-front rather than relying on
            // `mlx_array_data_bfloat16` to return nil for non-bf16 — its
            // documented behavior on type mismatch is unspecified in older
            // mlx-c versions, and a silent reinterpret would corrupt the
            // sealed payload.
            guard activation.dtype == .bfloat16 else {
                throw TensorCryptoError.dtypeMismatch(
                    expected: "bfloat16", got: "\(activation.dtype)")
            }
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

public enum TensorCryptoError: Error, CustomStringConvertible, Sendable {
    case arrayDataUnavailable
    case truncatedPayload
    case dtypeMismatch(expected: String, got: String)

    public var description: String {
        switch self {
        case .arrayDataUnavailable:
            return "MLXArray data pointer was nil"
        case .truncatedPayload:
            return "sealed tensor payload is too short"
        case .dtypeMismatch(let expected, let got):
            return "tensor dtype mismatch: expected \(expected), got \(got)"
        }
    }
}
