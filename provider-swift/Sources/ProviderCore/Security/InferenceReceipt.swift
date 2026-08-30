import Foundation

/// Inference receipt: the canonical record of one inference.
///
/// The receipt binds the model (aggregate weight hash), the exact decrypted
/// request bytes (whose digest transitively binds every sampling parameter —
/// temperature, seed, max_tokens, messages), and the full response text. Its
/// receipt hash is the SHA-256 of its canonical JSON bytes; the Secure
/// Enclave signs that hash through the existing response attestation
/// channel unchanged: `response_hash` carries the hash, `se_signature`
/// signs it, and the new `receipt` field carries the canonical JSON.
///
/// Digests only — the receipt never contains prompt or response plaintext,
/// so it is safe to publish.
///
/// The canonical encoding is mirrored byte-for-byte by the coordinator
/// (`coordinator/receipt/receipt.go`) and pinned by the shared golden vectors
/// in `fixtures/receipts/receipt_vectors.json`. Keys are in alphabetical order;
/// strings escape exactly what JSON requires (backslash, quote, control
/// characters) and nothing more — no HTML escaping, no slash escaping.
public struct InferenceReceipt: Sendable, Equatable {
    public static let version = 2

    public let completionTokens: Int
    public let modelId: String
    /// Lowercase hex aggregate SHA-256 of the model weights; "" when the
    /// provider has no verified hash for the model.
    public let modelWeightHash: String
    public let promptTokens: Int
    public let requestId: String
    /// SHA-256 (lowercase hex) of the exact decrypted request body bytes.
    public let requestSha256: String
    /// SHA-256 (lowercase hex) of the full response text (UTF-8).
    public let responseSha256: String

    public init(
        completionTokens: Int,
        modelId: String,
        modelWeightHash: String,
        promptTokens: Int,
        requestId: String,
        requestSha256: String,
        responseSha256: String
    ) {
        self.completionTokens = completionTokens
        self.modelId = modelId
        self.modelWeightHash = modelWeightHash
        self.promptTokens = promptTokens
        self.requestId = requestId
        self.requestSha256 = requestSha256
        self.responseSha256 = responseSha256
    }

    /// Canonical JSON: single line, alphabetical keys, minimal escaping.
    /// Must stay byte-identical to `Receipt.Canonical()` in Go.
    public func canonicalJSON() -> String {
        var out = "{"
        out += "\"completion_tokens\":\(completionTokens)"
        out += ",\"model_id\":\(Self.encodeJSONString(modelId))"
        out += ",\"model_weight_hash\":\(Self.encodeJSONString(modelWeightHash))"
        out += ",\"prompt_tokens\":\(promptTokens)"
        out += ",\"request_id\":\(Self.encodeJSONString(requestId))"
        out += ",\"request_sha256\":\(Self.encodeJSONString(requestSha256))"
        out += ",\"response_sha256\":\(Self.encodeJSONString(responseSha256))"
        out += ",\"v\":\(Self.version)"
        out += "}"
        return out
    }

    /// Receipt hash: lowercase hex SHA-256 of the canonical receipt bytes.
    public func address() -> String {
        sha256Hex(Data(canonicalJSON().utf8))
    }

    /// Escape exactly what JSON requires and nothing more. Mirrors
    /// `encodeJSONString` in coordinator/receipt/receipt.go.
    static func encodeJSONString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

/// Compute the receipt attestation for a completed inference: the
/// canonical receipt JSON, its hash, and the Secure Enclave signature
/// over the hash. The signing contract is identical to the v1
/// `computeResponseAttestation` (DER ECDSA P-256 over SHA-256 of the UTF-8
/// address bytes) — only what the signed hash covers has grown.
public func computeReceiptAttestation(
    identity: (any AttestationSigner)?,
    receipt: InferenceReceipt
) -> (receipt: String, address: String, signature: String?) {
    let json = receipt.canonicalJSON()
    let address = sha256Hex(Data(json.utf8))

    var signature: String?
    if let identity {
        if let sigData = try? identity.sign(Data(address.utf8)) {
            signature = sigData.base64EncodedString()
        }
    }
    return (json, address, signature)
}
