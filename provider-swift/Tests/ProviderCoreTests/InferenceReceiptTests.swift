import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

// Inference receipt canonical form twin tests.
//
// The Go coordinator (coordinator/receipt) and this Swift provider must
// produce byte identical canonical receipt JSON; both the receipt hash and
// the Secure Enclave signature cover these bytes. The shared golden vectors
// in fixtures/receipts/receipt_vectors.json (generated independently of both
// implementations) pin the contract; the Go side runs the same vectors in
// coordinator/receipt/receipt_test.go.

private struct ReceiptVector: Decodable {
    struct Fields: Decodable {
        let completion_tokens: Int
        let model_id: String
        let model_weight_hash: String
        let prompt_tokens: Int
        let request_id: String
        let request_sha256: String
        let response_sha256: String
        let v: Int
    }
    let name: String
    let receipt: Fields
    let canonical: String
    let address: String
}

private func loadVectors() throws -> [ReceiptVector] {
    // Tests/ProviderCoreTests/InferenceReceiptTests.swift → repo root
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ProviderCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // provider-swift
        .deletingLastPathComponent() // repo root
    let url = repoRoot
        .appendingPathComponent("fixtures")
        .appendingPathComponent("receipts")
        .appendingPathComponent("receipt_vectors.json")
    return try JSONDecoder().decode([ReceiptVector].self, from: Data(contentsOf: url))
}

private func makeReceipt(_ f: ReceiptVector.Fields) -> InferenceReceipt {
    InferenceReceipt(
        completionTokens: f.completion_tokens,
        modelId: f.model_id,
        modelWeightHash: f.model_weight_hash,
        promptTokens: f.prompt_tokens,
        requestId: f.request_id,
        requestSha256: f.request_sha256,
        responseSha256: f.response_sha256)
}

@Test func receiptCanonicalFormMatchesGoldenVectors() throws {
    let vectors = try loadVectors()
    #expect(!vectors.isEmpty)
    for v in vectors {
        #expect(v.receipt.v == InferenceReceipt.version, "vector \(v.name)")
        let r = makeReceipt(v.receipt)
        #expect(r.canonicalJSON() == v.canonical, "canonical drift in vector \(v.name)")
        #expect(r.address() == v.address, "address drift in vector \(v.name)")
    }
}

@Test func receiptAddressChangesWhenAnyFieldChanges() throws {
    let base = InferenceReceipt(
        completionTokens: 42,
        modelId: "mlx-community/gemma-4-26b",
        modelWeightHash: String(repeating: "ab", count: 32),
        promptTokens: 17,
        requestId: "req-0001",
        requestSha256: String(repeating: "12", count: 32),
        responseSha256: String(repeating: "34", count: 32))
    let mutations: [InferenceReceipt] = [
        InferenceReceipt(
            completionTokens: 43, modelId: base.modelId,
            modelWeightHash: base.modelWeightHash, promptTokens: base.promptTokens,
            requestId: base.requestId, requestSha256: base.requestSha256,
            responseSha256: base.responseSha256),
        InferenceReceipt(
            completionTokens: base.completionTokens, modelId: "other-model",
            modelWeightHash: base.modelWeightHash, promptTokens: base.promptTokens,
            requestId: base.requestId, requestSha256: base.requestSha256,
            responseSha256: base.responseSha256),
        InferenceReceipt(
            completionTokens: base.completionTokens, modelId: base.modelId,
            modelWeightHash: String(repeating: "cd", count: 32), promptTokens: base.promptTokens,
            requestId: base.requestId, requestSha256: base.requestSha256,
            responseSha256: base.responseSha256),
        InferenceReceipt(
            completionTokens: base.completionTokens, modelId: base.modelId,
            modelWeightHash: base.modelWeightHash, promptTokens: base.promptTokens,
            requestId: base.requestId, requestSha256: base.requestSha256,
            responseSha256: String(repeating: "ee", count: 32)),
    ]
    for m in mutations {
        #expect(m.address() != base.address(), "mutation did not move the address")
    }
}

@Test func receiptStringEscapingMatchesGoEncoder() {
    // Mirrors TestEncodeJSONStringEscaping in coordinator/receipt.
    let cases: [(String, String)] = [
        ("plain", "\"plain\""),
        ("sla/sh", "\"sla/sh\""), // no slash escaping
        ("qu\"ote", "\"qu\\\"ote\""),
        ("back\\slash", "\"back\\\\slash\""),
        ("tab\tnl\n", "\"tab\\tnl\\n\""),
        ("ctrl\u{01}", "\"ctrl\\u0001\""),
        ("<html>&", "\"<html>&\""), // no HTML escaping
        ("unicodé-κ", "\"unicodé-κ\""),
    ]
    for (input, want) in cases {
        #expect(InferenceReceipt.encodeJSONString(input) == want, "escaping drift for \(input)")
    }
}

@Test func receiptAttestationSignsTheAddress() throws {
    // The signature contract must match v1: DER ECDSA over SHA-256 of the
    // UTF-8 address bytes. Use the software P-256 test signer.
    let key = try P256TestSigner()
    let receipt = InferenceReceipt(
        completionTokens: 1, modelId: "m", modelWeightHash: "",
        promptTokens: 1, requestId: "r",
        requestSha256: String(repeating: "00", count: 32),
        responseSha256: String(repeating: "ff", count: 32))
    let sealed = computeReceiptAttestation(identity: key, receipt: receipt)
    #expect(sealed.address == receipt.address())
    #expect(sealed.receipt == receipt.canonicalJSON())
    let signature = try #require(sealed.signature)
    #expect(try key.verify(
        signatureB64: signature, message: Data(sealed.address.utf8)))

    // Tamper: the signature must not verify over a different address.
    let forged = InferenceReceipt(
        completionTokens: 2, modelId: "m", modelWeightHash: "",
        promptTokens: 1, requestId: "r",
        requestSha256: String(repeating: "00", count: 32),
        responseSha256: String(repeating: "ff", count: 32))
    #expect(!(try key.verify(
        signatureB64: signature, message: Data(forged.address().utf8))))
}

/// Software P-256 signer with the same signing shape as the Secure Enclave
/// identity (DER ECDSA, SHA-256 of the message).
private struct P256TestSigner: AttestationSigner {
    let key: P256.Signing.PrivateKey

    init() throws {
        key = P256.Signing.PrivateKey()
    }

    func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).derRepresentation
    }

    var publicKeyBase64: String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    func verify(signatureB64: String, message: Data) throws -> Bool {
        guard let der = Data(base64Encoded: signatureB64) else { return false }
        let sig = try P256.Signing.ECDSASignature(derRepresentation: der)
        return key.publicKey.isValidSignature(sig, for: message)
    }
}

